<#
.SYNOPSIS
  End-to-end, unattended setup of the On-premises data gateway on a Windows Azure VM:
  install -> register cluster -> create SQL data source -> verify connectivity.

.DESCRIPTION
  Designed for Azure Run Command / Custom Script Extension (no RDP). Runs as SYSTEM or local admin.
  No secrets are passed on the command line. Secrets are read at runtime from Key Vault using the
  VM's managed identity (needs "Key Vault Secrets User" on the vault).

  Key Vault secrets expected (names are parameters):
    - SPN application (client) ID
    - SPN client secret
    - Gateway recovery key
    - Test SQL connection string, e.g.
      Server=tcp:sqltest01.contoso.local,1433;Database=TestDb;User ID=gw_test;Password=...;Encrypt=True;

  Prerequisites (outside this script):
    - Tenant setting "Service principals can call Fabric/Power BI APIs" enabled for a security group containing the SPN
    - Outbound 443 (and 9350-9354 optional) to the gateway endpoints; line of sight to the SQL server
    - Internal PSGallery/package source or outbound access to PSGallery if the DataGateway module isn't pre-staged

.EXAMPLE
  .\Setup-OnPremGateway.ps1 -KeyVaultName kv-gateway-prod -TenantId <guid> -GatewayName gw-prod-01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $KeyVaultName,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $GatewayName,

    [string] $SpnAppIdSecretName     = 'gw-spn-app-id',
    [string] $SpnSecretSecretName    = 'gw-spn-client-secret',
    [string] $RecoveryKeySecretName  = 'gw-recovery-key',
    [string] $SqlConnStringSecretName = 'gw-test-sql-connstring',

    [string] $DataSourceName = 'test-sql-datasource',

    # Optional: internal copy of the PowerShell 7 MSI (preferred on locked-down VMs)
    [string] $Ps7InstallerPath,
    # Optional: internal PSRepository hosting the DataGateway module
    [string] $PsRepository = 'PSGallery',

    # Credential encryption padding for the data-source call. If creation fails with a
    # credentials/encryption error, re-run with the other value.
    [ValidateSet('SHA256','SHA1')] [string] $OaepHash = 'SHA256',

    [string] $LogRoot = 'C:\ProgramData\GatewaySetup'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$logFile = Join-Path $LogRoot ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Write-Log([string]$m) {
    $line = "{0:u} {1}" -f (Get-Date), $m
    Add-Content -Path $logFile -Value $line
    Write-Output $line
}

# ---------------------------------------------------------------------------
# STAGE 1: Gateway cmdlets need PowerShell 7. If running in 5.1 (Run Command),
#          ensure pwsh exists, then relaunch this same script under pwsh.
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Log "Running under Windows PowerShell $($PSVersionTable.PSVersion); bootstrapping PowerShell 7."
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) {
        $msi = $Ps7InstallerPath
        if (-not $msi) {
            # Falls back to GitHub; will fail on locked-down networks -> stage the MSI internally instead.
            $msi = Join-Path $LogRoot 'PowerShell-7-win-x64.msi'
            Write-Log "No -Ps7InstallerPath given; attempting download from GitHub releases."
            $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
            $asset = $rel.assets | Where-Object name -like 'PowerShell-*-win-x64.msi' | Select-Object -First 1
            Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
        }
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart ADD_PATH=1" -Wait -PassThru
        if ($p.ExitCode -notin 0,3010) { throw "PowerShell 7 install failed, msiexec exit code $($p.ExitCode)" }
    }
    if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found after install." }

    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { $fwd += "-$($kv.Key)"; $fwd += [string]$kv.Value }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

Start-Transcript -Path (Join-Path $LogRoot 'transcript.log') -Append | Out-Null
try {
    Write-Log "PowerShell $($PSVersionTable.PSVersion) - starting gateway setup for '$GatewayName'."

    # -----------------------------------------------------------------------
    # Helper: read a Key Vault secret using the VM managed identity (IMDS)
    # -----------------------------------------------------------------------
    $script:kvToken = $null
    function Get-KvSecret([string]$Name) {
        if (-not $script:kvToken) {
            $t = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get `
                -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
            $script:kvToken = $t.access_token
        }
        (Invoke-RestMethod -Method Get -Headers @{ Authorization = "Bearer $script:kvToken" } `
            -Uri "https://$KeyVaultName.vault.azure.net/secrets/${Name}?api-version=7.4").value
    }

    Write-Log "Reading secrets from Key Vault '$KeyVaultName' (values are never logged)."
    $spnAppId   = Get-KvSecret $SpnAppIdSecretName
    $spnSecret  = Get-KvSecret $SpnSecretSecretName
    $recoveryPw = Get-KvSecret $RecoveryKeySecretName
    $sqlConn    = Get-KvSecret $SqlConnStringSecretName

    # -----------------------------------------------------------------------
    # STAGE 2: DataGateway module
    # -----------------------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name DataGateway)) {
        Write-Log "Installing DataGateway module from '$PsRepository'."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module -Name DataGateway -Repository $PsRepository -Scope AllUsers -Force -AcceptLicense
    }
    Import-Module DataGateway -Force

    # -----------------------------------------------------------------------
    # STAGE 3: Install the gateway Windows service (PBIEgwService)
    # -----------------------------------------------------------------------
    $svc = Get-Service -Name PBIEgwService -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Installing On-premises data gateway (silent)."
        Install-DataGateway -AcceptConditions
        $svc = Get-Service -Name PBIEgwService -ErrorAction Stop
    } else {
        Write-Log "Gateway service already present - skipping install."
    }
    if ($svc.StartType -ne 'Automatic') { Set-Service PBIEgwService -StartupType Automatic }
    if ($svc.Status -ne 'Running')      { Start-Service PBIEgwService }
    Write-Log "PBIEgwService status: $((Get-Service PBIEgwService).Status)"

    # -----------------------------------------------------------------------
    # STAGE 4: Authenticate as the SPN and register the gateway cluster
    # -----------------------------------------------------------------------
    $secureSpn      = ConvertTo-SecureString $spnSecret  -AsPlainText -Force
    $secureRecovery = ConvertTo-SecureString $recoveryPw -AsPlainText -Force

    Write-Log "Connecting gateway module as service principal."
    Connect-DataGatewayServiceAccount -ApplicationId $spnAppId -ClientSecret $secureSpn -Tenant $TenantId | Out-Null

    $existing = Get-DataGatewayCluster | Where-Object { $_.Name -eq $GatewayName }
    if ($existing) {
        Write-Log "Gateway '$GatewayName' already registered - skipping registration."
    } else {
        Write-Log "Registering gateway '$GatewayName'."
        Add-DataGatewayCluster -Name $GatewayName -RecoveryKey $secureRecovery -OverwriteExistingGateway | Out-Null
    }

    # -----------------------------------------------------------------------
    # STAGE 5: Create the SQL data source through the Power BI REST API
    #          (the DataGateway module has no data-source cmdlets)
    # -----------------------------------------------------------------------
    Write-Log "Requesting Power BI API token for the SPN."
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        grant_type    = 'client_credentials'
        client_id     = $spnAppId
        client_secret = $spnSecret
        scope         = 'https://analysis.windows.net/powerbi/api/.default'
    }
    $hdr  = @{ Authorization = "Bearer $($tok.access_token)"; 'Content-Type' = 'application/json' }
    $base = 'https://api.powerbi.com/v1.0/myorg'

    # Wait for the gateway to appear in the service (registration is eventually consistent)
    $gw = $null
    for ($i = 1; $i -le 12 -and -not $gw; $i++) {
        $gw = (Invoke-RestMethod -Headers $hdr -Uri "$base/gateways").value | Where-Object name -eq $GatewayName | Select-Object -First 1
        if (-not $gw) { Write-Log "Gateway not visible via API yet (attempt $i/12); waiting 15s."; Start-Sleep 15 }
    }
    if (-not $gw) { throw "Gateway '$GatewayName' not visible via the API. Confirm the SPN is a gateway admin and the tenant setting allows SPN API access." }
    $gwId = $gw.id
    Write-Log "Gateway id: $gwId"

    # Parse the test connection string
    $csb = New-Object System.Data.Common.DbConnectionStringBuilder
    $csb.ConnectionString = $sqlConn
    function Get-CsValue([string[]]$Keys) {
        foreach ($k in $Keys) { if ($csb.ContainsKey($k)) { return [string]$csb[$k] } }
        return $null
    }
    $server      = (Get-CsValue 'Server','Data Source') -replace '^tcp:', ''
    $db          = Get-CsValue 'Database','Initial Catalog'
    $user        = Get-CsValue 'User ID','UID'
    $sqlPassword = Get-CsValue 'Password','PWD'
    if (-not ($server -and $db -and $user -and $sqlPassword)) { throw "Connection string must include Server, Database, User ID and Password (SQL auth)." }

    # Network pre-check from the VM to the SQL server
    $hostPart = ($server -split ',')[0]
    $port = if ($server -match ',(\d+)$') { [int]$Matches[1] } else { 1433 }
    $tcp = Test-NetConnection -ComputerName $hostPart -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) { throw "VM cannot reach $hostPart`:$port (check NSG/firewall/DNS/ExpressRoute)." }
    Write-Log "TCP reachability to $hostPart`:$port OK."

    # Idempotency: skip if a data source with this name exists
    $dsList = (Invoke-RestMethod -Headers $hdr -Uri "$base/gateways/$gwId/datasources").value
    $ds = $dsList | Where-Object dataSourceName -eq $DataSourceName | Select-Object -First 1

    if (-not $ds) {
        # Encrypt credentials with the gateway's public key (required for on-prem gateways)
        $pub = $gw.publicKey
        $credJson = (@{ credentialData = @(
            @{ name = 'username'; value = $user },
            @{ name = 'password'; value = $sqlPassword }
        ) } | ConvertTo-Json -Compress)

        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rp  = New-Object System.Security.Cryptography.RSAParameters
        $rp.Modulus  = [Convert]::FromBase64String($pub.modulus)
        $rp.Exponent = [Convert]::FromBase64String($pub.exponent)
        $rsa.ImportParameters($rp)
        $pad = if ($OaepHash -eq 'SHA1') { [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1 }
               else                      { [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256 }
        $bytes = [Text.Encoding]::UTF8.GetBytes($credJson)
        $enc = ''
        for ($o = 0; $o -lt $bytes.Length; $o += 60) {      # 60-byte segments, per Microsoft's sample
            $len = [Math]::Min(60, $bytes.Length - $o)
            $seg = New-Object byte[] $len
            [Array]::Copy($bytes, $o, $seg, 0, $len)
            $enc += [Convert]::ToBase64String($rsa.Encrypt($seg, $pad))
        }

        $body = @{
            dataSourceType    = 'Sql'
            dataSourceName    = $DataSourceName
            connectionDetails = (@{ server = $hostPart; database = $db } | ConvertTo-Json -Compress)
            credentialDetails = @{
                credentialType      = 'Basic'
                credentials         = $enc
                encryptedConnection = 'Encrypted'
                encryptionAlgorithm = 'RSA-OAEP'
                privacyLevel        = 'Organizational'
            }
        } | ConvertTo-Json -Depth 5

        Write-Log "Creating data source '$DataSourceName'."
        $ds = Invoke-RestMethod -Method Post -Headers $hdr -Uri "$base/gateways/$gwId/datasources" -Body $body
    } else {
        Write-Log "Data source '$DataSourceName' already exists - skipping creation."
    }

    # -----------------------------------------------------------------------
    # STAGE 6: Verify - gateway end-to-end connection test to the data source
    # -----------------------------------------------------------------------
    Invoke-RestMethod -Method Get -Headers $hdr -Uri "$base/gateways/$gwId/datasources/$($ds.id)/status" | Out-Null
    Write-Log "SUCCESS: data source '$DataSourceName' on gateway '$GatewayName' passed the connection test."
    Write-Log "Service: $((Get-Service PBIEgwService).Status). Log: $logFile"
    exit 0
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Log "API detail: $($_.ErrorDetails.Message)" }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
    Remove-Variable spnSecret, recoveryPw, sqlConn, sqlPassword -ErrorAction SilentlyContinue
}

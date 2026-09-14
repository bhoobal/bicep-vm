<#
.SYNOPSIS
    First-boot initialization script for the Windows Server 2025 Datacenter VM.

.DESCRIPTION
    Windows has no native cloud-init support (cloud-init/Cloudbase-Init is not present on the
    standard MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition marketplace
    image used by this template). This script is the Windows equivalent: it is embedded into
    the VM's CustomScriptExtension configuration by main.bicep and executed once, automatically,
    the first time the VM boots after provisioning.

    It runs as SYSTEM. Keep it idempotent - re-running the extension (e.g. on redeploy) should
    not break anything.

    Extend the "Baseline configuration" section below with whatever your organization needs
    (domain join, agent installs, registry hardening, feature enablement, etc).
#>

[CmdletBinding()]
param(
    # All of the following are substituted at Bicep compile-time by main.bicep
    # (see the `replace()` calls building initScriptContent) - do not rename the
    # __PLACEHOLDER__ tokens without updating main.bicep to match.
    [string]$TimeZoneId         = '__TIME_ZONE_ID__',
    [string]$InstallDataGateway = '__INSTALL_DATA_GATEWAY__',   # 'true' or 'false'
    [string]$GatewayInstallScriptB64   = '__GATEWAY_INSTALL_SCRIPT_B64__',
    [string]$GatewayRegisterScriptB64  = '__GATEWAY_REGISTER_SCRIPT_B64__',
    [string]$LogPath            = 'C:\Windows\Temp\init-script.log',
    [string]$GatewayScriptDir   = 'C:\ProgramData\vm-init'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

New-Item -Path (Split-Path $LogPath) -ItemType Directory -Force | Out-Null
Write-Log "=== init.ps1 started ==="

try {
    # ---------------------------------------------------------------------
    # Baseline configuration - customize this section for your environment
    # ---------------------------------------------------------------------

    # Set the OS time zone
    Write-Log "Setting time zone to '$TimeZoneId'"
    tzutil /s $TimeZoneId

    # Set the power plan to High Performance (recommended for server workloads)
    Write-Log 'Setting power plan to High Performance'
    powercfg /setactive SCHEME_MIN

    # Ensure the Windows Firewall rule group for Remote Desktop is enabled
    Write-Log 'Ensuring Remote Desktop firewall rules are enabled'
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue

    # Disable IE Enhanced Security Configuration for administrators (common baseline tweak
    # on Windows Server "desktop" builds; remove if not desired)
    Write-Log 'Disabling IE Enhanced Security Configuration for Administrators'
    $ieEscAdminPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
    if (Test-Path $ieEscAdminPath) {
        Set-ItemProperty -Path $ieEscAdminPath -Name 'IsInstalled' -Value 0
    }

    # Bring any additional data disks online, initialize, and format them (no-op if none attached)
    Write-Log 'Checking for raw/offline data disks to initialize'
    $rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.OperationalStatus -eq 'Offline' }
    foreach ($disk in $rawDisks) {
        Write-Log "Initializing disk $($disk.Number)"
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
            New-Partition -AssignDriveLetter -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data$($disk.Number)" -Confirm:$false
    }

    # ---------------------------------------------------------------------
    # On-premises Data Gateway (standard/"enterprise" mode) - unattended install only.
    #
    # This installs the gateway SOFTWARE. It deliberately does NOT create/register the
    # gateway cluster: Microsoft's own docs state Add-DataGatewayCluster and
    # Add-DataGatewayClusterMember "must be run with a user based credential" (an
    # interactive sign-in), which cannot run headless as SYSTEM during provisioning.
    # An admin must finish setup by running register-data-gateway.ps1 manually.
    # ---------------------------------------------------------------------
    if ($InstallDataGateway -eq 'true') {
        Write-Log 'InstallDataGateway=true - installing the on-premises data gateway'

        New-Item -Path $GatewayScriptDir -ItemType Directory -Force | Out-Null

        # PowerShell 7+ is required by the DataGateway module (Windows PowerShell 5.1,
        # which is what this init script itself runs under, is not supported).
        if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
            Write-Log 'PowerShell 7 not found - installing it silently via the latest GitHub MSI release'
            $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            $asset = $release.assets | Where-Object { $_.name -like '*win-x64.msi' } | Select-Object -First 1
            if (-not $asset) { throw 'Could not find a win-x64.msi asset in the latest PowerShell GitHub release.' }

            $msiPath = Join-Path $env:TEMP $asset.name
            Write-Log "Downloading PowerShell 7 installer: $($asset.browser_download_url)"
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $msiPath

            Write-Log 'Installing PowerShell 7 silently (msiexec /quiet)'
            $msiArgs = @('/package', $msiPath, '/quiet', 'ADD_PATH=1')
            $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "PowerShell 7 MSI install failed with exit code $($proc.ExitCode)" }

            # Refresh PATH in this process so pwsh.exe is resolvable without a new shell
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('Path', 'User')
        }
        else {
            Write-Log 'PowerShell 7 already present'
        }

        # Materialize the two gateway scripts on disk: install-data-gateway.ps1 is run now
        # (unattended); register-data-gateway.ps1 is left behind for an admin to run later.
        $installScriptPath = Join-Path $GatewayScriptDir 'install-data-gateway.ps1'
        $registerScriptPath = Join-Path $GatewayScriptDir 'register-data-gateway.ps1'

        [System.IO.File]::WriteAllText(
            $installScriptPath,
            [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($GatewayInstallScriptB64))
        )
        [System.IO.File]::WriteAllText(
            $registerScriptPath,
            [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($GatewayRegisterScriptB64))
        )

        Write-Log "Running $installScriptPath under pwsh.exe"
        & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $installScriptPath
        if ($LASTEXITCODE -ne 0) { throw "install-data-gateway.ps1 failed with exit code $LASTEXITCODE" }

        Write-Log "Gateway software installed. ACTION REQUIRED: an admin must sign in to this VM (RDP/console) and run:"
        Write-Log "  pwsh -File `"$registerScriptPath`" -GatewayName '<unique-name>'"
        Write-Log 'to interactively register the gateway - this step cannot be automated.'
    }
    else {
        Write-Log 'InstallDataGateway=false - skipping on-premises data gateway install'
    }

    # ---------------------------------------------------------------------
    # TODO: add organization-specific steps here, e.g.:
    #   - Domain join (or use the AVM module's built-in extensionDomainJoinConfig instead)
    #   - Install monitoring / security agents
    #   - Apply registry-based hardening
    #   - Install application packages (choco, winget, MSI, etc.)
    # ---------------------------------------------------------------------

    Write-Log '=== init.ps1 completed successfully ==='
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    throw
}

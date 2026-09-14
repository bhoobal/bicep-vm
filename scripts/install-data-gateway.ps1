<#
.SYNOPSIS
    Installs the On-premises Data Gateway (standard/"enterprise" mode) software, unattended.

.DESCRIPTION
    This is the fully-unattended half of on-premises data gateway setup: it installs the
    official `DataGateway` PowerShell module from the PowerShell Gallery and uses its
    `Install-DataGateway` cmdlet to download and silently install the gateway software
    itself. No credentials are needed for this part.

    IMPORTANT - this script deliberately does NOT create or join a gateway cluster.
    Per Microsoft's own cmdlet documentation, both `Add-DataGatewayCluster` and
    `Add-DataGatewayClusterMember` "must be run with a user based credential" - i.e. an
    interactive sign-in (browser / device code). That is fundamentally incompatible with
    unattended execution as SYSTEM during VM provisioning: there is no user session to
    complete the sign-in, and a service-principal login (which IS supported for other
    DataGateway cmdlets) is explicitly not accepted for cluster creation.
    See scripts/register-data-gateway.ps1, which must be run manually, once, by an admin
    after the VM is up (e.g. over RDP), to finish setup.

    Reference:
      https://learn.microsoft.com/en-us/powershell/gateway/overview
      https://learn.microsoft.com/en-us/powershell/module/datagateway/install-datagateway
      https://learn.microsoft.com/en-us/powershell/module/datagateway/add-datagatewaycluster

.NOTES
    Must run under PowerShell 7.0.6+ (pwsh.exe) - the DataGateway module does not support
    Windows PowerShell 5.1. init.ps1 installs PowerShell 7 and re-launches this script
    under pwsh; do the same if running it standalone.

    Requires outbound internet access from the VM to, at minimum:
      - www.powershellgallery.com and its CDN   (Install-Module DataGateway)
      - go.microsoft.com / download.microsoft.com (the gateway installer itself)
    Once running, the gateway service needs a broader set of Microsoft cloud endpoints -
    see https://learn.microsoft.com/en-us/data-integration/gateway/service-gateway-communication
    for the authoritative allow-list before locking down egress on this VM's subnet/NSG.
#>

[CmdletBinding()]
param(
    [string]$LogPath = 'C:\Windows\Temp\install-data-gateway.log'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] $Message"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

Write-Log "=== install-data-gateway.ps1 started (PSVersion=$($PSVersionTable.PSVersion)) ==="

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'This script must be run under PowerShell 7+ (pwsh.exe). The DataGateway module requires PS 7.0.6 or later.'
    }

    Write-Log 'Ensuring NuGet provider is present and PSGallery is trusted (required for unattended Install-Module)'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Write-Log 'Installing the DataGateway PowerShell module from the PowerShell Gallery'
    Install-Module -Name DataGateway -Force -Scope AllUsers -AllowClobber

    Write-Log 'Importing DataGateway module'
    Import-Module DataGateway -ErrorAction Stop

    Write-Log 'Downloading and silently installing the on-premises data gateway (standard/enterprise mode)'
    Install-DataGateway -AcceptConditions

    Write-Log '=== install-data-gateway.ps1 completed successfully. ==='
    Write-Log 'The gateway SOFTWARE is installed but NOT YET REGISTERED to a tenant.'
    Write-Log 'An admin must now run register-data-gateway.ps1 INTERACTIVELY (e.g. over RDP) to create/join a gateway cluster.'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    throw
}

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
    # Substituted at Bicep compile-time by main.bicep (see `replace()` on initScriptContent)
    [string]$TimeZoneId = '__TIME_ZONE_ID__',
    [string]$LogPath    = 'C:\Windows\Temp\init-script.log'
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

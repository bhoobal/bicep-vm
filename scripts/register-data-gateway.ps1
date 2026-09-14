<#
.SYNOPSIS
    Registers the already-installed on-premises data gateway with your tenant.
    RUN THIS MANUALLY - it is NOT part of the automated VM-launch script.

.DESCRIPTION
    This step cannot be automated as part of VM provisioning. Microsoft's own cmdlet
    documentation states that both `Add-DataGatewayCluster` and
    `Add-DataGatewayClusterMember` "must be run with a user based credential" - meaning
    `Connect-DataGatewayServiceAccount` has to complete an interactive sign-in
    (browser/device code), which requires a real, logged-on desktop session. A service
    principal (`Connect-DataGatewayServiceAccount -ApplicationId ...`) is supported for
    most other DataGateway cmdlets, but explicitly not for creating or joining a cluster.

    Run this once, interactively, after RDP'ing or console-logging into the VM - signed
    in as the user who should be this gateway's initial administrator (that account needs
    permission to create gateways in your tenant; ask your Power BI/Fabric admin if unsure).

.PARAMETER GatewayName
    Name for the new gateway cluster. Must be unique across the tenant.

.PARAMETER RegionKey
    Optional. Azure region key for the gateway cluster (run Get-DataGatewayRegion to list
    valid values). Defaults to your tenant's default Power BI region if omitted.

.PARAMETER JoinExistingCluster
    Optional. If set, joins an existing gateway cluster as a high-availability member
    instead of creating a brand-new cluster. Requires -GatewayClusterId.

.PARAMETER GatewayClusterId
    Required when -JoinExistingCluster is set. The Id (GUID) of the existing cluster to join.

.EXAMPLE
    # Create a brand-new gateway cluster (most common case for a first VM)
    pwsh -File .\register-data-gateway.ps1 -GatewayName 'vm-win2025-01-gw'

.EXAMPLE
    # Add this VM as a high-availability member of an existing cluster
    pwsh -File .\register-data-gateway.ps1 -GatewayName 'vm-win2025-02-gw' `
        -JoinExistingCluster -GatewayClusterId '14e63994-6c2c-4fda-a2b1-3fc27079c855'

.NOTES
    https://learn.microsoft.com/en-us/powershell/module/datagateway/add-datagatewaycluster
    https://learn.microsoft.com/en-us/powershell/module/datagateway/add-datagatewayclustermember
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GatewayName,

    [string]$RegionKey,

    [switch]$JoinExistingCluster,

    [string]$GatewayClusterId
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Run this under PowerShell 7+ (pwsh.exe). Install it first if needed: winget install --id Microsoft.PowerShell'
}

if ($JoinExistingCluster -and -not $GatewayClusterId) {
    throw '-GatewayClusterId is required when -JoinExistingCluster is set.'
}

Import-Module DataGateway -ErrorAction Stop

Write-Host 'A browser window will open for interactive sign-in.' -ForegroundColor Cyan
Write-Host 'Sign in with the account that should administer this gateway.' -ForegroundColor Cyan

# Interactive sign-in - this is the step that cannot be automated/run headless.
Connect-DataGatewayServiceAccount

$recoveryKey = Read-Host -Prompt 'Enter a recovery key for this gateway (used to encrypt on-prem credentials; store it in a password manager/Key Vault - Microsoft cannot recover it for you)' -AsSecureString

if ($JoinExistingCluster) {
    $params = @{
        GatewayName      = $GatewayName
        RecoveryKey      = $recoveryKey
        GatewayClusterId = $GatewayClusterId
    }
    Add-DataGatewayClusterMember @params
    Write-Host "Gateway '$GatewayName' joined cluster '$GatewayClusterId' as a member." -ForegroundColor Green
}
else {
    $params = @{
        GatewayName = $GatewayName
        RecoveryKey = $recoveryKey
    }
    if ($RegionKey) { $params['RegionKey'] = $RegionKey }
    Add-DataGatewayCluster @params
    Write-Host "Gateway cluster '$GatewayName' created." -ForegroundColor Green
}

Write-Host 'Run Get-DataGatewayCluster to confirm status.' -ForegroundColor Cyan

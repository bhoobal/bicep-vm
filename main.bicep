metadata name = 'Windows Server 2025 Datacenter VM'
metadata description = '''
Deploys a single Windows Server 2025 Datacenter virtual machine using the existing
MicrosoftWindowsServer:WindowsServer marketplace platform image, attached to an
already-existing VNet/subnet.

Uses the Azure Verified Module (AVM) `avm/res/compute/virtual-machine`, vendored
locally under modules/avm/res/compute/virtual-machine (pinned to upstream tag
avm/res/compute/virtual-machine/0.22.3) so the exact module version is locked and
does not depend on a live pull from the public Bicep registry at deploy time.

Windows has no native cloud-init support, so first-boot initialization is done via
the module's built-in CustomScriptExtension configuration, which runs
scripts/init.ps1 (the Windows equivalent of a cloud-init script) once on first boot.
'''

targetScope = 'resourceGroup'

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Required. Name of the virtual machine resource.')
@minLength(1)
@maxLength(64)
param vmName string

@description('Optional. The Windows computer/host name (NetBIOS). Must be 15 characters or fewer. Defaults to the first 15 characters of vmName.')
@maxLength(15)
param computerName string = take(vmName, 15)

@description('Optional. Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('''Required. Resource ID of the existing, pre-created subnet the VM's NIC will be attached to.
Example: /subscriptions/<subId>/resourceGroups/<rgName>/providers/Microsoft.Network/virtualNetworks/<vnetName>/subnets/<subnetName>''')
param subnetResourceId string

@description('Optional. Size (SKU) of the virtual machine.')
param vmSize string = 'Standard_D4s_v5'

@description('Optional. Marketplace image publisher.')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Optional. Marketplace image offer.')
param imageOffer string = 'WindowsServer'

@description('Optional. Marketplace image SKU. Defaults to the Gen2 Azure Edition of Windows Server 2025 Datacenter, which is the SKU Microsoft recommends for new Azure deployments (built-in Hotpatch support). Adjust if your subscription is enabled for a different 2025 SKU (e.g. "2025-datacenter-g2").')
param imageSku string = '2025-datacenter-azure-edition'

@description('Optional. Marketplace image version.')
param imageVersion string = 'latest'

@description('Required. Local administrator username for the VM.')
@secure()
param adminUsername string

@description('Required. Local administrator password for the VM. Supply this via a secure parameter file reference to Key Vault (see main.bicepparam) - never commit a literal value to source control.')
@secure()
param adminPassword string

@description('Optional. OS disk storage account type.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'StandardSSD_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param osDiskStorageAccountType string = 'Premium_LRS'

@description('Optional. OS disk size in GB.')
param osDiskSizeGB int = 128

@description('Optional. Availability zone to pin the VM to. Use -1 for no zone.')
@allowed([
  -1
  1
  2
  3
])
param availabilityZone int = -1

@description('Optional. Enable accelerated networking on the NIC. Requires a vmSize that supports it.')
param enableAcceleratedNetworking bool = true

@description('Optional. Enable boot diagnostics (uses a Microsoft-managed storage account).')
param bootDiagnostics bool = true

@description('Optional. Windows guest OS time zone applied by the init script, e.g. "Pacific Standard Time".')
param timeZoneId string = 'UTC'

@description('Optional. Tags applied to all resources.')
param tags object = {
  environment: 'dev'
  workload: 'windows-server-2025-vm'
}

// =============================================================================
// VARIABLES
// =============================================================================

// The Windows equivalent of a cloud-init script, run once on first boot via the
// AVM module's built-in CustomScriptExtension support. Loaded from disk so the
// script can be authored/tested as a normal .ps1 file. The timezone placeholder is
// substituted here at compile time so no arguments need to be passed on the command
// line (which keeps the extension's commandToExecute free of nested-quoting issues).
var initScriptContent = replace(loadTextContent('scripts/init.ps1'), '__TIME_ZONE_ID__', timeZoneId)

// PowerShell has no native way to decode a UTF-8 base64 payload via -EncodedCommand
// (that flag requires UTF-16LE), so the script is base64-encoded with Bicep's UTF-8
// base64() function and decoded explicitly as UTF-8 inside PowerShell before being
// invoked. This keeps the whole payload self-contained in the ARM deployment - no
// outbound internet access is required to fetch the script, which matters because
// this VM is deployed on a private subnet. The base64 alphabet (A-Z a-z 0-9 + / =)
// contains no quote characters, so it is safe to splice directly into the command line.
var encodedInitScript = base64(initScriptContent)
var initCommandToExecute = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'${encodedInitScript}\')))"'

// =============================================================================
// MODULE - locally vendored AVM avm/res/compute/virtual-machine (pinned v0.22.3)
// =============================================================================

module vm 'modules/avm/res/compute/virtual-machine/main.bicep' = {
  name: take('deploy-${vmName}', 64)
  params: {
    name: vmName
    computerName: computerName
    location: location
    vmSize: vmSize
    osType: 'Windows'
    licenseType: 'Windows_Server'
    availabilityZone: availabilityZone
    encryptionAtHost: false
    tags: tags

    adminUsername: adminUsername
    adminPassword: adminPassword

    // Existing marketplace platform image (not a custom image)
    imageReference: {
      publisher: imagePublisher
      offer: imageOffer
      sku: imageSku
      version: imageVersion
    }

    osDisk: {
      createOption: 'FromImage'
      caching: 'ReadWrite'
      diskSizeGB: osDiskSizeGB
      managedDisk: {
        storageAccountType: osDiskStorageAccountType
      }
    }

    // Attach to the existing, pre-created VNet/subnet - no network resources are created
    nicConfigurations: [
      {
        deleteOption: 'Delete'
        enableAcceleratedNetworking: enableAcceleratedNetworking
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
          }
        ]
      }
    ]

    bootDiagnostics: bootDiagnostics

    // Guest patching baseline - platform-managed patching with hotpatch-friendly image
    patchMode: 'AutomaticByPlatform'
    patchAssessmentMode: 'AutomaticByPlatform'
    enableAutomaticUpdates: true

    // Windows equivalent of a cloud-init script: runs scripts/init.ps1 once on first boot
    extensionCustomScriptConfig: {
      settings: {
        commandToExecute: initCommandToExecute
      }
    }
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Resource ID of the deployed virtual machine.')
output vmResourceId string = vm.outputs.resourceId

@description('Name of the deployed virtual machine.')
output vmName string = vm.outputs.name

@description('Azure region the VM was deployed to.')
output location string = vm.outputs.location

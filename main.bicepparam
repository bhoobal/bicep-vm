using 'main.bicep'

// -----------------------------------------------------------------------------
// Fill in the values below for your environment before deploying.
// -----------------------------------------------------------------------------

param vmName = 'vm-win2025-01'

// Resource ID of the existing, pre-created subnet the VM will attach to.
// Replace <sub-id>, <rg-name>, <vnet-name> and <subnet-name>.
param subnetResourceId = '/subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>'

param vmSize = 'Standard_D4s_v5'

param adminUsername = 'azureadmin'

// Do NOT commit a literal password here. Either:
//   1) pass it at deploy time: az deployment group create ... --parameters adminPassword=$SECURE_VALUE
//   2) or reference a Key Vault secret, e.g.:
//        param adminPassword = getSecret('<subscriptionId>', '<vaultResourceGroup>', '<vaultName>', '<secretName>')
param adminPassword = ''

param timeZoneId = 'UTC'

param tags = {
  environment: 'dev'
  workload: 'windows-server-2025-vm'
  owner: 'bhoobalan.palanivel@gmail.com'
}

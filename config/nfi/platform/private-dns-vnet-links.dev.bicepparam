using '../../../src/platform/connectivity/private-dns-vnet-links.bicep'

// Deployment target:
//   Subscription : 719f5040-fa8e-4b0a-bc2b-2e3fdc8163c2  (AZ-NFI-devops)
//   Resource group: rg-dns
//
// What-if:
//   az deployment group what-if \
//     --subscription 719f5040-fa8e-4b0a-bc2b-2e3fdc8163c2 \
//     --resource-group rg-dns \
//     --template-file src/platform/connectivity/private-dns-vnet-links.bicep \
//     --parameters config/nfi/platform/private-dns-vnet-links.dev.bicepparam

param environment      = 'dev'

// DEV application VNet — subscription AZ-NFI-lims-dev (8ebb26a1-...), resource group rg-connectivity
param virtualNetworkId = '/subscriptions/8ebb26a1-674a-40d1-97f8-e0a237e288a6/resourceGroups/rg-connectivity/providers/Microsoft.Network/virtualNetworks/nfi-lims-dev-westeu-vnet'

param tags = {
  environment: 'development'
  purpose:     'lims'
  ManagedBy:   'bicep-iac'
}

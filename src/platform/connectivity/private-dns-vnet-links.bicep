targetScope = 'resourceGroup'

metadata name = 'Platform Connectivity — Private DNS VNet Links'
metadata description = 'Adds Virtual Network Links from Private DNS zones (in the DevOps subscription) to a spoke VNet. Deploy into the rg-dns resource group in subscription 719f5040-fa8e-4b0a-bc2b-2e3fdc8163c2.'

@description('Full resource ID of the spoke VNet to link.')
param virtualNetworkId string

@description('Environment code — used to construct the link name.')
@allowed(['mgmt', 'dev', 'tst', 'acc', 'preprd', 'prd'])
param environment string

@description('Tags to apply.')
param tags object = {}

// Backup Private DNS zone — required for RSV SQL workload registration via private endpoint
module backupLink '../../../modules/platform/private-dns-vnet-link/main.bicep' = {
  name: 'dns-link-backup-${environment}'
  params: {
    privateDnsZoneName: 'privatelink.we.backup.windowsazure.com'
    linkName:           'vnl-nfi-lims-${environment}-backup'
    virtualNetworkId:   virtualNetworkId
  }
}

// Queue Private DNS zone — required for RSV storage queue private endpoint resolution
module queueLink '../../../modules/platform/private-dns-vnet-link/main.bicep' = {
  name: 'dns-link-queue-${environment}'
  params: {
    privateDnsZoneName: 'privatelink.queue.core.windows.net'
    linkName:           'vnl-nfi-lims-${environment}-queue'
    virtualNetworkId:   virtualNetworkId
  }
}

// Blob link (privatelink.blob.core.windows.net) is intentionally excluded —
// vnl-nfi-lims-dev-blob already exists and must not be duplicated.

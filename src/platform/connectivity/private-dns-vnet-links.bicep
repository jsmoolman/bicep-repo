targetScope = 'resourceGroup'

metadata name = 'Platform Connectivity — Private DNS VNet Links'
metadata description = 'Adds Virtual Network Links from Private DNS zones to a spoke VNet. Deployed into the resource group that owns the DNS zones (rg-dns in subscription 719f5040-fa8e-4b0a-bc2b-2e3fdc8163c2).'

// -----------------------------------------------------------------------------
// PARAMETERS
// -----------------------------------------------------------------------------

@description('Azure region. Always the full region name, e.g. "westeurope". Required by the mandatory parameter contract.')
param location string = 'westeurope'

@description('Environment code — used to construct link names.')
@allowed(['mgmt', 'dev', 'tst', 'acc', 'preprd', 'prd'])
param environment string

@description('Subscription ID this param file targets. Used by pipelines to select the correct service connection.')
param subscriptionId string

@description('Workload / purpose identifier (e.g. lims). Required by the mandatory parameter contract.')
param purpose string

@description('Static prefix used when constructing VNet link names, e.g. "vnl-nfi-lims". Driven from config so this composition stays customer-neutral.')
param linkNamePrefix string

@description('Full resource ID of the spoke VNet to link. May be in a different subscription from the DNS zones.')
param virtualNetworkId string

@description('Tags applied to all VNet link resources.')
param tags object = {}

// -----------------------------------------------------------------------------
// MODULES
// -----------------------------------------------------------------------------

// Backup Private DNS zone — required for RSV SQL workload registration via private endpoint
module backupLink '../../../modules/platform/private-dns-vnet-link/main.bicep' = {
  name: 'dns-link-backup-${environment}'
  params: {
    privateDnsZoneName: 'privatelink.we.backup.windowsazure.com'
    linkName:           '${linkNamePrefix}-${environment}-backup'
    virtualNetworkId:   virtualNetworkId
    tags:               tags
  }
}

// Queue Private DNS zone — required for RSV storage queue private endpoint resolution
module queueLink '../../../modules/platform/private-dns-vnet-link/main.bicep' = {
  name: 'dns-link-queue-${environment}'
  params: {
    privateDnsZoneName: 'privatelink.queue.core.windows.net'
    linkName:           '${linkNamePrefix}-${environment}-queue'
    virtualNetworkId:   virtualNetworkId
    tags:               tags
  }
}

// Blob link (privatelink.blob.core.windows.net) is intentionally excluded —
// vnl-nfi-lims-dev-blob already exists for DEV and must not be duplicated.

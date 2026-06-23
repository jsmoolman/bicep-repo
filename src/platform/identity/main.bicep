targetScope = 'subscription'

metadata name = 'Platform Identity'
metadata description = 'Deploys identity subscription baseline: resource groups, VNet peering to hub, and Active Directory infrastructure support resources.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Tags to apply to all resources.')
param tags object = {}

var resourceGroupName = 'rg-id-prd-${location}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

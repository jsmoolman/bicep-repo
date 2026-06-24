targetScope = 'subscription'

metadata name = 'Platform Connectivity — Virtual WAN'
metadata description = 'Deploys an Azure Virtual WAN with a secured virtual hub as an alternative to the hub-spoke topology.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Tags to apply to all resources.')
param tags object = {}

var resourceGroupName = 'rg-conn-prd-${location}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: 'vwan-conn-prd-${location}'
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    disableVpnEncryption: false
    allowBranchToBranchTraffic: true
  }
}

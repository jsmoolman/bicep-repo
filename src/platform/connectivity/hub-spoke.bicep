targetScope = 'subscription'

metadata name = 'Platform Connectivity — Hub-Spoke'
metadata description = 'Deploys the hub virtual network, Azure Firewall, VPN/ExpressRoute gateways, and Azure Bastion for a hub-spoke topology.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Hub VNet address space.')
param hubAddressPrefix string = '10.0.0.0/16'

@description('Tags to apply to all resources.')
param tags object = {}

var resourceGroupName = 'rg-conn-prd-${location}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-conn-prd-${location}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [hubAddressPrefix]
    }
  }
}

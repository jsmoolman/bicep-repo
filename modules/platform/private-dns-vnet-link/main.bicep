targetScope = 'resourceGroup'

metadata name = 'Private DNS — VNet Link'
metadata description = 'Adds a Virtual Network Link to an existing Private DNS zone. Deployed into the resource group that owns the DNS zone.'

@description('Name of the existing Private DNS zone.')
param privateDnsZoneName string

@description('Name for the VNet link resource.')
param linkName string

@description('Full resource ID of the VNet to link.')
param virtualNetworkId string

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDnsZoneName
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: linkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

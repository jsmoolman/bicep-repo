targetScope = 'subscription'

metadata name = 'Platform Security'
metadata description = 'Enables Microsoft Defender for Cloud plans and configures Microsoft Sentinel on the central Log Analytics workspace.'

@description('Log Analytics workspace resource ID for Sentinel.')
param logAnalyticsWorkspaceId string

@description('Tags to apply to all resources.')
param tags object = {}

resource defenderForServers 'Microsoft.Security/pricings@2023-01-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
  }
}

resource defenderForStorage 'Microsoft.Security/pricings@2023-01-01' = {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
  }
}

resource defenderForKeyVault 'Microsoft.Security/pricings@2023-01-01' = {
  name: 'KeyVaults'
  properties: {
    pricingTier: 'Standard'
  }
}

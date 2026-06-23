targetScope = 'subscription'

metadata name = 'Platform Management'
metadata description = 'Deploys centralized Log Analytics workspace, Automation Account, Data Collection Rules, and monitoring baseline.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Log Analytics workspace retention in days.')
param logRetentionDays int = 90

@description('Tags to apply to all resources.')
param tags object = {}

var resourceGroupName = 'rg-mgmt-prd-${location}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module logAnalytics '../../../modules/platform/log-analytics/main.bicep' = {
  name: 'log-analytics'
  scope: rg
  params: {
    location: location
    retentionInDays: logRetentionDays
    tags: tags
  }
}

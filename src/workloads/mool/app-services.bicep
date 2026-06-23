targetScope = 'resourceGroup'

metadata name = 'MOOL — App Services'
metadata description = 'Deploys App Service Plan and App Service instances for the MOOL application.'

@description('Azure region.')
param location string

@description('Environment code.')
param environment string

@description('Log Analytics workspace resource ID.')
param logAnalyticsWorkspaceId string

@description('Tags to apply.')
param tags object = {}

var appServicePlanName = 'asp-mool-${environment}-${location}'
var appServiceName = 'app-mool-${environment}-${location}'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: environment == 'prd' ? 'P2v3' : 'B2'
    tier: environment == 'prd' ? 'PremiumV3' : 'Basic'
  }
  properties: {
    reserved: false
  }
}

resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: appServiceName
  location: location
  tags: tags
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
}

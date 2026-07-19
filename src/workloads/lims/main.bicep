targetScope = 'subscription'

metadata name = 'Workload — lims'
metadata description = 'Orchestrates the full lims workload deployment: app services, SQL VMs, backup, and monitoring.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Environment code.')
@allowed(['dev', 'tst', 'acc', 'preprd', 'prd'])
param environment string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Recovery Services vault name.')
param recoveryServicesVaultName string = 'rsv-lims-${environment}-${location}'

@description('Tags to apply to all resources.')
param tags object = {}

var resourceGroupName = 'rg-lims-${environment}-${location}'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module appServices 'app-services.bicep' = {
  name: 'lims-app-services'
  scope: rg
  params: {
    location: location
    environment: environment
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags
  }
}

module backup 'backup.bicep' = {
  name: 'lims-backup'
  scope: rg
  params: {
    location: location
    vaultName: recoveryServicesVaultName
    tags: tags
  }
}

module monitoring 'monitoring.bicep' = {
  name: 'lims-monitoring'
  scope: rg
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags
  }
}

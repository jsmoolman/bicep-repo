using '../../../../src/workloads/lims/main.bicep'

param location = 'westeurope'
param environment = 'dev'
param logAnalyticsWorkspaceId = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-lims-dev-westeurope'
param tags = {
  Environment: 'dev'
  Workload: 'lims'
  ManagedBy: 'bicep-iac'
  Owner: 'team-lims'
  CostCenter: 'CC-1001'
}

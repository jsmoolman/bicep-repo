using '../../../../src/workloads/mool/main.bicep'

param location = 'westeurope'
param environment = 'dev'
param logAnalyticsWorkspaceId = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-mool-dev-westeurope'
param tags = {
  Environment: 'dev'
  Workload: 'mool'
  ManagedBy: 'bicep-iac'
  Owner: 'team-mool'
  CostCenter: 'CC-1001'
}

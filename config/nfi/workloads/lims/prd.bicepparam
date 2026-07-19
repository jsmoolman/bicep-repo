using '../../../../src/workloads/lims/main.bicep'

param location = 'westeurope'
param environment = 'prd'
param logAnalyticsWorkspaceId = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-lims-prd-westeu'
param tags = {
  Environment: 'prd'
  Workload: 'lims'
  ManagedBy: 'bicep-iac'
  Owner: 'team-lims'
  CostCenter: 'CC-1001'
}

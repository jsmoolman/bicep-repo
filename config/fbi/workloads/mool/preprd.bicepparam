using '../../../../src/workloads/mool/main.bicep'

param location                  = 'westeurope'
param environment               = 'preprd'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-mool-preprd-westeurope'
param tags = {
  Environment: 'preprd'
  Workload:    'mool'
  ManagedBy:   'bicep-iac'
  Owner:       'team-mool'
  CostCenter:  'CC-1001'
}

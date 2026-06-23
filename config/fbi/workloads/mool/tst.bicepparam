using '../../../../src/workloads/mool/main.bicep'

param location                  = 'westeurope'
param environment               = 'tst'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-mool-tst-westeurope'
param tags = {
  Environment: 'tst'
  Workload:    'mool'
  ManagedBy:   'bicep-iac'
  Owner:       'team-mool'
  CostCenter:  'CC-1001'
}

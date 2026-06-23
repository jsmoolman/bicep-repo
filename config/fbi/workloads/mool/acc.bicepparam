using '../../../../src/workloads/mool/main.bicep'

param location                  = 'westeurope'
param environment               = 'acc'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-mool-acc-westeurope'
param tags = {
  Environment: 'acc'
  Workload:    'mool'
  ManagedBy:   'bicep-iac'
  Owner:       'team-mool'
  CostCenter:  'CC-1001'
}

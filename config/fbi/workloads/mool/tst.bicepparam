using '../../../../src/workloads/lims/main.bicep'

param location                  = 'westeurope'
param environment               = 'tst'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-lims-tst-westeurope'
param tags = {
  Environment: 'tst'
  Workload:    'lims'
  ManagedBy:   'bicep-iac'
  Owner:       'team-lims'
  CostCenter:  'CC-1001'
}

using '../../../../src/workloads/lims/main.bicep'

param location                  = 'westeurope'
param environment               = 'acc'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-lims-acc-westeu'
param tags = {
  Environment: 'acc'
  Workload:    'lims'
  ManagedBy:   'bicep-iac'
  Owner:       'team-lims'
  CostCenter:  'CC-1001'
}

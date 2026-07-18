using '../../../../src/workloads/lims/main.bicep'

param location                  = 'westeurope'
param environment               = 'preprd'
param logAnalyticsWorkspaceId   = '' // TODO: replace with actual resource ID after platform/management deployment
param recoveryServicesVaultName = 'rsv-lims-preprd-westeurope'
param tags = {
  Environment: 'preprd'
  Workload:    'lims'
  ManagedBy:   'bicep-iac'
  Owner:       'team-lims'
  CostCenter:  'CC-1001'
}

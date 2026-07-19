using '../../../src/platform/core/main.bicep'

param managementGroupPrefix = 'nfi'
param location = 'westeurope'
param tags = {
  Environment: 'prd'
  Workload: 'platform-core'
  ManagedBy: 'bicep-iac'
  Owner: 'team-infrastructure'
  CostCenter: 'CC-0001'
}

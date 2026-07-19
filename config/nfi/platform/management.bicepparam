using '../../../src/platform/management/main.bicep'

param location = 'westeurope'
param logRetentionDays = 90
param tags = {
  Environment: 'prd'
  Workload: 'platform-management'
  ManagedBy: 'bicep-iac'
  Owner: 'team-infrastructure'
  CostCenter: 'CC-0001'
}

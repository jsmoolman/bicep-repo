using '../../../src/platform/connectivity/hub-spoke.bicep'

param location = 'westeurope'
param hubAddressPrefix = '10.0.0.0/16'
param tags = {
  Environment: 'prd'
  Workload: 'platform-connectivity'
  ManagedBy: 'bicep-iac'
  Owner: 'team-infrastructure'
  CostCenter: 'CC-0001'
}

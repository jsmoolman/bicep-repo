// Parameters for the LIMS VM Availability SLA Workbook v2. Service window: Mon-Fri 08:00-17:00 Europe/Amsterdam.
// Planned maintenance support via PlannedMaintenance_CL custom LAW table. Deploys into rg-lims-reports-mgmt-westeu
// (derived from centralLawResourceId).
using '../../../../src/observability/vm-availability-sla-dashboard-v2/main.bicep'

param workloadName = 'lims'

param centralLawResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourcegroups/rg-lims-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

param location = 'westeurope'

param subscriptionEnvironmentMappings = [
  {
    _comment: 'AZ-NFI-lims-mgt — management / reporting subscription'
    subscriptionId: 'cd9bed50-c972-49d0-83b0-b97bf801c804'
    environment: 'mgt'
  }
  {
    _comment: 'AZ-NFI-lims-dev — development subscription'
    subscriptionId: '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
    environment: 'dev'
  }
  {
    _comment: 'AZ-NFI-lims-tst — test subscription'
    subscriptionId: '1947d5e2-5ca8-4994-8f7d-5c380da19ef9'
    environment: 'tst'
  }
  {
    _comment: 'AZ-NFI-lims-acc — acceptance subscription'
    subscriptionId: 'b29525c8-045f-4793-b3cf-e93b5ff9bf74'
    environment: 'acc'
  }
  {
    _comment: 'AZ-NFI-lims-preprd — pre-production subscription'
    subscriptionId: '3999f5e2-435b-4b07-a28e-005ffe0a5607'
    environment: 'preprd'
  }
  {
    _comment: 'AZ-NFI-lims-prd — production subscription'
    subscriptionId: '786de6c9-1dd2-48d4-8436-1a6565a61799'
    environment: 'prd'
  }
]

param tags = {
  environment: 'management'
  purpose: 'lims'
}

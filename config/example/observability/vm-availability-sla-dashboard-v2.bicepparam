// Example parameters for the VM Availability SLA Workbook v2 — illustrates the
// shape a real deployment's parameter file must provide. Service window,
// subscription IDs, and resource names below are fictional.
using '../../../src/observability/vm-availability-sla-dashboard-v2/main.bicep'

param workloadName = 'contoso'

param centralLawResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-contoso-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

param location = 'westeurope'

param subscriptionEnvironmentMappings = [
  {
    _comment: 'Management / reporting subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000001'
    environment: 'mgt'
  }
  {
    _comment: 'Development subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000002'
    environment: 'dev'
  }
  {
    _comment: 'Test subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000003'
    environment: 'tst'
  }
  {
    _comment: 'Acceptance subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000004'
    environment: 'acc'
  }
  {
    _comment: 'Pre-production subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000005'
    environment: 'preprd'
  }
  {
    _comment: 'Production subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000006'
    environment: 'prd'
  }
]

param tags = {
  environment: 'management'
  purpose: 'contoso'
}

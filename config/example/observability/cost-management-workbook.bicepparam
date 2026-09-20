// Example parameters for the Cost Management Dashboard — illustrates the shape
// a real deployment's parameter file must provide. Subscription IDs,
// management-group ID, and resource names below are fictional.
//
// This workbook reads exclusively from the CostManagementSnapshot_CL Log
// Analytics table, populated by
// scripts/observability/Invoke-CostManagementSnapshotCollector.ps1 via
// .azuredevops/pipelines/collect-cost-management-snapshot.yml.
//
// managementGroupId and subscriptionEnvironmentMappings are also the
// authoritative configuration source for the collector script (read via
// `az bicep build-params`) — do not remove or restructure them for the
// workbook's sake alone.
using '../../../src/observability/cost-management-workbook/main.bicep'

param workloadName = 'contoso'

param workbookDisplayName = 'Cost Management Dashboard - contoso'

// Declared directly rather than derived from workspaceResourceId, so
// deployment always targets the intended subscription.
param workbookSubscriptionId = '00000000-0000-0000-0000-000000000001'

param workbookResourceGroupName = 'rg-contoso-reports-mgmt-westeu'

param location = 'westeurope'

param managementGroupId = '00000000-0000-0000-0000-000000000099'

param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-contoso-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

// Array order controls the Cost per Environment grid's display order
// (Total is always shown last). It has no effect on the collector's
// SubscriptionId -> Environment resolution, which is key-based.
param subscriptionEnvironmentMappings = [
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
  {
    _comment: 'Management / reporting subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000001'
    environment: 'mgt'
  }
]

param tags = {
  environment: 'management'
  purpose: 'contoso'
}

// Parameters for the LIMS Cost Management Dashboard.
//
// This workbook reads exclusively from the CostManagementSnapshot_CL Log
// Analytics table — it no longer calls the Azure Cost Management REST API
// itself (see modules/observability/cost-management-workbook/main.bicep for
// the full LAW-based query architecture). CostManagementSnapshot_CL is
// populated separately, on a manual-only basis today, by
// scripts/observability/Invoke-CostManagementSnapshotCollector.ps1 via
// .azuredevops/pipelines/collect-cost-management-snapshot.yml — see
// docs/operations.md for current commissioning state.
//
// Workbook hosting reuses the existing LIMS reporting resource group/location
// (same as the VM Availability SLA Dashboard v2) — this is a hosting-location
// decision only and is independent from workspaceResourceId below.
//
// managementGroupId is the Tenant Root Group (c7adbc6a-e0b3-4eb7-9403-ed7f7f48ec4b),
// per explicit customer confirmation. This workbook no longer uses this value to
// query Azure Cost Management (see the module's managementGroupId parameter
// description for why it is still declared here: resource-name/GUID stability,
// and this file's continued use as the separate collector's own authoritative
// Cost Management query-scope configuration, read directly via
// `az bicep build-params` from scripts/observability/Invoke-CostManagementSnapshotCollector.ps1).
// RBAC for the costing security group at this (or any) management-group scope
// is reviewed and applied separately, and is intentionally not part of this
// repository's authority — see docs/scope.md. Using the Tenant Root Group here
// should not be read as a recommendation to grant tenant-wide Cost Management
// visibility; that scope should be revisited once the costing security group's
// actual required boundary is confirmed.
//
// workspaceResourceId is the existing central Log Analytics Workspace (same one
// used by the VM Availability SLA Dashboard v2) that hosts CostManagementSnapshot_CL
// (see config/nfi/lims/observability/cost-management-data-foundation.bicepparam
// for the table/DCR that provisioned it — same workspaceResourceId value). This
// workbook queries that table directly and exclusively for all cost figures.
//
// subscriptionEnvironmentMappings below is read by both this workbook (only the
// environment values, for the Environment selector/grid zero-fill — LAW rows
// already carry their own Environment column, written by the collector) and,
// separately, by the collector script itself (both subscriptionId and
// environment, to build its own Cost Management query filter and Environment
// mapping). Do not remove or rename this parameter or its shape for the
// workbook's sake — the collector's configuration contract is unrelated to this
// refactor and must not be restructured.
using '../../../../src/observability/cost-management-workbook/main.bicep'

param workloadName = 'lims'

param workbookDisplayName = 'Cost Management Dashboard - lims'

// Explicit, independent hosting-subscription decision — this is the AZ-NFI-lims-mgt
// subscription (same one workspaceResourceId below already points at), but it is
// declared here directly rather than derived from workspaceResourceId, so the
// deployment always targets the intended subscription regardless of the Azure
// DevOps service connection's ambient/default subscription context.
param workbookSubscriptionId = 'cd9bed50-c972-49d0-83b0-b97bf801c804'

param workbookResourceGroupName = 'rg-lims-reports-mgmt-westeu'

param location = 'westeurope'

param managementGroupId = 'c7adbc6a-e0b3-4eb7-9403-ed7f7f48ec4b'

param workspaceResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourcegroups/rg-lims-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

// Array order below is authoritative for the Cost per Environment grid's
// business display order (dev, tst, acc, preprd, prd, mgt, then Total last)
// — see modules/observability/cost-management-workbook/main.bicep's
// EnvironmentSortOrder derivation. It has no effect on the collector's
// SubscriptionId -> Environment resolution, which is key-based (by
// subscriptionId) and therefore unaffected by array order. Subscription
// IDs and environment names below are unchanged from before; only the
// array's order has changed.
param subscriptionEnvironmentMappings = [
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
  {
    _comment: 'AZ-NFI-lims-mgt — management / reporting subscription'
    subscriptionId: 'cd9bed50-c972-49d0-83b0-b97bf801c804'
    environment: 'mgt'
  }
]

param tags = {
  environment: 'management'
  purpose: 'lims'
}

// Parameters for the LIMS Cost Management LAW ingestion foundation.
//
// This creates only the CostManagementSnapshot_CL custom table and its
// Direct-ingestion Data Collection Rule against the existing central LIMS
// reporting Log Analytics workspace (same workspace already reused as a
// stateless KQL compute engine by the Cost Management Dashboard workbook).
// No workspace, resource group, DCE, identity, or role assignment is created.
//
// The resource group hosting the table/DCR is derived from workspaceResourceId
// by the reusable entrypoint — it is intentionally not duplicated here.
//
// dataCollectionEndpointResourceId is intentionally empty: LIMS does not have a
// Data Collection Endpoint yet (insufficient private-networking IP address space
// for that future design). The DCR is provisioned with kind: Direct and works
// through its own Direct logs-ingestion endpoint until a DCE is supplied here in
// a future configuration change — see docs/operations.md.
//
// Operational prerequisite (outside this repository's authority, not performed
// here): the Azure DevOps service principal that will run the future scheduled
// collector requires the "Monitoring Metrics Publisher" role at this DCR's scope
// before it can ingest data through it. That RBAC assignment is a separate
// customer/user action after this DCR exists.
using '../../../../src/observability/cost-management-data-foundation/main.bicep'

param workspaceResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourceGroups/rg-lims-reports-mgmt-westeu/providers/Microsoft.OperationalInsights/workspaces/law-reports-mgmt-westeu'

param location = 'westeurope'

param tableName = 'CostManagementSnapshot_CL'

param dataCollectionRuleName = 'dcr-cost-snapshot-westeu'

param retentionInDays = 730

param totalRetentionInDays = 730

param dataCollectionEndpointResourceId = ''

param tags = {
  environment: 'management'
  purpose: 'lims'
}

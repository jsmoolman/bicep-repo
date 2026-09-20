// Example parameters for the Cost Management LAW ingestion foundation —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription ID and resource names below are fictional.
//
// This creates only the CostManagementSnapshot_CL custom table and its
// Direct-ingestion Data Collection Rule against an existing central Log
// Analytics workspace. No workspace, resource group, DCE, identity, or role
// assignment is created.
//
// The resource group hosting the table/DCR is derived from workspaceResourceId
// by the reusable entrypoint — it is intentionally not duplicated here.
//
// dataCollectionEndpointResourceId is intentionally empty in this example —
// the DCR is provisioned with kind: Direct and works through its own Direct
// logs-ingestion endpoint until a Data Collection Endpoint is supplied here in
// a future configuration change; see docs/operations.md.
//
// Operational prerequisite (outside this repository's authority, not
// performed here): the collector's identity requires the "Monitoring Metrics
// Publisher" role at this DCR's scope before it can ingest data through it.
using '../../../src/observability/cost-management-data-foundation/main.bicep'

param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso-reports-mgmt-westeu/providers/Microsoft.OperationalInsights/workspaces/law-reports-mgmt-westeu'

param location = 'westeurope'

param tableName = 'CostManagementSnapshot_CL'

param dataCollectionRuleName = 'dcr-cost-snapshot-westeu'

param retentionInDays = 730

param totalRetentionInDays = 730

param dataCollectionEndpointResourceId = ''

param tags = {
  environment: 'management'
  purpose: 'contoso'
}

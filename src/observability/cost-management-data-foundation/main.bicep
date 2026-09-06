metadata description = 'Subscription-scoped orchestrator for the Cost Management LAW ingestion foundation: deploys a custom Log Analytics table plus a Direct-ingestion Data Collection Rule against an existing Log Analytics workspace, into the subscription and resource group that already host that workspace. Deploys no workspace, resource group, DCE, identity, or role assignment.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing Log Analytics workspace that will host the custom table and receive DCR-ingested data. Both the target subscription and the target resource group are derived from this ID — there is no separate/duplicate subscription or resource-group parameter. workspaceResourceId is the single authoritative target.')
param workspaceResourceId string

@description('Azure region for the Data Collection Rule resource.')
param location string = 'westeurope'

@description('Name of the custom Log Analytics table to create, e.g. CostManagementSnapshot_CL.')
param tableName string

@description('Name of the Data Collection Rule to create, e.g. dcr-cost-management-snapshot-westeu.')
param dataCollectionRuleName string

@description('Analytics-plan interactive retention in days for the custom table (4-730).')
param retentionInDays int = 730

@description('Total retention in days for the custom table (4-4383).')
param totalRetentionInDays int = 730

@description('Optional: full ARM resource ID of an existing Data Collection Endpoint. Empty string (current LIMS state) means no DCE is configured and the DCR uses its own Direct logs-ingestion endpoint.')
param dataCollectionEndpointResourceId string = ''

@description('Tags applied to the Data Collection Rule.')
param tags object = {}

// ─── Derived scope ────────────────────────────────────────────────────────────
// Both the subscription ID and the resource group are parsed out of
// workspaceResourceId rather than accepted as separate parameters: the
// workspace resource ID, in its canonical
// /subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/...
// shape, is already the one authoritative source of truth for where the
// workspace lives, and custom tables must be deployed into that same
// subscription and resource group (they are children of the workspace). Using
// the two-argument resourceGroup(subscriptionId, name) scope form below makes
// the target subscription explicit and authoritative, rather than relying on
// whichever subscription happens to be the ambient context of the
// `az deployment sub create` call that runs this composition.

var workspaceIdSegments = split(workspaceResourceId, '/')
var workspaceSubscriptionId = workspaceIdSegments[2]
var workspaceResourceGroupName = workspaceIdSegments[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module foundation '../../../modules/observability/cost-management-data-foundation/main.bicep' = {
  name: 'cost-mgmt-data-foundation-${take(uniqueString(workspaceResourceId, tableName, dataCollectionRuleName), 8)}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceResourceId: workspaceResourceId
    location: location
    tableName: tableName
    dataCollectionRuleName: dataCollectionRuleName
    retentionInDays: retentionInDays
    totalRetentionInDays: totalRetentionInDays
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    tags: tags
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Name of the deployed custom Log Analytics table.')
output tableName string = foundation.outputs.tableName

@description('DCR stream name that accepts data for this table.')
output streamName string = foundation.outputs.streamName

@description('Full ARM resource ID of the deployed Data Collection Rule.')
output dataCollectionRuleResourceId string = foundation.outputs.dataCollectionRuleResourceId

@description('Immutable ID of the deployed Data Collection Rule, required by the Logs Ingestion API.')
output dataCollectionRuleImmutableId string = foundation.outputs.dataCollectionRuleImmutableId

@description('''The Direct DCR logs-ingestion endpoint (properties.endpoints.logsIngestion) of the deployed Data Collection Rule — the endpoint this DCR exposes on its own. This is the value the future collector configures as its logsIngestionEndpoint today (no Data Collection Endpoint, DCE, exists for LIMS). It does not automatically change if a DCE is associated with this DCR in the future: a Direct DCR may retain its own endpoint even once associated with a DCE, and the caller chooses which endpoint to send data to. See the reusable module output of the same name for the two separate changes required to adopt DCE-routed ingestion later.''')
output directLogsIngestionEndpoint string = foundation.outputs.directLogsIngestionEndpoint

@description('Resource group hosting the workspace, table, and DCR (derived from workspaceResourceId).')
output workspaceResourceGroupName string = workspaceResourceGroupName

@description('Subscription ID hosting the workspace, table, and DCR (derived from workspaceResourceId).')
output workspaceSubscriptionId string = workspaceSubscriptionId

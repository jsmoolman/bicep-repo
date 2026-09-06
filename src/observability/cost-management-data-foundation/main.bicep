metadata description = 'Subscription-scoped orchestrator for the Cost Management LAW ingestion foundation: deploys a custom Log Analytics table plus a Direct-ingestion Data Collection Rule against an existing Log Analytics workspace, into the resource group that already hosts that workspace. Deploys no workspace, resource group, DCE, identity, or role assignment.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing Log Analytics workspace that will host the custom table and receive DCR-ingested data. The target resource group is derived from this ID — there is no separate/duplicate resource-group parameter.')
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
// The resource group is parsed out of workspaceResourceId rather than accepted as
// a second parameter: the workspace's resource ID is already the one
// authoritative source of truth for where it lives, and custom tables must be
// deployed into that same resource group (they are children of the workspace).

var workspaceResourceGroupName = split(workspaceResourceId, '/')[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module foundation '../../../modules/observability/cost-management-data-foundation/main.bicep' = {
  name: 'cost-mgmt-data-foundation-${take(uniqueString(workspaceResourceId, tableName, dataCollectionRuleName), 8)}'
  scope: resourceGroup(workspaceResourceGroupName)
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

@description('Direct logs-ingestion endpoint URL of the deployed Data Collection Rule.')
output directLogsIngestionEndpoint string = foundation.outputs.directLogsIngestionEndpoint

@description('Resource group hosting the workspace, table, and DCR (derived from workspaceResourceId).')
output workspaceResourceGroupName string = workspaceResourceGroupName

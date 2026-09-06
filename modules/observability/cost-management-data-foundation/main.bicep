metadata description = 'Persisted reporting-data foundation for the Cost Management Dashboard: a custom Log Analytics table (CostManagementSnapshot_CL-shaped) plus a Direct-ingestion Data Collection Rule targeting an existing Log Analytics workspace. Creates only the table and the DCR against that existing workspace — no workspace, resource group, DCE, identity, role assignment, or scheduler is created here. A future collector milestone will populate this table via the Logs Ingestion API; this milestone ships the destination contract only.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing Log Analytics workspace that will host the custom table and receive DCR-ingested data. This module must be deployed into the same resource group as this workspace (custom tables are always children of their parent workspace).')
param workspaceResourceId string

@description('Azure region for the Data Collection Rule resource. The custom table itself has no location property of its own — it always inherits its parent workspaces location.')
param location string = 'westeurope'

@description('Name of the custom Log Analytics table to create, e.g. CostManagementSnapshot_CL. Not hard-coded here so this module stays reusable for other projects/tables with the same shape.')
@minLength(4)
@maxLength(63)
param tableName string

@description('Name of the Data Collection Rule to create, e.g. dcr-cost-management-snapshot-westeu. Kept configurable rather than hard-coded so a future project can supply its own instance name.')
param dataCollectionRuleName string

@description('Analytics-plan interactive retention in days for the custom table (4-730). Does not modify workspace-wide retention.')
@minValue(4)
@maxValue(730)
param retentionInDays int = 730

@description('Total retention in days for the custom table, including any archive period (4-4383). Does not modify workspace-wide retention.')
@minValue(4)
@maxValue(4383)
param totalRetentionInDays int = 730

@description('''Optional: full ARM resource ID of an existing Data Collection Endpoint (DCE). Empty string (the current LIMS state — no DCE exists yet due to insufficient private-networking IP address space) means the DCR is provisioned without a DCE and works through its own Direct logs-ingestion endpoint. Supplying a DCE resource ID here in the future switches properties.dataCollectionEndpointId without any change to the table schema, stream declaration, destination, data flow, or collector/workbook ingestion contract. This module never invents or creates a DCE.''')
param dataCollectionEndpointResourceId string = ''

@description('Tags applied to the Data Collection Rule. The custom table resource does not support tags.')
param tags object = {}

// ─── Single-sourced column schema ─────────────────────────────────────────────
// One canonical list drives BOTH the table's schema.columns and the DCR stream
// declaration's columns, so the two cannot drift independently (same names, same
// column count, same logical type, enforced by construction rather than by
// convention). The two Azure REST APIs happen to use different literal casing for
// the same "datetime" concept — Microsoft.OperationalInsights/workspaces/tables
// expects "dateTime", Microsoft.Insights/dataCollectionRules stream declarations
// expect "datetime" — so a small per-API type-token map translates the single
// logical "datetime" kind to each API's expected literal without duplicating the
// column list itself.

var columnDefinitions = [
  { name: 'TimeGenerated', kind: 'datetime' }
  { name: 'Project', kind: 'string' }
  { name: 'SubscriptionId', kind: 'string' }
  { name: 'Environment', kind: 'string' }
  { name: 'BillingMonth', kind: 'datetime' }
  { name: 'ServiceName', kind: 'string' }
  { name: 'ActualCost', kind: 'real' }
  { name: 'Currency', kind: 'string' }
  { name: 'CollectionRunId', kind: 'string' }
]

var tableColumnTypeByKind = {
  datetime: 'dateTime'
  string: 'string'
  real: 'real'
}

var streamColumnTypeByKind = {
  datetime: 'datetime'
  string: 'string'
  real: 'real'
}

var tableColumns = [for c in columnDefinitions: {
  name: c.name
  type: tableColumnTypeByKind[c.kind]
}]

var streamColumns = [for c in columnDefinitions: {
  name: c.name
  type: streamColumnTypeByKind[c.kind]
}]

// ─── Derived names ────────────────────────────────────────────────────────────

// Workspace name parsed from its full resource ID — the caller supplies only the
// one authoritative resource ID; this module never needs a second/duplicate
// "workspace name" configuration value.
var workspaceName = last(split(workspaceResourceId, '/'))

// Stream name is derived from the approved table name (per the DCR "Custom-<table>"
// convention) rather than duplicating the literal separately.
var streamName = 'Custom-${tableName}'

// Internal friendly name for the single Log Analytics destination — referenced by
// name (not resource ID) from the data flow, per the DCR destinations contract.
var logAnalyticsDestinationName = 'law-destination'

// ─── Existing Log Analytics workspace ─────────────────────────────────────────
// Referenced only to attach the custom table as its child resource. No
// workspace-wide property (SKU, networking, retention, RBAC, identity, public/
// private access) is read or written here.

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

// ─── Custom table ──────────────────────────────────────────────────────────────
// Analytics plan, append-only 9-column schema. No workspace-global retention is
// touched — retentionInDays/totalRetentionInDays here are table-scoped properties
// only.

resource table 'Microsoft.OperationalInsights/workspaces/tables@2025-07-01' = {
  parent: workspace
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    totalRetentionInDays: totalRetentionInDays
    schema: {
      name: tableName
      columns: tableColumns
    }
  }
}

// ─── Data Collection Rule ──────────────────────────────────────────────────────
// kind: Direct — obtains a Direct logs-ingestion endpoint now (no DCE available
// yet). One stream, one destination (the existing LAW only), one schema-preserving
// data flow. dataCollectionEndpointId is included only when a DCE resource ID is
// actually supplied — omitted (not present in the properties object at all) for
// the current no-DCE LIMS state, so the DCR relies on its own Direct endpoint.

var dcrPropertiesBase = {
  streamDeclarations: {
    '${streamName}': {
      columns: streamColumns
    }
  }
  destinations: {
    logAnalytics: [
      {
        name: logAnalyticsDestinationName
        workspaceResourceId: workspaceResourceId
      }
    ]
  }
  dataFlows: [
    {
      streams: [
        streamName
      ]
      destinations: [
        logAnalyticsDestinationName
      ]
      outputStream: streamName
    }
  ]
}

var dcrProperties = empty(dataCollectionEndpointResourceId)
  ? dcrPropertiesBase
  : union(dcrPropertiesBase, { dataCollectionEndpointId: dataCollectionEndpointResourceId })

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dataCollectionRuleName
  location: location
  kind: 'Direct'
  tags: tags
  properties: dcrProperties
  // Explicit, smallest-justified dependency: the DCR's data flow/stream
  // declaration references the custom table only by stream-name string, so Bicep
  // cannot infer the table-before-DCR ordering that the Azure Monitor custom-
  // table/DCR workflow requires. This is the only dependsOn in this module.
  dependsOn: [
    table
  ]
}

// ─── Outputs ──────────────────────────────────────────────────────────────────
// immutableId and endpoints.logsIngestion are read-only, server-populated DCR
// properties — Bicep resolves them via an implicit reference() against the
// deployed resource symbol, so no separate reference()/listKeys()-style call or
// fabricated value is needed here.

@description('Name of the deployed custom Log Analytics table.')
output tableName string = table.name

@description('DCR stream name that accepts data for this table (Custom-<tableName>).')
output streamName string = streamName

@description('Full ARM resource ID of the deployed Data Collection Rule.')
output dataCollectionRuleResourceId string = dcr.id

@description('Immutable ID of the deployed Data Collection Rule, required by the Logs Ingestion API.')
output dataCollectionRuleImmutableId string = dcr.properties.immutableId

@description('Direct logs-ingestion endpoint URL of the deployed Data Collection Rule (server-populated; becomes a DCE endpoint transparently if dataCollectionEndpointResourceId is supplied in a future configuration).')
output directLogsIngestionEndpoint string = dcr.properties.endpoints.logsIngestion

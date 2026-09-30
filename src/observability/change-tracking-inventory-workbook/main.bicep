metadata description = 'Subscription-scoped orchestrator for the Change Tracking & Inventory (CTI) Dashboard Workbook, which reads exclusively from the existing ConfigurationChange and ConfigurationData Log Analytics tables already populated by the CTI foundation (see modules/observability/change-tracking-inventory-foundation/main.bicep) and onboarded via the CTI policy pipeline (see modules/observability/change-tracking-inventory-policy/main.bicep). Workbook hosting (subscription/resource group/location) is configured independently from the Log Analytics workspace that hosts those tables — the two are unrelated inputs that happen to coincide only when a project bicepparam file says so. This orchestrator creates or modifies no DCR, policy assignment, identity, VM extension, DCR association, or LAW configuration.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Drives parameter labelling, the deterministic workbook name/GUID seed, and — via the workbook\'s own {workloadName} text substitution — the Computer-name prefix used in every KQL query (passed through to the module).')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name.')
param workbookDisplayName string

@description('Subscription ID that hosts the workbook resource group below. An explicit, independent configuration decision — deliberately not derived from workspaceResourceId (that ARM ID identifies an unrelated resource, the Log Analytics workspace this workbook queries) or from the deployment\'s ambient/service-connection subscription context, which is not guaranteed to be the intended hosting subscription.')
param workbookSubscriptionId string

@description('Name of the existing resource group, in the workbookSubscriptionId subscription above, that will host the workbook resource.')
param workbookResourceGroupName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Full ARM resource ID of the existing central Log Analytics workspace that already receives CTI ConfigurationChange/ConfigurationData telemetry from the onboarded VMs. This workbook queries those two tables directly and exclusively for all reporting.')
param workspaceResourceId string

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Module ───────────────────────────────────────────────────────────────────

module workbook '../../../modules/observability/change-tracking-inventory-workbook/main.bicep' = {
  name: 'cti-workbook-${take(uniqueString(workloadName, workspaceResourceId), 8)}'
  scope: resourceGroup(workbookSubscriptionId, workbookResourceGroupName)
  params: {
    workloadName:        workloadName
    workbookDisplayName: workbookDisplayName
    location:            location
    workspaceResourceId: workspaceResourceId
    tags:                tags
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed workbook.')
output workbookResourceId string = workbook.outputs.workbookResourceId

@description('GUID name of the deployed workbook resource.')
output workbookName string = workbook.outputs.workbookName

@description('Display name of the deployed workbook.')
output workbookDisplayName string = workbook.outputs.workbookDisplayName

@description('Resource group hosting the workbook.')
output workbookResourceGroupName string = workbookResourceGroupName

@description('Subscription ID hosting the workbook (deployment diagnostics only — proves the deployment targeted the intended explicit subscription rather than the service connection\'s ambient/default one).')
output workbookSubscriptionId string = workbookSubscriptionId

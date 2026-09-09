metadata description = 'Subscription-scoped orchestrator for the Cost Management Dashboard Workbook, which reads exclusively from the CostManagementSnapshot_CL Log Analytics table (see modules/observability/cost-management-workbook/main.bicep). Workbook hosting (subscription/resource group/location) is configured independently from the Log Analytics workspace that hosts CostManagementSnapshot_CL — the two are unrelated inputs that happen to coincide only when a project bicepparam file says so.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Drives parameter labelling, the deterministic workbook name seed, and (passed through to the module) the Project value this workbook filters CostManagementSnapshot_CL by — this must match the value the collector writes for this workload.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name.')
param workbookDisplayName string

@description('Name of the existing resource group, in this deployments target subscription, that will host the workbook resource. Independent from the Cost Management query scope below.')
param workbookResourceGroupName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('''Historical Azure Cost Management query-scope management group ID. This workbook no longer queries Azure Cost Management directly — it is passed through unchanged to the module only to preserve the workbook''s existing deterministic resource name/GUID, and because the checked-in cost-management-workbook.bicepparam file that declares it is also the separate collector script''s own authoritative configuration source. See modules/observability/cost-management-workbook/main.bicep for the full explanation.''')
param managementGroupId string

@description('''Full ARM resource ID of the existing central Log Analytics workspace that hosts CostManagementSnapshot_CL. This workbook queries that table directly and exclusively for all cost figures.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. This workbook uses only the distinct environment values (for the Environment selector and grid zero-fill); subscriptionId is retained in the shape only because the separate collector script reads this exact same array from the same checked-in parameter file.
Known LIMS values are pre-populated in config/nfi/lims/observability/cost-management-workbook.bicepparam.''')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Module ───────────────────────────────────────────────────────────────────

module workbook '../../../modules/observability/cost-management-workbook/main.bicep' = {
  name: 'cost-mgmt-workbook-${take(uniqueString(workloadName, managementGroupId, workspaceResourceId), 8)}'
  scope: resourceGroup(workbookResourceGroupName)
  params: {
    workloadName:                    workloadName
    workbookDisplayName:             workbookDisplayName
    location:                        location
    managementGroupId:               managementGroupId
    workspaceResourceId:             workspaceResourceId
    subscriptionEnvironmentMappings: subscriptionEnvironmentMappings
    tags:                            tags
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

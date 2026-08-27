metadata description = 'Subscription-scoped orchestrator for the Cost Management single-query pivot Workbook. Workbook hosting (subscription/resource group/location) is configured independently from the Azure Cost Management query scope (management group) — the two are unrelated inputs that happen to coincide only when a project bicepparam file says so.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Drives parameter labelling and the deterministic workbook name seed.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name.')
param workbookDisplayName string

@description('Name of the existing resource group, in this deployments target subscription, that will host the workbook resource. Independent from the Cost Management query scope below.')
param workbookResourceGroupName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Management group ID used as the Azure Cost Management query scope. Independent from the workbook hosting resource group above. The query still explicitly filters to only the configured subscriptionEnvironmentMappings.')
param managementGroupId string

@description('''Full ARM resource ID of an existing Log Analytics workspace, reused purely as a stateless KQL compute engine for pivot/trend calculation. No Cost Management data is ingested into or queried from this workspace.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings driving both the Cost Management query filter and the Environment pivot. Each element: { subscriptionId: string, environment: string }.
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

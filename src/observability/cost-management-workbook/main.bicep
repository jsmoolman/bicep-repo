metadata description = 'Subscription-scoped orchestrator for the Cost Management Dashboard Workbook (see modules/observability/cost-management-workbook/main.bicep). Workbook hosting (subscription/resource group/location) is configured independently from the Log Analytics workspace that hosts CostManagementSnapshot_CL.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Drives parameter labelling, the deterministic workbook name, and the Project value this workbook filters CostManagementSnapshot_CL by. Must match the collector script\'s value.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name.')
param workbookDisplayName string

@description('Subscription ID hosting the workbook resource group below. Declared explicitly rather than derived from workspaceResourceId or the deployment\'s ambient subscription context.')
param workbookSubscriptionId string

@description('Name of the existing resource group, in workbookSubscriptionId, that hosts the workbook resource.')
param workbookResourceGroupName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Cost Management query-scope management group ID. Passed through to the module for resource-name/GUID stability and because the collector script reads it from the same parameter file.')
param managementGroupId string

@description('ARM resource ID of the Log Analytics workspace hosting CostManagementSnapshot_CL.')
param workspaceResourceId string

@description('Array of { subscriptionId, environment } mappings. Only the distinct environment values are used (Environment selector, grid zero-fill, display order); subscriptionId is retained because the collector script reads this same array.')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Module ───────────────────────────────────────────────────────────────────

module workbook '../../../modules/observability/cost-management-workbook/main.bicep' = {
  name: 'cost-mgmt-workbook-${take(uniqueString(workloadName, managementGroupId, workspaceResourceId), 8)}'
  scope: resourceGroup(workbookSubscriptionId, workbookResourceGroupName)
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

@description('Subscription ID hosting the workbook (deployment diagnostics only).')
output workbookSubscriptionId string = workbookSubscriptionId

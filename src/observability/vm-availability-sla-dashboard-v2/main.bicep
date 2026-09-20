metadata description = 'Subscription-scoped orchestrator for the VM Availability SLA Workbook v2. Deploys the workbook into the same resource group as the central Log Analytics Workspace. Service window: Mon–Fri 08:00–17:00 Europe/Amsterdam. Includes planned maintenance support via PlannedMaintenance_CL custom LAW table.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload short code (e.g. "contoso"). Drives the workbook display name and title.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Full ARM resource ID of the central Log Analytics Workspace. The orchestrator derives the target resource group from this single input — no separate RG parameter needed.')
param centralLawResourceId string

@description('Azure region. Must match the central LAW region. Defaults to West Europe.')
param location string = 'westeurope'

@description('''Subscription-to-environment mappings embedded in the workbook KQL datatable.
Each element: { subscriptionId: string, environment: string }.
See config/example/observability/vm-availability-sla-dashboard-v2.bicepparam for the expected shape.''')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource. Free-form for cross-workload reuse.')
param tags object = {}

// ─── Derivations ──────────────────────────────────────────────────────────────
// The workbook deploys into the same resource group as the central LAW, following
// the project convention: derive everything possible from centralLawResourceId.

var lawParts             = split(centralLawResourceId, '/')
var lawResourceGroupName = lawParts[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module workbook '../../../modules/observability/vm-availability-sla-dashboard-v2/main.bicep' = {
  name: 'workbook-v2-${take(uniqueString(workloadName, centralLawResourceId), 8)}'
  scope: resourceGroup(lawResourceGroupName)
  params: {
    workloadName:                    workloadName
    workspaceResourceId:             centralLawResourceId
    location:                        location
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

@description('Resource group that hosts the workbook (same as the central LAW).')
output workbookResourceGroupName string = lawResourceGroupName

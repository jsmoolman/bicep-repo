metadata description = 'Subscription-scoped orchestrator for the Change Tracking & Inventory (CTI) foundation: deploys a dedicated Data Collection Rule and the ChangeTracking solution against an existing Log Analytics workspace, into the subscription and resource group that already host that workspace. Deploys no workspace, VM extension, DCR association, policy assignment, managed identity, or role assignment.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Subscription ID that hosts the existing Log Analytics workspace. The Change Tracking DCR and solution must be deployed into this same subscription and resource group as the workspace.')
param workspaceSubscriptionId string

@description('Resource group name that hosts the existing Log Analytics workspace.')
param workspaceResourceGroupName string

@description('Name of the existing Log Analytics workspace that will receive Change Tracking data.')
param workspaceName string

@description('Azure region for the Data Collection Rule and the ChangeTracking solution.')
param location string = 'westeurope'

@description('Name of the Data Collection Rule to create, e.g. dcr-cti-example-westeu.')
param dataCollectionRuleName string

@description('Tags applied to the Data Collection Rule and the ChangeTracking solution.')
param tags object = {}

// ─── Module ───────────────────────────────────────────────────────────────────

module foundation '../../../modules/observability/change-tracking-inventory-foundation/main.bicep' = {
  name: 'cti-foundation-${take(uniqueString(workspaceSubscriptionId, workspaceResourceGroupName, workspaceName, dataCollectionRuleName), 8)}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    location: location
    dataCollectionRuleName: dataCollectionRuleName
    tags: tags
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed Data Collection Rule.')
output dataCollectionRuleResourceId string = foundation.outputs.dataCollectionRuleResourceId

@description('Immutable ID of the deployed Data Collection Rule.')
output dataCollectionRuleImmutableId string = foundation.outputs.dataCollectionRuleImmutableId

@description('Full ARM resource ID of the deployed ChangeTracking solution.')
output changeTrackingSolutionResourceId string = foundation.outputs.changeTrackingSolutionResourceId

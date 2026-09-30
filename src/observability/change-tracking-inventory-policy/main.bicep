metadata description = 'Subscription-scoped orchestrator for the Change Tracking & Inventory (CTI) policy assignment: assigns Microsoft\'s built-in "Enable ChangeTracking and Inventory for virtual machines" initiative against the subscription the deployment targets. Deploys no managed identity, role assignment, VM extension, or DCR association.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the policy assignment.')
param assignmentName string

@description('Azure region recorded on the policy assignment.')
param location string = 'westeurope'

@description('Full resource ID of the built-in initiative (or policy definition) to assign.')
param policyDefinitionId string

@description('Display name recorded on the policy assignment.')
param displayName string = 'Enable ChangeTracking and Inventory for virtual machines'

@description('Enforcement mode for the policy assignment.')
param enforcementMode string = 'Default'

@description('Full resource ID of the existing user-assigned managed identity to use as the policy assignment/remediation identity. This identity, and any RBAC it holds, is not created or modified here.')
param identityResourceId string

@description('Value of the initiative\'s bringYourOwnUserAssignedManagedIdentity parameter.')
param bringYourOwnUserAssignedManagedIdentity bool = false

@description('Value of the initiative\'s restrictBringYourOwnUserAssignedIdentityToSubscription parameter.')
param restrictBringYourOwnUserAssignedIdentityToSubscription bool = true

@description('Value of the initiative\'s builtInIdentityResourceGroupLocation parameter.')
param builtInIdentityResourceGroupLocation string = 'westeurope'

@description('Value of the initiative\'s listOfApplicableLocations parameter.')
param listOfApplicableLocations array

@description('Value of the initiative\'s effect parameter.')
param effect string = 'DeployIfNotExists'

@description('Full resource ID of the target environment\'s Change Tracking & Inventory Data Collection Rule (value of the initiative\'s dcrResourceId parameter).')
param dcrResourceId string

// ─── Module ───────────────────────────────────────────────────────────────────

module policy '../../../modules/observability/change-tracking-inventory-policy/main.bicep' = {
  name: 'cti-policy-${take(uniqueString(assignmentName, policyDefinitionId, dcrResourceId), 8)}'
  params: {
    assignmentName: assignmentName
    location: location
    policyDefinitionId: policyDefinitionId
    displayName: displayName
    enforcementMode: enforcementMode
    identityResourceId: identityResourceId
    bringYourOwnUserAssignedManagedIdentity: bringYourOwnUserAssignedManagedIdentity
    restrictBringYourOwnUserAssignedIdentityToSubscription: restrictBringYourOwnUserAssignedIdentityToSubscription
    builtInIdentityResourceGroupLocation: builtInIdentityResourceGroupLocation
    listOfApplicableLocations: listOfApplicableLocations
    effect: effect
    dcrResourceId: dcrResourceId
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed policy assignment.')
output policyAssignmentId string = policy.outputs.policyAssignmentId

@description('Name of the deployed policy assignment.')
output policyAssignmentName string = policy.outputs.policyAssignmentName

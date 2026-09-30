metadata description = 'Assigns Microsoft\'s built-in "Enable ChangeTracking and Inventory for virtual machines" initiative (policySetDefinitions/92a36f05-ebc9-4bba-9128-b47ad2ea3354) at subscription scope, using an existing user-assigned managed identity as the policy assignment/remediation identity. Creates exactly one Microsoft.Authorization/policyAssignments resource. Creates no managed identity, role assignment, VM extension, or DCR association — those remain owned by the built-in initiative and its own remediation tasks.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the policy assignment.')
param assignmentName string

@description('Azure region recorded on the policy assignment. Required by ARM whenever a policy assignment carries a managed identity.')
param location string

@description('Full resource ID of the built-in initiative (or policy definition) to assign.')
param policyDefinitionId string

@description('Display name recorded on the policy assignment.')
param displayName string

@description('Enforcement mode for the policy assignment.')
param enforcementMode string = 'Default'

@description('Full resource ID of the existing user-assigned managed identity to use as the policy assignment/remediation identity. This identity, and any RBAC it holds, is not created or modified by this module.')
param identityResourceId string

@description('Value of the initiative\'s bringYourOwnUserAssignedManagedIdentity parameter.')
param bringYourOwnUserAssignedManagedIdentity bool

@description('Value of the initiative\'s restrictBringYourOwnUserAssignedIdentityToSubscription parameter.')
param restrictBringYourOwnUserAssignedIdentityToSubscription bool

@description('Value of the initiative\'s builtInIdentityResourceGroupLocation parameter.')
param builtInIdentityResourceGroupLocation string

@description('Value of the initiative\'s listOfApplicableLocations parameter.')
param listOfApplicableLocations array

@description('Value of the initiative\'s effect parameter.')
param effect string

@description('Full resource ID of the target environment\'s Change Tracking & Inventory Data Collection Rule (value of the initiative\'s dcrResourceId parameter).')
param dcrResourceId string

// ─── Policy assignment ───────────────────────────────────────────────────────
// definitionVersion is intentionally not set: the proven reference assignment
// leaves it unpinned and lets the service track the initiative's effective
// version. Only the six proven initiative parameters are supplied.

resource assignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: assignmentName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    displayName: displayName
    policyDefinitionId: policyDefinitionId
    enforcementMode: enforcementMode
    parameters: {
      bringYourOwnUserAssignedManagedIdentity: {
        value: bringYourOwnUserAssignedManagedIdentity
      }
      restrictBringYourOwnUserAssignedIdentityToSubscription: {
        value: restrictBringYourOwnUserAssignedIdentityToSubscription
      }
      builtInIdentityResourceGroupLocation: {
        value: builtInIdentityResourceGroupLocation
      }
      listOfApplicableLocations: {
        value: listOfApplicableLocations
      }
      effect: {
        value: effect
      }
      dcrResourceId: {
        value: dcrResourceId
      }
    }
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed policy assignment.')
output policyAssignmentId string = assignment.id

@description('Name of the deployed policy assignment.')
output policyAssignmentName string = assignment.name

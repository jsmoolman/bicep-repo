metadata description = 'Subscription-scoped orchestrator for the LIMS WS2025 DEV v2 patch-onboarding pilot: deploys exactly four Microsoft built-in Azure Policy assignments (two per VM), individually resource-scoped to the two replacement LIMS DEV v2 virtual machines already created by src/compute/lims-ws2025-dev-foundation, into the same existing resource group. Deploys no VNet, subnet, Key Vault, Disk Encryption Set, maintenance configuration, dynamic scope, direct/static maintenance assignment, identity, or RBAC resource not explicitly covered by the LIMS WS2025 DEV v2 patch-onboarding exception in docs/scope.md.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing resource group hosting the two LIMS DEV v2 VMs, e.g. /subscriptions/<id>/resourceGroups/rg-compute-lims-dev-westeu. Both the target subscription and resource group are derived from this single authoritative value, matching src/compute/lims-ws2025-dev-foundation — there is no separate/duplicate subscription or resource-group parameter. This is intentionally the same resource group as the compute foundation; this composition does not create or modify any resource group.')
param resourceGroupResourceId string

@description('Azure region used as the policy assignment deployment metadata location.')
param location string = 'westeurope'

@description('Resource name of the existing APP virtual machine to scope assignments to, e.g. vm-lims-dev-v2-westeu-001.')
param appVmName string

@description('Resource name of the existing SQL virtual machine to scope assignments to, e.g. vm-lims-dev-v2-westeu-002.')
param sqlVmName string

@description('Full ARM resource ID of the existing, already-approved user-assigned managed identity reused for Policy Modify/DeployIfNotExists remediation. Never guessed or reconstructed — supply the authoritative resource ID explicitly. See docs/scope.md for the narrow reuse-only decision this falls under.')
param userAssignedIdentityResourceId string

// ─── Derived scope ────────────────────────────────────────────────────────────
// Subscription ID and resource group name are parsed out of
// resourceGroupResourceId rather than accepted as separate parameters,
// mirroring the pattern already used by src/compute/lims-ws2025-dev-foundation.

var resourceGroupIdSegments = split(resourceGroupResourceId, '/')
var targetSubscriptionId = resourceGroupIdSegments[2]
var targetResourceGroupName = resourceGroupIdSegments[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module patchPolicy '../../../modules/compute/lims-ws2025-dev-patch-policy/main.bicep' = {
  scope: resourceGroup(targetSubscriptionId, targetResourceGroupName)
  params: {
    location: location
    appVmName: appVmName
    sqlVmName: sqlVmName
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP VM periodic-assessment policy assignment.')
output appAssessmentAssignmentId string = patchPolicy.outputs.appAssessmentAssignmentId

@description('Full ARM resource ID of the APP VM schedule-prerequisite policy assignment.')
output appSchedulePrerequisiteAssignmentId string = patchPolicy.outputs.appSchedulePrerequisiteAssignmentId

@description('Full ARM resource ID of the SQL VM periodic-assessment policy assignment.')
output sqlAssessmentAssignmentId string = patchPolicy.outputs.sqlAssessmentAssignmentId

@description('Full ARM resource ID of the SQL VM schedule-prerequisite policy assignment.')
output sqlSchedulePrerequisiteAssignmentId string = patchPolicy.outputs.sqlSchedulePrerequisiteAssignmentId

@description('Resource group hosting the two VMs (derived from resourceGroupResourceId).')
output resourceGroupName string = targetResourceGroupName

@description('Subscription ID hosting the two VMs (derived from resourceGroupResourceId).')
output subscriptionId string = targetSubscriptionId

metadata description = 'Subscription-scoped orchestrator for the LIMS WS2025 DEV v2 time-zone enforcement RBAC grant: creates exactly one Microsoft.Authorization/roleAssignments resource, scoped to the same existing resource group hosting the two LIMS DEV v2 VMs already created by src/compute/lims-ws2025-dev-foundation, granting the EXISTING time-zone policy assignment\'s system-assigned identity the Guest Configuration Resource Contributor role. Deploys no VNet, subnet, identity, policy assignment, or guest configuration assignment not explicitly covered by the LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing resource group hosting the two LIMS DEV v2 VMs, e.g. /subscriptions/<id>/resourceGroups/rg-compute-lims-dev-westeu. Matches src/compute/lims-ws2025-dev-foundation and src/compute/lims-ws2025-dev-patch-policy — this is intentionally the same resource group; this composition does not create or modify a resource group.')
param resourceGroupResourceId string

@description('Principal ID of the existing time-zone policy assignment\'s system-assigned identity. Never guessed — see modules/compute/lims-ws2025-dev-timezone-rbac for the full constraints on this value.')
param timeZonePolicyAssignmentPrincipalId string

// ─── Derived scope ────────────────────────────────────────────────────────────
// Subscription ID and resource group name are parsed out of
// resourceGroupResourceId rather than accepted as separate parameters,
// mirroring the pattern already used by src/compute/lims-ws2025-dev-foundation
// and src/compute/lims-ws2025-dev-patch-policy.

var resourceGroupIdSegments = split(resourceGroupResourceId, '/')
var targetSubscriptionId = resourceGroupIdSegments[2]
var targetResourceGroupName = resourceGroupIdSegments[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module timezoneRbac '../../../modules/compute/lims-ws2025-dev-timezone-rbac/main.bicep' = {
  scope: resourceGroup(targetSubscriptionId, targetResourceGroupName)
  params: {
    timeZonePolicyAssignmentPrincipalId: timeZonePolicyAssignmentPrincipalId
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the role assignment granting the time-zone policy identity Guest Configuration Resource Contributor at resource-group scope.')
output roleAssignmentId string = timezoneRbac.outputs.roleAssignmentId

@description('Resource group hosting the two VMs (derived from resourceGroupResourceId).')
output resourceGroupName string = targetResourceGroupName

@description('Subscription ID hosting the two VMs (derived from resourceGroupResourceId).')
output subscriptionId string = targetSubscriptionId

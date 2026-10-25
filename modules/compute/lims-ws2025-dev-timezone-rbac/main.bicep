metadata description = 'LIMS WS2025 DEV v2 time-zone enforcement (Machine Configuration) RBAC grant: grants the EXISTING, separately-managed subscription-scoped time-zone policy assignment (configure-windows-timezone-dev, built-in definition 6141c932-9384-44c6-a395-59e4c057d7c9) system-assigned identity the single built-in role its own policyRule.then.details.roleDefinitionIds requires for DeployIfNotExists remediation (Guest Configuration Resource Contributor), scoped to exactly the resource group hosting the two LIMS DEV v2 VMs. Approved under the narrow LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md. Creates no identity, Entra object, custom role, policy assignment, or guest configuration assignment; does not modify the existing policy assignment; grants no permission beyond this one built-in role at this one resource-group scope.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Principal ID (object ID) of the EXISTING system-assigned managed identity belonging to the subscription-scoped time-zone policy assignment "configure-windows-timezone-dev" (built-in definition 6141c932-9384-44c6-a395-59e4c057d7c9). Never guessed or reconstructed — supply the authoritative value shown on that policy assignment\'s Identity tab in the Azure portal, or via `az policy assignment show`. This module creates no identity — it only grants an already-existing identity a role.')
param timeZonePolicyAssignmentPrincipalId string

// ─── Built-in role definition ID (approved RBAC decision — see docs/scope.md) ───
// This is the single role the "Configure time zone on Windows machines."
// built-in policy definition's own policyRule.then.details.roleDefinitionIds
// requires for its DeployIfNotExists remediation — verified directly against
// the official policy source (https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Guest%20Configuration/SetWindowsTimeZone_DINE.json),
// not assumed. No custom role definition is declared anywhere in this module.
var guestConfigurationResourceContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '088ab73d-1256-47ae-bea9-9de8e7131f31')

// ─── Role assignment, resource-group scope ───────────────────────────────────
// Resource-group scope (the default/implicit scope for this resourceGroup-
// scoped module) is the minimum effective scope for this grant, not merely a
// convenient default: Microsoft's "Remediate non-compliant resources"
// documentation confirms deployIfNotExists remediation's existenceScope
// defaults to ResourceGroup and "If a template deployment is executed, it's
// deployed in the resource group of [the target resource]" — so the nested
// template that creates the guestConfigurationAssignments resource is itself
// deployed at resource-group scope, not VM scope. This is also why the Guest
// Configuration Resource Contributor role's own action list includes
// Microsoft.Resources/deployments/* alongside the guestConfigurationAssignments
// actions. A role assignment scoped only to an individual VM would therefore
// NOT be sufficient for this remediation's deployment step, even though the
// final guestConfigurationAssignments resource it creates is itself a child
// of the VM. See docs/operations.md for the full verification and the
// residual-scope caveat (this resource group may contain resources beyond
// the two named v2 VMs).
resource timeZoneGuestConfigurationRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, timeZonePolicyAssignmentPrincipalId, guestConfigurationResourceContributorRoleDefinitionId)
  properties: {
    principalId: timeZonePolicyAssignmentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: guestConfigurationResourceContributorRoleDefinitionId
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the role assignment granting the time-zone policy identity Guest Configuration Resource Contributor at resource-group scope.')
output roleAssignmentId string = timeZoneGuestConfigurationRoleAssignment.id

metadata description = 'Subscription-scoped orchestrator for LIMS WS2025 DEV v2 time-zone enforcement: deploys exactly two Microsoft built-in Azure Policy assignments (one per VM, each individually resource-scoped) and two matching Microsoft.Authorization/roleAssignments (each at this resource group\'s scope, granting that assignment\'s own dedicated system-assigned identity Guest Configuration Resource Contributor), into the same existing resource group already hosting the two replacement LIMS DEV v2 virtual machines created by src/compute/lims-ws2025-dev-foundation. Deploys no VNet, subnet, Key Vault, Disk Encryption Set, standalone identity, custom policy definition, custom role, or guest configuration assignment not explicitly covered by the LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md. Does not modify, reference, or grant any permission to the existing, separately-managed subscription-scoped "configure-windows-timezone-dev" policy assignment or its identity.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing resource group hosting the two LIMS DEV v2 VMs, e.g. /subscriptions/<id>/resourceGroups/rg-compute-lims-dev-westeu. Both the target subscription and resource group are derived from this single authoritative value, matching src/compute/lims-ws2025-dev-foundation and src/compute/lims-ws2025-dev-patch-policy — this is intentionally the same resource group; this composition does not create or modify a resource group.')
param resourceGroupResourceId string

@description('Azure region used as the policy assignment deployment metadata location.')
param location string = 'westeurope'

@description('Resource name of the existing APP virtual machine to scope its time-zone policy assignment to, e.g. vm-lims-dev-v2-westeu-001.')
param appVmName string

@description('Resource name of the existing SQL virtual machine to scope its time-zone policy assignment to, e.g. vm-lims-dev-v2-westeu-002.')
param sqlVmName string

@description('TimeZone parameter value passed to the built-in policy definition — must be one of that definition\'s own exact allowedValues display strings.')
param timeZone string = '(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna'

@description('IncludeArcMachines parameter value passed to the built-in policy definition. The definition declares this parameter as type string with allowedValues ["true","false"] (not boolean).')
@allowed([
  'true'
  'false'
])
param includeArcMachines string = 'false'

@description('Policy assignment enforcementMode for both assignments.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param enforcementMode string = 'Default'

// ─── Derived scope ────────────────────────────────────────────────────────────
// Subscription ID and resource group name are parsed out of
// resourceGroupResourceId rather than accepted as separate parameters,
// mirroring the pattern already used by src/compute/lims-ws2025-dev-foundation
// and src/compute/lims-ws2025-dev-patch-policy.

var resourceGroupIdSegments = split(resourceGroupResourceId, '/')
var targetSubscriptionId = resourceGroupIdSegments[2]
var targetResourceGroupName = resourceGroupIdSegments[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module timezonePolicy '../../../modules/compute/lims-ws2025-dev-timezone-policy/main.bicep' = {
  scope: resourceGroup(targetSubscriptionId, targetResourceGroupName)
  params: {
    location: location
    appVmName: appVmName
    sqlVmName: sqlVmName
    timeZone: timeZone
    includeArcMachines: includeArcMachines
    enforcementMode: enforcementMode
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP VM time-zone policy assignment.')
output appTimeZoneAssignmentId string = timezonePolicy.outputs.appTimeZoneAssignmentId

@description('Full ARM resource ID of the SQL VM time-zone policy assignment.')
output sqlTimeZoneAssignmentId string = timezonePolicy.outputs.sqlTimeZoneAssignmentId

@description('Full ARM resource ID of the role assignment granting the APP VM time-zone assignment identity Guest Configuration Resource Contributor at resource-group scope.')
output appTimeZoneRoleAssignmentId string = timezonePolicy.outputs.appTimeZoneRoleAssignmentId

@description('Full ARM resource ID of the role assignment granting the SQL VM time-zone assignment identity Guest Configuration Resource Contributor at resource-group scope.')
output sqlTimeZoneRoleAssignmentId string = timezonePolicy.outputs.sqlTimeZoneRoleAssignmentId

@description('Resource group hosting the two VMs (derived from resourceGroupResourceId).')
output resourceGroupName string = targetResourceGroupName

@description('Subscription ID hosting the two VMs (derived from resourceGroupResourceId).')
output subscriptionId string = targetSubscriptionId

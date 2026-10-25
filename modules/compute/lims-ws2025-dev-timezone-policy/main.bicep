metadata description = 'LIMS WS2025 DEV v2 time-zone enforcement: assigns the Microsoft built-in Azure Policy definition "Configure time zone on Windows machines." (6141c932-9384-44c6-a395-59e4c057d7c9, never copied into a custom definition), each individually scoped to exactly one of the two replacement LIMS DEV v2 virtual machines (resource scope, never subscription or resource-group scope) — two policy assignments total, each with its own dedicated system-assigned identity. Each identity is granted Guest Configuration Resource Contributor at this resource group\'s scope (the minimum scope this built-in policy\'s DeployIfNotExists remediation mechanics require), resolved from the assignment\'s own identity output, never hardcoded or guessed. Approved under the narrow LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md. Deliberately separate from, and does not modify, grant permissions to, or otherwise touch, the existing broader subscription-scoped "configure-windows-timezone-dev" policy assignment or its identity (2dea906c-2e98-4b2c-ab4b-2d002de614e7) — see docs/scope.md and docs/operations.md for why reusing that broader assignment/identity was rejected. Creates no guest configuration assignment directly, no custom policy definition, and no standalone user-assigned identity.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region used as the policy assignment deployment metadata location (required because each assignment below declares a system-assigned identity). Does not need to match the VM region for a resource-scoped assignment, but is set to the same region for consistency.')
param location string = 'westeurope'

@description('Resource name of the existing APP virtual machine to scope its time-zone policy assignment to, e.g. vm-lims-dev-v2-westeu-001. Referenced only as an existing resource for scoping — not created, modified, or redefined here.')
param appVmName string

@description('Resource name of the existing SQL virtual machine to scope its time-zone policy assignment to, e.g. vm-lims-dev-v2-westeu-002. Referenced only as an existing resource for scoping — not created, modified, or redefined here.')
param sqlVmName string

@description('TimeZone parameter value passed to the built-in policy definition. Must be one of the exact display strings in that definition\'s own allowedValues list (e.g. "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna") — a free-form display string, distinct from the Windows time-zone ID (e.g. "W. Europe Standard Time") that the Get-TimeZone PowerShell cmdlet reports for the same zone. Never substitute one for the other.')
param timeZone string = '(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna'

@description('IncludeArcMachines parameter value passed to the built-in policy definition. The definition declares this parameter as type string with allowedValues ["true","false"] (not boolean) — this value must be one of those exact strings, not a Bicep bool.')
@allowed([
  'true'
  'false'
])
param includeArcMachines string = 'false'

@description('Policy assignment enforcementMode for both assignments below. "Default" actively enforces/remediates; "DoNotEnforce" only evaluates compliance without deploying the guest configuration assignment.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param enforcementMode string = 'Default'

// ─── Existing VM references (scoping only — not declared/modified) ──────────

resource appVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: appVmName
}

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: sqlVmName
}

// ─── Built-in policy and role definition IDs (approved decisions — see docs/scope.md) ───
// Read-only references to Microsoft's built-in definitions, verified directly
// against the official policy source
// (https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Guest%20Configuration/SetWindowsTimeZone_DINE.json).
// No custom Microsoft.Authorization/policyDefinitions or
// Microsoft.Authorization/roleDefinitions resource is declared anywhere in
// this module.

var timeZonePolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/6141c932-9384-44c6-a395-59e4c057d7c9'
var guestConfigurationResourceContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '088ab73d-1256-47ae-bea9-9de8e7131f31')

// ─── APP VM: dedicated policy assignment + dedicated RBAC grant ─────────────
// The assignment itself is scoped to the VM resource only (scope: appVm) —
// it evaluates and remediates only this one VM. Its system-assigned identity
// is new and dedicated to this assignment (never the existing, broader
// subscription-scoped "configure-windows-timezone-dev" assignment's
// identity). The identity's permission grant below is necessarily scoped to
// this resource group (DeployIfNotExists remediation's nested deployment
// executes at the resource group of the target resource, not at VM scope —
// see docs/operations.md) — the RBAC *grant* covers the resource group, even
// though the *policy assignment* it belongs to is scoped to this one VM only.

resource appTimeZoneAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-app-timezone'
  location: location
  scope: appVm
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'LIMS WS2025 DEV v2 - time zone enforcement (APP VM)'
    description: 'Built-in DeployIfNotExists policy (6141c932-9384-44c6-a395-59e4c057d7c9): enforces the configured Windows time zone on vm-lims-dev-v2-westeu-001 only, via a dedicated system-assigned identity. Deliberately separate from the existing, broader subscription-scoped configure-windows-timezone-dev assignment - see docs/scope.md and docs/operations.md. Part of the narrow LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md.'
    policyDefinitionId: timeZonePolicyDefinitionId
    enforcementMode: enforcementMode
    parameters: {
      TimeZone: {
        value: timeZone
      }
      IncludeArcMachines: {
        value: includeArcMachines
      }
    }
  }
}

resource appTimeZoneRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, appTimeZoneAssignment.id, guestConfigurationResourceContributorRoleDefinitionId)
  properties: {
    principalId: appTimeZoneAssignment.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: guestConfigurationResourceContributorRoleDefinitionId
  }
}

// ─── SQL VM: dedicated policy assignment + dedicated RBAC grant ────────────
// Same structure and constraints as the APP VM block above.

resource sqlTimeZoneAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-sql-timezone'
  location: location
  scope: sqlVm
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'LIMS WS2025 DEV v2 - time zone enforcement (SQL VM)'
    description: 'Built-in DeployIfNotExists policy (6141c932-9384-44c6-a395-59e4c057d7c9): enforces the configured Windows time zone on vm-lims-dev-v2-westeu-002 only, via a dedicated system-assigned identity. Deliberately separate from the existing, broader subscription-scoped configure-windows-timezone-dev assignment - see docs/scope.md and docs/operations.md. Part of the narrow LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md.'
    policyDefinitionId: timeZonePolicyDefinitionId
    enforcementMode: enforcementMode
    parameters: {
      TimeZone: {
        value: timeZone
      }
      IncludeArcMachines: {
        value: includeArcMachines
      }
    }
  }
}

resource sqlTimeZoneRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sqlTimeZoneAssignment.id, guestConfigurationResourceContributorRoleDefinitionId)
  properties: {
    principalId: sqlTimeZoneAssignment.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: guestConfigurationResourceContributorRoleDefinitionId
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP VM time-zone policy assignment.')
output appTimeZoneAssignmentId string = appTimeZoneAssignment.id

@description('Full ARM resource ID of the SQL VM time-zone policy assignment.')
output sqlTimeZoneAssignmentId string = sqlTimeZoneAssignment.id

@description('Full ARM resource ID of the role assignment granting the APP VM time-zone assignment identity Guest Configuration Resource Contributor at resource-group scope.')
output appTimeZoneRoleAssignmentId string = appTimeZoneRoleAssignment.id

@description('Full ARM resource ID of the role assignment granting the SQL VM time-zone assignment identity Guest Configuration Resource Contributor at resource-group scope.')
output sqlTimeZoneRoleAssignmentId string = sqlTimeZoneRoleAssignment.id

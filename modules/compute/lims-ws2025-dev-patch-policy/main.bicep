metadata description = 'LIMS WS2025 DEV v2 patch-onboarding pilot: assigns two Microsoft built-in Azure Policy definitions (never copied into custom definitions), each individually scoped to exactly one of the two replacement LIMS DEV v2 virtual machines (resource scope, never subscription or resource-group scope) — four policy assignments total. Approved under the narrow LIMS WS2025 DEV v2 patch-onboarding exception in docs/scope.md. Creates no maintenance configuration, dynamic scope, direct/static maintenance assignment, identity, Entra object, custom role, or new RBAC grant; schedule membership is supplied entirely by the existing mc-lims-nonprod-westeu dynamic scope once the dataClassification=non-production tag is present on each VM (set by src/compute/lims-ws2025-dev-foundation, not here).'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region used as the policy assignment deployment metadata location. Does not need to match the VM region for a resource-scoped assignment, but is set to the same region for consistency.')
param location string = 'westeurope'

@description('Resource name of the existing APP virtual machine to scope the assessment and schedule-prerequisite assignments to, e.g. vm-lims-dev-v2-westeu-001. Referenced only as an existing resource for scoping — not created, modified, or redefined here.')
param appVmName string

@description('Resource name of the existing SQL virtual machine to scope the assessment and schedule-prerequisite assignments to, e.g. vm-lims-dev-v2-westeu-002. Referenced only as an existing resource for scoping — not created, modified, or redefined here.')
param sqlVmName string

@description('Full ARM resource ID of the existing, already-approved user-assigned managed identity reused for Policy Modify/DeployIfNotExists remediation (e.g. /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>). This module creates no identity, Entra object, custom role, or new RBAC grant — the identity is assumed to already hold whatever effective permission it needs (both built-in definitions below list Contributor for remediation) at the scope these assignments target; that must be verified out-of-band before deploying. Never guessed or reconstructed — supply the authoritative resource ID explicitly.')
param userAssignedIdentityResourceId string

// ─── Existing VM references (scoping only — not declared/modified) ──────────

resource appVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: appVmName
}

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: sqlVmName
}

// ─── Shared remediation identity reference ───────────────────────────────────
// Reuse-only: references the existing user-assigned identity supplied via
// userAssignedIdentityResourceId. No identity resource, RBAC assignment, or
// role definition is declared anywhere in this module.

var remediationIdentity = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${userAssignedIdentityResourceId}': {}
  }
}

// ─── Built-in policy definition IDs (approved Policy decision — see docs/scope.md) ───
// Read-only references to Microsoft's built-in policy definitions. No custom
// Microsoft.Authorization/policyDefinitions resource is declared anywhere in
// this module.

var assessmentPolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/59efceea-0c96-497e-a4a1-4eb2290dac15'
var schedulePrerequisitePolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/9905ca54-1471-49c6-8291-7582c04cd4d4'

// ─── APP VM: two assignments, resource-scoped only ──────────────────────────

resource appAssessmentAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-app-patch-assessment'
  location: location
  scope: appVm
  identity: remediationIdentity
  properties: {
    displayName: 'LIMS WS2025 DEV v2 pilot - periodic update assessment (APP VM)'
    description: 'Built-in Modify policy (59efceea-0c96-497e-a4a1-4eb2290dac15): configures Windows update auto-assessment (assessmentMode=AutomaticByPlatform) on vm-lims-dev-v2-westeu-001 only. Part of the narrow LIMS WS2025 DEV v2 patch-onboarding pilot in docs/scope.md.'
    policyDefinitionId: assessmentPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      assessmentMode: {
        value: 'AutomaticByPlatform'
      }
      osType: {
        value: 'Windows'
      }
    }
  }
}

resource appSchedulePrerequisiteAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-app-patch-schedule-prereq'
  location: location
  scope: appVm
  identity: remediationIdentity
  properties: {
    displayName: 'LIMS WS2025 DEV v2 pilot - schedule prerequisite (APP VM)'
    description: 'Built-in DeployIfNotExists policy (9905ca54-1471-49c6-8291-7582c04cd4d4): sets the Customer Managed Schedules prerequisite (patchMode=AutomaticByPlatform, bypassPlatformSafetyChecksOnUserSchedule=true) on vm-lims-dev-v2-westeu-001 only, so it can be picked up by the existing mc-lims-nonprod-westeu dynamic scope. Does not create any maintenance configuration, dynamic scope, or direct/static maintenance assignment. Part of the narrow LIMS WS2025 DEV v2 patch-onboarding pilot in docs/scope.md.'
    policyDefinitionId: schedulePrerequisitePolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      operatingSystemTypes: {
        value: [
          'Windows'
        ]
      }
      effect: {
        value: 'DeployIfNotExists'
      }
    }
  }
}

// ─── SQL VM: two assignments, resource-scoped only ──────────────────────────

resource sqlAssessmentAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-sql-patch-assessment'
  location: location
  scope: sqlVm
  identity: remediationIdentity
  properties: {
    displayName: 'LIMS WS2025 DEV v2 pilot - periodic update assessment (SQL VM)'
    description: 'Built-in Modify policy (59efceea-0c96-497e-a4a1-4eb2290dac15): configures Windows update auto-assessment (assessmentMode=AutomaticByPlatform) on vm-lims-dev-v2-westeu-002 only. Part of the narrow LIMS WS2025 DEV v2 patch-onboarding pilot in docs/scope.md.'
    policyDefinitionId: assessmentPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      assessmentMode: {
        value: 'AutomaticByPlatform'
      }
      osType: {
        value: 'Windows'
      }
    }
  }
}

resource sqlSchedulePrerequisiteAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lims-dev-v2-sql-patch-schedule-prereq'
  location: location
  scope: sqlVm
  identity: remediationIdentity
  properties: {
    displayName: 'LIMS WS2025 DEV v2 pilot - schedule prerequisite (SQL VM)'
    description: 'Built-in DeployIfNotExists policy (9905ca54-1471-49c6-8291-7582c04cd4d4): sets the Customer Managed Schedules prerequisite (patchMode=AutomaticByPlatform, bypassPlatformSafetyChecksOnUserSchedule=true) on vm-lims-dev-v2-westeu-002 only, so it can be picked up by the existing mc-lims-nonprod-westeu dynamic scope. Does not create any maintenance configuration, dynamic scope, or direct/static maintenance assignment. Part of the narrow LIMS WS2025 DEV v2 patch-onboarding pilot in docs/scope.md.'
    policyDefinitionId: schedulePrerequisitePolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      operatingSystemTypes: {
        value: [
          'Windows'
        ]
      }
      effect: {
        value: 'DeployIfNotExists'
      }
    }
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP VM periodic-assessment policy assignment.')
output appAssessmentAssignmentId string = appAssessmentAssignment.id

@description('Full ARM resource ID of the APP VM schedule-prerequisite policy assignment.')
output appSchedulePrerequisiteAssignmentId string = appSchedulePrerequisiteAssignment.id

@description('Full ARM resource ID of the SQL VM periodic-assessment policy assignment.')
output sqlAssessmentAssignmentId string = sqlAssessmentAssignment.id

@description('Full ARM resource ID of the SQL VM schedule-prerequisite policy assignment.')
output sqlSchedulePrerequisiteAssignmentId string = sqlSchedulePrerequisiteAssignment.id

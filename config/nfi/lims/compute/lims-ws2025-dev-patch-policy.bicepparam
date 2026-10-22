// Real (non-secret) DEV parameters for the LIMS WS2025 DEV v2 patch-onboarding
// pilot. Approved under the narrow LIMS WS2025 DEV v2 patch-onboarding
// exception recorded in docs/scope.md — see that file before changing the
// scope of what this composition is allowed to create.
//
// *** NOT YET DEPLOYMENT-READY ***
// resourceGroupResourceId below is a REPLACE_WITH_REAL_VALUE placeholder,
// identical in kind to the one still unresolved in
// config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam (this pilot
// targets the SAME existing rg-compute-lims-dev-westeu resource group — it
// creates no resource group of its own). It MUST be replaced with the real
// resource ID before this file can be used for `bicep build-params` against
// live resources or for any deployment. Until then this file is suitable for
// local static validation only.
//
// userAssignedIdentityResourceId below is also a REPLACE_WITH_REAL_VALUE
// placeholder. No authoritative resource ID for an existing, already-approved
// user-assigned managed identity used for deployment/remediation was found
// anywhere in this repository (all branches searched) — it is never guessed
// or reconstructed (including from screenshots). This is a REQUIRED
// preflight input: supply the real resource ID of the existing identity
// before this file can be used for any deployment. Before running a `deploy`
// action, also verify out-of-band that this identity already has effective
// permission to remediate both built-in policies below (both list the
// built-in Contributor role for remediation — see docs/scope.md and
// docs/operations.md), and that the pipeline's service connection has
// permission to attach (reference) this existing identity on a policy
// assignment. This repository creates no identity, Entra object, custom
// role, or new RBAC grant for it.
//
// This pilot assigns exactly two Microsoft built-in Azure Policy definitions
// (never copied into custom definitions), each individually scoped to one of
// the two VMs below (resource scope only, never subscription or resource-
// group scope):
//   - Configure periodic checking for missing system updates on azure
//     virtual machines (Modify) — assessmentMode=AutomaticByPlatform,
//     osType=Windows.
//   - Set prerequisite for Scheduling recurring updates on Azure virtual
//     machines (DeployIfNotExists) — operatingSystemTypes=[Windows].
// Schedule membership itself is supplied by the existing
// mc-lims-nonprod-westeu maintenance configuration's dynamic scope (filtered
// on the dataClassification=non-production tag, set on both VMs by
// config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam) — this file
// does not create or modify any maintenance configuration, dynamic scope, or
// direct/static maintenance assignment.
using '../../../../src/compute/lims-ws2025-dev-patch-policy/main.bicep'

param resourceGroupResourceId = 'REPLACE_WITH_REAL_VALUE:/subscriptions/<lims-dev-subscription-id>/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param appVmName = 'vm-lims-dev-v2-westeu-001'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param userAssignedIdentityResourceId = 'REPLACE_WITH_REAL_VALUE:<resource ID of the existing, already-approved user-assigned managed identity used for deployment/remediation>'

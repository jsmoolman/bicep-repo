// Real (non-secret) DEV parameters for the LIMS WS2025 DEV v2 time-zone
// enforcement RBAC grant. Approved under the narrow LIMS WS2025 DEV v2
// time-zone enforcement exception recorded in docs/scope.md — see that file
// before changing the scope of what this composition is allowed to create.
//
// *** NOT YET DEPLOYMENT-READY ***
// resourceGroupResourceId below is a REPLACE_WITH_REAL_VALUE placeholder,
// identical in kind to the one still unresolved in
// config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam and
// config/nfi/lims/compute/lims-ws2025-dev-patch-policy.bicepparam (this
// composition targets the SAME existing rg-compute-lims-dev-westeu resource
// group — it creates no resource group of its own). Replace all three
// occurrences together from the same authoritative source. It MUST be
// replaced with the real resource ID before this file can be used for
// `bicep build-params` against live resources or for any deployment. Until
// then this file is suitable for local static validation only.
//
// timeZonePolicyAssignmentPrincipalId below is the real principal ID
// reported for the existing subscription-scoped "configure-windows-timezone-dev"
// policy assignment's system-assigned identity, as supplied evidence for
// this change. It is given here verbatim, not guessed or reconstructed —
// confirm it is still current (e.g. via `az policy assignment show`) before
// deploying, since this repository does not read live state.
using '../../../../src/compute/lims-ws2025-dev-timezone-rbac/main.bicep'

param resourceGroupResourceId = 'REPLACE_WITH_REAL_VALUE:/subscriptions/<lims-dev-subscription-id>/resourceGroups/rg-compute-lims-dev-westeu'

param timeZonePolicyAssignmentPrincipalId = '2dea906c-2e98-4b2c-ab4b-2d002de614e7'

// Example parameters for the LIMS WS2025 DEV v2 time-zone enforcement RBAC
// grant — illustrates the shape a real deployment's parameter file must
// provide. Subscription ID and resource group below are fictional and match
// the convention used by config/example/compute/lims-ws2025-dev-foundation.bicepparam
// (the resource group is intentionally the SAME one the compute foundation
// deploys into — this composition creates no resource group of its own).
//
// This grants the EXISTING, separately-managed subscription-scoped time-zone
// policy assignment's (configure-windows-timezone-dev, built-in definition
// 6141c932-9384-44c6-a395-59e4c057d7c9) system-assigned identity exactly one
// built-in role (Guest Configuration Resource Contributor) at exactly this
// resource group's scope — the single role and minimum effective scope the
// policy definition's own DeployIfNotExists remediation requires (verified
// against the official policy source and Microsoft's remediation
// documentation — see docs/scope.md and docs/operations.md). It does not
// modify the existing policy assignment, create any identity, or create any
// guest configuration assignment.
//
// timeZonePolicyAssignmentPrincipalId below is a fictional illustrative
// value — it must be replaced with the real principal ID shown on the
// existing policy assignment's Identity tab (or via
// `az policy assignment show`), never guessed or reconstructed.
using '../../../src/compute/lims-ws2025-dev-timezone-rbac/main.bicep'

param resourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-compute-lims-dev-westeu'

param timeZonePolicyAssignmentPrincipalId = '00000000-0000-0000-0000-000000000099'

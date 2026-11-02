metadata description = 'Resolves and verifies the existing system-assigned managed identity principalId of the existing LIMS WS2025 DEV v2 SQL virtual machine, for the narrow SQL v2 installation-media container RBAC exception in docs/scope.md. References the VM as an existing resource only — creates, modifies, or replaces no identity, and declares no workload resource of its own (resources: [] in the compiled template). When invoked as a nested module deployment (see src/compute/lims-ws2025-dev-sql-media-rbac/main.bicep), Azure still creates/updates a Microsoft.Resources/deployments record for that invocation in whichever resource group this module is scoped to — that is a property of nested module deployments generally, not a workload-resource mutation performed by this file. The supplied expectedSqlVmPrincipalId is verification evidence only: it is independently compared against the VM live-resolved identity.principalId, and this deployment fails closed if they do not match. The output is always the live-resolved value, never the supplied expected value, so it is never used as a hardcoded functional identity downstream.'

targetScope = 'resourceGroup'

@description('Resource name of the existing SQL virtual machine whose system-assigned identity is resolved, e.g. vm-lims-dev-v2-westeu-002. Referenced only as an existing resource — not created, modified, or redefined here.')
param sqlVmName string

@description('Customer-attested expected principalId of the SQL VM system-assigned managed identity, used ONLY as independent verification evidence against the live-resolved value below — never used as the functional principal passed to any role assignment. A mismatch fails this deployment closed.')
param expectedSqlVmPrincipalId string

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: sqlVmName
}

// Fail-closed verification: filtering the live-resolved principalId against
// the customer-attested expected value, then indexing position 0, throws a
// template-evaluation error (not merely a warning) when they do not match —
// mirroring this repository's "duplicated verification, never trusted only
// against each other" pattern used by the guest data-disk preparation
// script (see docs/scope.md). The value used everywhere downstream is
// always this live-resolved, verified identity — never the expected
// parameter directly.
var verifiedPrincipalIds = filter([sqlVm.identity.principalId], id => id == expectedSqlVmPrincipalId)

@description('The SQL VM system-assigned identity principalId, live-resolved from the existing VM resource and verified to match expectedSqlVmPrincipalId. Callers should use only this output functionally — never expectedSqlVmPrincipalId directly.')
output verifiedPrincipalId string = verifiedPrincipalIds[0]

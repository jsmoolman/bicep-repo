// Example parameters for LIMS WS2025 DEV v2 time-zone enforcement —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription ID and resource group below are fictional and match the
// convention used by config/example/compute/lims-ws2025-dev-foundation.bicepparam
// (the resource group is intentionally the SAME one the compute foundation
// deploys into — this composition creates no resource group of its own).
//
// This deploys exactly two Microsoft built-in Azure Policy assignments
// (never copied into a custom definition — built-in definition
// 6141c932-9384-44c6-a395-59e4c057d7c9), each individually scoped to one of
// the two replacement LIMS DEV v2 virtual machines (resource scope only),
// each with its own dedicated system-assigned identity, and two matching
// Microsoft.Authorization/roleAssignments granting those identities Guest
// Configuration Resource Contributor at this resource group's scope (the
// minimum scope this policy's DeployIfNotExists remediation requires — see
// docs/scope.md and docs/operations.md).
//
// This is deliberately separate from, and does NOT reference, modify, or
// grant any permission to, the existing broader subscription-scoped
// "configure-windows-timezone-dev" policy assignment or its identity — see
// docs/operations.md for why reusing that broader assignment was rejected
// (its resource group, rg-compute-lims-dev-westeu, also hosts the v1 LIMS
// DEV VMs, so granting permissions to its identity would not isolate
// enforcement to the two v2 VMs this exception covers).
using '../../../src/compute/lims-ws2025-dev-timezone-policy/main.bicep'

param resourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param appVmName = 'vm-lims-dev-v2-westeu-001'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param timeZone = '(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna'

param includeArcMachines = 'false'

param enforcementMode = 'Default'

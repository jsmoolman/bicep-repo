// Example parameters for the LIMS WS2025 DEV v2 patch-onboarding pilot —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription ID and resource group below are fictional and match the
// convention used by config/example/compute/lims-ws2025-dev-foundation.bicepparam
// (the resource group is intentionally the SAME one the compute foundation
// deploys into — this pilot creates no resource group of its own).
//
// This assigns exactly two Microsoft built-in Azure Policy definitions,
// never copied into custom definitions, each individually scoped to one of
// the two replacement LIMS DEV v2 virtual machines (resource scope only) —
// four assignments total. It creates no maintenance configuration, dynamic
// scope, direct/static maintenance assignment, identity, Entra object,
// custom role, or new RBAC grant. Approved under the narrow LIMS WS2025 DEV
// v2 patch-onboarding exception recorded in docs/scope.md.
//
// userAssignedIdentityResourceId below is a fictional illustrative value —
// it must be replaced with the real resource ID of the existing, already-
// approved user-assigned managed identity used for deployment/remediation.
// This repository does not create or guess that identity; see
// docs/operations.md for the required preflight input.
using '../../../src/compute/lims-ws2025-dev-patch-policy/main.bicep'

param resourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param appVmName = 'vm-lims-dev-v2-westeu-001'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param userAssignedIdentityResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-identity-example-westeu/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-example-update-manager-remediation'

// Real (non-secret) DEV/MGMT parameters for the LIMS WS2025 DEV v2 SQL
// installation-media container RBAC exception. Approved under the narrow
// exception recorded in docs/scope.md — see that file before changing the
// scope of what this composition is allowed to create.
//
// All values below were supplied directly by the customer for this specific
// task (target VM, both subscription IDs, both resource group names, the
// storage account, and the container) and are NOT placeholders:
//   - SQL VM:              vm-lims-dev-v2-westeu-002
//   - DEV subscription:    8ebb26a1-674a-40d1-97f8-e0a237e288a6 (same DEV
//                           subscription already used by
//                           lims-ws2025-dev-foundation/-patch-policy/
//                           -timezone-policy and the guest disk-prep
//                           script's own fixed allowlist)
//   - DEV resource group:  rg-compute-lims-dev-westeu (same resource group
//                           already hosting both LIMS WS2025 DEV v2 VMs)
//   - MGMT subscription:   cd9bed50-c972-49d0-83b0-b97bf801c804
//   - MGMT resource group: rg-core-lims-mgmt-westeu
//   - Storage account:     salimsmgmtwe
//   - Container:           mssql-2022-source
//
// expectedSqlVmPrincipalId is verification evidence only (see
// modules/compute/lims-ws2025-dev-sql-media-rbac/resolve-sql-vm-identity.bicep)
// — it is never the functional identity granted access; the role assignment
// always uses the live-resolved principalId read from the existing VM at
// deployment time, and this deployment fails closed if that live value does
// not match the expected value below.
//
// This file deploys exactly one Microsoft.Authorization/roleAssignments
// resource (built-in Storage Blob Data Reader,
// 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1), scoped to exactly the
// mssql-2022-source container — never the storage account, resource group,
// or subscription. It creates no VM, identity, storage account, container,
// account key, or SAS token, and performs no media listing/download, SQL
// Setup, or guest execution of any kind.
using '../../../../src/compute/lims-ws2025-dev-sql-media-rbac/main.bicep'

param sqlVmResourceGroupResourceId = '/subscriptions/8ebb26a1-674a-40d1-97f8-e0a237e288a6/resourceGroups/rg-compute-lims-dev-westeu'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param expectedSqlVmPrincipalId = 'cd8361e1-7145-4d87-9c31-3bfaf9769185'

param storageResourceGroupResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourceGroups/rg-core-lims-mgmt-westeu'

param storageAccountName = 'salimsmgmtwe'

param containerName = 'mssql-2022-source'

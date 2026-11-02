// Example parameters for the LIMS WS2025 DEV v2 SQL installation-media
// container RBAC exception — illustrates the shape a real deployment's
// parameter file must provide. All IDs below are fictional, matching the
// convention used by config/example/compute/lims-ws2025-dev-foundation.bicepparam
// (DEV-like fictional subscription ...000002, MGMT-like fictional
// subscription ...000001 — see config/example/observability/
// vm-availability-sla-dashboard-v2.bicepparam for the same MGMT convention).
//
// This deploys exactly one Microsoft.Authorization/roleAssignments resource
// (built-in Storage Blob Data Reader, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1),
// scoped to exactly the existing mssql-2022-source blob container — never
// the storage account, resource group, or subscription. It is deliberately
// cross-subscription: the SQL VM lookup below targets the DEV subscription
// (read-only — nothing is deployed there); the role assignment itself is
// deployed only into the MGMT subscription. See docs/scope.md for the full
// decision record.
using '../../../src/compute/lims-ws2025-dev-sql-media-rbac/main.bicep'

param sqlVmResourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-compute-lims-dev-westeu'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param expectedSqlVmPrincipalId = '00000000-0000-0000-0000-000000000099'

param storageResourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-core-lims-mgmt-westeu'

param storageAccountName = 'salimsmgmtwe'

param containerName = 'mssql-2022-source'

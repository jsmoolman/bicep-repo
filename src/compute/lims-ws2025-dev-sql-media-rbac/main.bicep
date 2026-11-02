metadata description = 'Subscription-scoped orchestrator for the narrow LIMS WS2025 DEV v2 SQL installation-media container RBAC exception (docs/scope.md): resolves and verifies the existing SQL v2 VM system-assigned identity in the DEV subscription, then grants that identity exactly one built-in Storage Blob Data Reader role assignment scoped to the existing mssql-2022-source container in the MGMT subscription — never storage-account, resource-group, or subscription scope. The DEV-side module creates no workload resource and modifies no VM there (read-only identity lookup), but — like any nested module deployment — it does create/update a Microsoft.Resources/deployments record in that DEV resource group; this is not the same as "nothing is deployed in DEV." Creates no identity, storage account, container, custom role, account key, or SAS token. Deliberately cross-subscription: the DEV VM lookup and the MGMT role-assignment target are each an explicitly, separately scoped module — never conflated. The existing Azure DevOps service connection already has customer-confirmed Owner access across all LIMS subscriptions, which covers both the DEV deployment-record creation and the MGMT role-assignment creation — no new permission is required or granted.'

targetScope = 'subscription'

@description('Full ARM resource ID of the existing DEV resource group hosting the SQL v2 VM, e.g. /subscriptions/<dev-subscription-id>/resourceGroups/rg-compute-lims-dev-westeu. The DEV subscription ID and resource group name are both derived from this single authoritative value. This composition creates no resource group and no workload resource in this subscription — the module scoped here performs a read-only existing-VM identity lookup only — but the nested-module mechanism itself still creates/updates a Microsoft.Resources/deployments record there, covered by the existing service connection\'s already-confirmed Owner access across all LIMS subscriptions (no new permission required).')
param sqlVmResourceGroupResourceId string

@description('Resource name of the existing SQL v2 virtual machine, e.g. vm-lims-dev-v2-westeu-002. Referenced only as an existing resource for identity resolution — not created, modified, or redefined here.')
param sqlVmName string

@description('Customer-attested expected principalId of the SQL VM system-assigned managed identity — verification evidence only. See modules/compute/lims-ws2025-dev-sql-media-rbac/resolve-sql-vm-identity.bicep for how it is used: it is never the functional identity passed to the role assignment, only an independent check against the live-resolved value.')
param expectedSqlVmPrincipalId string

@description('Full ARM resource ID of the existing MGMT resource group hosting the installation-media storage account, e.g. /subscriptions/<mgmt-subscription-id>/resourceGroups/rg-core-lims-mgmt-westeu. The MGMT subscription ID and resource group name are both derived from this single authoritative value. This is the only subscription into which this composition creates a workload resource — exactly one Microsoft.Authorization/roleAssignments resource, scoped to the container below. (The DEV subscription above also receives a Microsoft.Resources/deployments record from the identity-lookup module, but no workload resource.)')
param storageResourceGroupResourceId string

@description('Name of the existing storage account hosting the installation-media container, e.g. salimsmgmtwe. Referenced only as an existing resource — not created, modified, or redefined here.')
param storageAccountName string

@description('Name of the existing blob container to grant read access to, e.g. mssql-2022-source. Referenced only as an existing resource — not created, modified, or redefined here.')
param containerName string

// ─── Derived scope: DEV (VM identity lookup — read-only; no workload resource, but a Microsoft.Resources/deployments record is still created there) ───
var devResourceGroupIdSegments = split(sqlVmResourceGroupResourceId, '/')
var devSubscriptionId = devResourceGroupIdSegments[2]
var devResourceGroupName = devResourceGroupIdSegments[4]

// ─── Derived scope: MGMT (the only subscription this composition deploys into) ───
var mgmtResourceGroupIdSegments = split(storageResourceGroupResourceId, '/')
var mgmtSubscriptionId = mgmtResourceGroupIdSegments[2]
var mgmtResourceGroupName = mgmtResourceGroupIdSegments[4]

// Explicit subscription guard: this composition is cross-subscription by
// design (DEV VM lookup, MGMT role-assignment target). The two derived
// subscription IDs must never resolve to the same value — that would
// indicate a parameter mix-up (e.g. the same resourceGroupResourceId
// accidentally supplied for both parameters), not a legitimate
// configuration for this specific, narrowly scoped exception. Fails closed
// via the same filter(...)[0]-on-empty-array mechanism used in
// resolve-sql-vm-identity.bicep, rather than silently proceeding with a
// same-subscription deployment this exception was not reviewed for.
var distinctSubscriptionGuard = filter([devSubscriptionId], id => id != mgmtSubscriptionId)
var verifiedDevSubscriptionId = distinctSubscriptionGuard[0]

// ─── DEV: resolve + verify the SQL VM's existing system-assigned identity ──
// Scoped explicitly to the DEV subscription/resource group derived above —
// creates no workload resource and modifies no VM there; reads the
// existing VM's identity.principalId only. Like any nested module
// deployment, Azure still creates/updates a Microsoft.Resources/deployments
// record in this DEV resource group for this module invocation — covered
// by the existing service connection's already-confirmed Owner access
// across all LIMS subscriptions (no new permission required).
module resolveSqlVmIdentity '../../../modules/compute/lims-ws2025-dev-sql-media-rbac/resolve-sql-vm-identity.bicep' = {
  name: 'resolve-sql-vm-identity'
  scope: resourceGroup(verifiedDevSubscriptionId, devResourceGroupName)
  params: {
    sqlVmName: sqlVmName
    expectedSqlVmPrincipalId: expectedSqlVmPrincipalId
  }
}

// ─── MGMT: exactly one container-scoped role assignment ────────────────────
// Scoped explicitly to the MGMT subscription/resource group derived above —
// the only subscription into which this composition creates a workload
// resource (the DEV subscription above also receives a nested-deployment
// record, but no workload resource).
module mediaContainerRbac '../../../modules/compute/lims-ws2025-dev-sql-media-rbac/main.bicep' = {
  name: 'sql-media-container-rbac'
  scope: resourceGroup(mgmtSubscriptionId, mgmtResourceGroupName)
  params: {
    storageAccountName: storageAccountName
    containerName: containerName
    principalId: resolveSqlVmIdentity.outputs.verifiedPrincipalId
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('DEV subscription ID the SQL VM identity was resolved from (derived from sqlVmResourceGroupResourceId).')
output devSubscriptionId string = verifiedDevSubscriptionId

@description('DEV resource group hosting the SQL VM.')
output devResourceGroupName string = devResourceGroupName

@description('MGMT subscription ID the role assignment was deployed into (derived from storageResourceGroupResourceId).')
output mgmtSubscriptionId string = mgmtSubscriptionId

@description('MGMT resource group hosting the storage account.')
output mgmtResourceGroupName string = mgmtResourceGroupName

@description('Live-resolved, verified principalId of the SQL VM system-assigned identity actually granted access.')
output verifiedSqlVmPrincipalId string = resolveSqlVmIdentity.outputs.verifiedPrincipalId

@description('Full ARM resource ID of the single Storage Blob Data Reader role assignment created.')
output roleAssignmentId string = mediaContainerRbac.outputs.roleAssignmentId

@description('Full ARM resource ID of the exact container scope this role assignment targets (never the storage account, resource group, or subscription).')
output containerResourceId string = mediaContainerRbac.outputs.containerResourceId

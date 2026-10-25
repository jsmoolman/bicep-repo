# Operations

This document describes the operational behavior of each capability in this repository.

## Current state

### VM Availability SLA Dashboard

Reports per-VM daily availability against an SLA target, split by environment, with planned-maintenance credit.

- **Reusable entrypoint:** [`src/observability/vm-availability-sla-dashboard-v2/main.bicep`](../src/observability/vm-availability-sla-dashboard-v2/main.bicep) — subscription-scoped, no workload-specific values.
- **Reusable module:** [`modules/observability/vm-availability-sla-dashboard-v2/main.bicep`](../modules/observability/vm-availability-sla-dashboard-v2/main.bicep) — the workbook resource definition.
- **Configuration:** see [`config/example/observability/vm-availability-sla-dashboard-v2.bicepparam`](../config/example/observability/vm-availability-sla-dashboard-v2.bicepparam) for the parameter shape; one workbook covers every environment listed in `subscriptionEnvironmentMappings`.
- **Deployment pipeline:** [`deploy-vm-availability-sla-dashboard-v2.yml`](../.azuredevops/pipelines/deploy-vm-availability-sla-dashboard-v2.yml) — `trigger: none`/`pr: none`; supports an explicit `what-if` (default) or `deploy` action, run manually.

**Resource identity is stable:** the workbook's deterministic resource name/GUID and its Azure Portal gallery `displayName` are independent values derived from configuration, not from `workbookDisplayName` — changing the visible title never changes the underlying resource identity or its portal-gallery name.

### Cost Management Dashboard

Reports Azure costs by Environment and Service, six calendar months at a time, with a month-over-month Trend on the Service grid.

**Components:**

- **Snapshot Collector:** [`scripts/observability/Invoke-CostManagementSnapshotCollector.ps1`](../scripts/observability/Invoke-CostManagementSnapshotCollector.ps1), run via [`collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml).
- **LAW ingestion foundation:** [`modules/observability/cost-management-data-foundation/main.bicep`](../modules/observability/cost-management-data-foundation/main.bicep) / [`src/observability/cost-management-data-foundation/main.bicep`](../src/observability/cost-management-data-foundation/main.bicep), deployed via [`deploy-cost-management-data-foundation.yml`](../.azuredevops/pipelines/deploy-cost-management-data-foundation.yml). Creates the `CostManagementSnapshot_CL` custom table (Analytics plan, 730/730-day retention) and a `kind: Direct` Data Collection Rule against the configured Log Analytics workspace. No workspace, DCE, identity, or role assignment is created.
- **Dashboard workbook:** [`modules/observability/cost-management-workbook/main.bicep`](../modules/observability/cost-management-workbook/main.bicep) / [`src/observability/cost-management-workbook/main.bicep`](../src/observability/cost-management-workbook/main.bicep), deployed via [`deploy-cost-management-workbook.yml`](../.azuredevops/pipelines/deploy-cost-management-workbook.yml).
- **Configuration:** see [`config/example/observability/cost-management-workbook.bicepparam`](../config/example/observability/cost-management-workbook.bicepparam) and [`cost-management-data-foundation.bicepparam`](../config/example/observability/cost-management-data-foundation.bicepparam) for the parameter shape.

**Data flow:**

```text
Azure Cost Management API
  -> Snapshot Collector (one management-group query per month)
  -> Logs Ingestion API / Data Collection Rule
  -> CostManagementSnapshot_CL (Log Analytics)
  -> Cost Management Dashboard workbook
```

**How to collect a monthly snapshot.** Run `collect-cost-management-snapshot.yml` manually with `billingMonth` = `current` or a completed `YYYY-MM`. It issues exactly one management-group Cost Management query, resolves response columns by name, maps `SubscriptionId` to `Environment` via `subscriptionEnvironmentMappings`, and performs exactly one Logs Ingestion POST of the normalized 9-column rows. Any validation failure (missing column, `nextLink` pagination, zero rows, unmapped subscription) or non-2xx response from either API aborts the run before ingesting. No schedule is configured; this is a manual operation.

**How to deploy/update the workbook or foundation.** `deploy-cost-management-data-foundation.yml` and `deploy-cost-management-workbook.yml` are both manual (`trigger: none`, `pr: none`), default to `what-if`, and accept an explicit `deploy` action.

**Required permissions/prerequisites:**

- The collector's identity requires the **Monitoring Metrics Publisher** role at the Data Collection Rule's scope to ingest data. This role assignment is managed outside this repository — see [`docs/scope.md`](scope.md).
- Read/query access to the configured Log Analytics workspace is required to view the workbook; granted separately.
- Read access to Cost Management at the configured management-group scope is required for the collector to query costs.

**Workbook behavior that matters operationally:**

- The workbook reads only `CostManagementSnapshot_CL`; it never calls the Cost Management API directly.
- The collector's writes are append-only. For each Project + BillingMonth, the workbook selects only the rows belonging to the newest complete collector run (never a per-row `arg_max()`, which could mix rows from different runs), excluding non-collector/diagnostic run IDs.
- A cell/Total renders `€ 0,00` only when a valid snapshot exists with genuinely zero matching cost; it renders `-` when no valid snapshot exists for that month.
- The Environment grid's row order follows `subscriptionEnvironmentMappings`' configured order; `Total` is always last.
- The Service grid's Trend compares only the selected Report Month against the immediately preceding calendar month (not the six-month window), using cent-rounded aggregates so it matches the displayed money values; it is `-` for the current month or when either month's snapshot is unavailable.
- `managementGroupId` and `subscriptionEnvironmentMappings` in the Cost Management workbook parameter file remain the collector script's own configuration source (read via `az bicep build-params`) — do not remove or restructure them for the workbook alone.

**Known limitations:**

- The collector is manual-only; no `schedules:` block is configured.
- No Data Collection Endpoint (DCE) is configured; the DCR uses its own Direct ingestion endpoint. Adopting a DCE later requires updating both the foundation's parameter file (`dataCollectionEndpointResourceId`) and the collector's ingestion-endpoint configuration.

### Backup & Restore Dashboard

Reports backup execution, failures, policy evidence, and restore/recovery activity, read entirely from existing Azure Backup Log Analytics diagnostic tables. This capability creates or modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity resource, and makes no ARM, Resource Graph, or Recovery Services API call.

- **Reusable module:** [`modules/observability/backup-restore-workbook/main.bicep`](../modules/observability/backup-restore-workbook/main.bicep) — no subscription IDs or workspace ID hardcoded; all are parameters.
- **Reusable entrypoint:** [`src/observability/backup-restore-workbook/main.bicep`](../src/observability/backup-restore-workbook/main.bicep) — explicitly scoped to `resourceGroup(workbookSubscriptionId, workbookResourceGroupName)`, independent of the Log Analytics workspace queried.
- **Configuration:** see [`config/example/observability/backup-restore-workbook.bicepparam`](../config/example/observability/backup-restore-workbook.bicepparam) for the parameter shape; `agreedPolicyNames` is an optional allowlist for the Policy Evidence grid.
- **Deployment pipeline:** [`deploy-backup-restore-workbook.yml`](../.azuredevops/pipelines/deploy-backup-restore-workbook.yml) — manual-only, same as the other workbook pipelines, reusing the same shared [`templates/deploy-observability-workbook-steps.yml`](../.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml).

**Data source:** `AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy` — diagnostic settings that populate these tables already exist and are entirely outside this repository's authority.

**Behavior that matters operationally:**

- Environment is derived only from `subscriptionEnvironmentMappings`, never from a resource/VM/vault name. A subscription not present in that configuration is excluded from Protected Estate and Policy Evidence; for job/restore telemetry it is instead retained and labelled `Unmapped`, selectable in the Environment parameter only once such telemetry exists.
- **Agreed Backup Strategy** is a hard-coded reference table (the agreed configuration), distinct from **Backup Policy Evidence** (the actual configuration read from Log Analytics) — Policy Evidence never asserts or implies per-item/database policy assignment.
- **Backup Activity** (selected month) and **Six-Month Backup Performance** distinguish a month with no telemetry (renders `-` throughout) from a month with telemetry but zero executions of a class (renders a real `0`/`-` Success %).
- **Backup Failures** is built from the same filtered job base as Backup Activity, so its row count always equals the sum of that grid's own Failed values for the same selection.
- **Restore Activity/Details** reflect only restore/recovery categories that actually occurred that month; Restore Details is hidden entirely (via `conditionalVisibility`) whenever there is no restore/recovery evidence for the selection.

**Required permissions/prerequisites:**

- Read/query access to the configured Log Analytics workspace is required to view the workbook; granted separately.

**Known limitations:**

- No per-item/database policy-assignment correlation is asserted — Backup Policy Evidence reports only the actual current policy configuration, filtered to an agreed allowlist.
- Restore-test/business-continuity compliance is not asserted — absence of restore/recovery evidence is reported as exactly that, never as a pass/fail result.

### LIMS WS2025 Phase 1 — compute foundation

Creates the replacement LIMS DEV APP and SQL virtual machines (Windows Server 2025 Datacenter, non-Azure Edition), their directly coupled NICs and managed disks, and the Microsoft Entra sign-in extension — into the existing `rg-compute-lims-dev-westeu` resource group. Approved under the narrow, named exception recorded in [`docs/scope.md`](scope.md#explicitly-approved-workload-infrastructure-exceptions); it is not general infrastructure authority and does not extend to any other workload.

- **Reusable module:** [`modules/compute/lims-ws2025-dev-foundation/main.bicep`](../modules/compute/lims-ws2025-dev-foundation/main.bicep) — resource-group-scoped, no hardcoded subscription/resource-group/subnet/Disk-Encryption-Set values.
- **Reusable entrypoint:** [`src/compute/lims-ws2025-dev-foundation/main.bicep`](../src/compute/lims-ws2025-dev-foundation/main.bicep) — subscription-scoped; target subscription and resource group are both derived from a single `resourceGroupResourceId` parameter.
- **Configuration:** see [`config/example/compute/lims-ws2025-dev-foundation.bicepparam`](../config/example/compute/lims-ws2025-dev-foundation.bicepparam) for the parameter shape; the real (non-secret) DEV configuration lives at [`config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam`](../config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam) and is not deployment-ready until its existing-resource placeholder values are replaced — see the comments at the top of that file.
- **Deployment pipeline:** [`deploy-lims-ws2025-dev-foundation.yml`](../.azuredevops/pipelines/deploy-lims-ws2025-dev-foundation.yml) — `trigger: none`/`pr: none`; supports an explicit `what-if` (default) or `deploy` action, run manually. Not routed through the shared observability workbook steps template (it needs to map two secure admin-credential pipeline variables into the Bicep parameter file's `readEnvironmentVariable()` calls, which that template does not support). The service connection used by this pipeline needs permission both to deploy the compute resources below **and** to create the approved VM-scoped Azure RBAC role assignments once the `*LoginPrincipalIds` arrays are populated — see "Microsoft Entra VM sign-in and RBAC" below; this is a documentation/preflight note only, no permission is granted or changed by this repository.

**What this creates:** two VMs (`Standard_D4ads_v5`, Gen2, Trusted Launch with Secure Boot + vTPM, `encryptionAtHost` enabled, always a system-assigned managed identity plus any existing user-assigned identities supplied via `*ExistingUserAssignedIdentityResourceIds` — see "Preserving existing VM identities" below, no public IP), one NIC per VM on the existing `snet-routable` subnet, a 127 GiB OS disk per VM (`osDiskSizeGiB`, explicitly set — not left at the Marketplace image default), a 128 GiB APP application data disk (future `A:`, not initialized or formatted here), a 1024 GiB SQL DATA disk (`ReadOnly` caching) and a 512 GiB SQL LOG disk (`None` caching), and the `AADLoginForWindows` extension on both VMs. All five managed disks use the existing Disk Encryption Set supplied via `diskEncryptionSetResourceId`.

**Preserving existing VM identities (`*ExistingUserAssignedIdentityResourceIds`).** Azure Resource Manager's Incremental deployment mode reapplies every property on every redeployment; a property omitted from the Bicep file is reset to its default rather than left alone (see Microsoft Learn, ["Deployment modes"](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes)). Because the VM resources only ever declared `identity: { type: 'SystemAssigned' }`, redeploying after a user-assigned identity was attached outside this Bicep composition (for example, by Azure Policy's own remediation, which attaches an identity such as `Built-In-Identity-westeurope`) would silently remove that identity, changing `SystemAssigned, UserAssigned` back to `SystemAssigned`.

The module and entrypoint now accept `appExistingUserAssignedIdentityResourceIds` / `sqlExistingUserAssignedIdentityResourceIds` (arrays of full ARM resource IDs, default `[]`) to prevent this:

- The system-assigned identity is **always** retained, regardless of this parameter.
- When an array is non-empty, the VM's `identity.type` becomes `'SystemAssigned, UserAssigned'` and `identity.userAssignedIdentities` includes every supplied resource ID as a key (e.g. `{ '<resource id>': {} }`), matching the [`Microsoft.Compute/virtualMachines` identity schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines).
- An empty array (the default) reproduces the original initial-creation behavior (`SystemAssigned` only) — it is not a "no-op" on an already-converged VM that already has a user-assigned identity attached from outside Bicep; it actively removes that identity on the next redeployment, per the Incremental-mode behavior above.
- This module never creates a user-assigned identity resource, grants it any new permission, or attaches the deployment/remediation identity to a VM. It only preserves identities already attached to the VM by something else (never discovered automatically — this module does not read live state) — supply only authoritative existing resource IDs, never guessed or reconstructed from screenshots or names.
- This is **not** the same parameter as `modules/compute/lims-ws2025-dev-patch-policy`'s `userAssignedIdentityResourceId`: that identity is referenced only by the four `policyAssignment` resources for Policy remediation and is never attached to a VM; `*ExistingUserAssignedIdentityResourceIds` here is attached directly to the VM's own `identity` property and has no relationship to Policy remediation.

Example syntax (dummy IDs — see [`config/example/compute/lims-ws2025-dev-foundation.bicepparam`](../config/example/compute/lims-ws2025-dev-foundation.bicepparam)):

```bicep
param appExistingUserAssignedIdentityResourceIds = [
  '/subscriptions/<id>/resourceGroups/rg-identity-example-westeu/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-westeurope'
]
param sqlExistingUserAssignedIdentityResourceIds = [
  '/subscriptions/<id>/resourceGroups/rg-identity-example-westeu/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-westeurope'
]
```

**What this does not do:** configure the LIMS application, install or configure SQL Server, migrate any data or application content, initialize/format/assign drive letters to any data disk, create or modify any VNet/subnet/NSG/Key Vault/Disk Encryption Set/Log Analytics workspace/Data Collection Rule/Recovery Services Vault, create or modify any Entra group, or modify any existing (v1) LIMS DEV VM or disk. These remain later, separate stages.

**Microsoft Entra VM sign-in and RBAC.** The `AADLoginForWindows` extension alone does not grant anyone sign-in access. Assigning an already-existing Entra security group to an Azure RBAC role is not an Entra ID mutation (see [`docs/scope.md`](scope.md#rbac-and-entra-id-mutation-are-distinct)); it is still a deliberate, narrowly scoped, approved decision, not a default. Only the built-in **Virtual Machine Administrator Login** and **Virtual Machine User Login** roles are ever used, scoped to the individual VM — never any other role, never at subscription/resource-group scope.

The approved DEV access mapping (see [`docs/scope.md`](scope.md#rbac-decision-vm-login-roles-only--lims-ws2025) for the full decision record) is:

| VM | Virtual Machine Administrator Login | Virtual Machine User Login |
|---|---|---|
| `vm-lims-dev-v2-westeu-001` (APP) | `AZ-TC-LIMS-Infra`, `AZ-TC-LIMS-Func`, `AZ-TC-LIMS-App` | none currently required |
| `vm-lims-dev-v2-westeu-002` (SQL) | `AZ-TC-LIMS-Infra`, `AZ-TC-LIMS-App` | none currently required |

`AZ-TC-LIMS-Data` currently has no DEV VM-login assignment on either VM. The module's `appAdministratorLoginPrincipalIds`, `appUserLoginPrincipalIds`, `sqlAdministratorLoginPrincipalIds`, and `sqlUserLoginPrincipalIds` parameters take Entra **object IDs**, never group display names, and all default to empty arrays — **no role assignment is created for a group whose object ID has not been supplied**. No object ID is guessed or inferred (including from screenshots); the real parameter file currently leaves every array empty pending the object IDs below.

**Object IDs still required before this mapping can take effect (not available in this repository):**

- Object ID of `AZ-TC-LIMS-Infra`
- Object ID of `AZ-TC-LIMS-Func`
- Object ID of `AZ-TC-LIMS-App`

(`AZ-TC-LIMS-Data` needs no object ID for DEV VM login, since it currently has no assignment on either VM.)

**Other required live inputs before this can be deployed (not available in this repository):**

- The resource ID of the existing `rg-compute-lims-dev-westeu` resource group.
- The resource ID of the existing `snet-routable` subnet.
- The resource ID of the existing LIMS DEV Disk Encryption Set.
- The resource ID(s) of the existing user-assigned identity/identities already attached to each VM (e.g. `Built-In-Identity-westeurope`), for `appExistingUserAssignedIdentityResourceIds` / `sqlExistingUserAssignedIdentityResourceIds` — see "Preserving existing VM identities" above. **Required before the next redeployment of an already-converged VM**, or that identity will be removed.
- A secret pipeline variable group (or equivalent) providing the local administrator username/password used only as a deployment/break-glass credential — never committed to source.

**Explicitly preserved configurable settings (`tier`, `networkAccessPolicy`, `publicNetworkAccess`, NIC `auxiliaryMode`/`auxiliarySku`/`disableTcpStateTracking`, `privateIPAddressVersion`, data-disk `name`/`deleteOption`).** A second customer `what-if` run (after the identity fix above) correctly showed both VMs' identities preserved and only the intended patch/tag changes, but still reported several disk/NIC properties as differences. These are genuinely configurable, supported properties — not service-generated noise — so they are now declared explicitly rather than left to ARM Incremental mode's "reset to default" behavior (see "Preserving existing VM identities" above for why omission is risky):

- **Disk `tier`** (`Microsoft.Compute/disks@2024-03-02` `properties.tier`, a free-form string, [Microsoft Learn schema reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/disks)) — explicitly set via `appDataDiskTier` / `sqlDataDiskTier` / `sqlLogDiskTier` parameters (defaults `P10` / `P30` / `P20`, the baseline tiers for the current 128 GiB / 1024 GiB / 512 GiB sizes per the [Premium SSD size/tier table](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types#premium-ssd-size)). **These parameters are deliberately separate from the corresponding `*DiskSizeGiB` parameters** — tier is not derived from size — specifically so a future size change does not silently leave a stale, non-baseline tier in place (which would either be rejected or burst-billed); update both together.
- **Disk `networkAccessPolicy: 'AllowAll'` and `publicNetworkAccess: 'Enabled'`** — the documented defaults, now declared explicitly on all three standalone data disks so they are not ambiguous about intent on redeployment. Not a hardening change — `AllowAll`/`Enabled` is retained, matching the current configuration.
- **NIC `auxiliaryMode: 'None'`, `auxiliarySku: 'None'`, `disableTcpStateTracking: false`** (`Microsoft.Network/networkInterfaces@2024-05-01` `properties`) — the documented defaults, now declared explicitly on both NICs.
- **NIC `ipConfigurations[].properties.privateIPAddressVersion: 'IPv4'`** — the documented default, now declared explicitly; allocation remains `Dynamic` and the existing subnet reference is unchanged — this is not a switch to `Static` and does not declare a `privateIPAddress` value (Azure continues to assign and report that value; it is never set by this module).
- **VM data-disk `name`** (`Microsoft.Compute/virtualMachines@2024-11-01` `storageProfile.dataDisks[].name`) — **this is a supported, independently settable input, not merely an echo of the attached disk** (earlier documentation in this file incorrectly described it as not independently settable). Now explicitly set to the matching managed-disk name (`appDataDiskName` / `sqlDataDiskName` / `sqlLogDiskName`) on each VM's data-disk attachment.
- **VM data-disk `deleteOption: 'Detach'`** — the documented default, now declared explicitly on every data-disk attachment on both VMs; disk IDs, LUNs, and caching values are all unchanged.

**Remaining what-if differences reviewed, confirmed as service-generated — not code changes:**

- **Data-disk `toBeDetached`** — a transient, read-only detachment-in-progress flag (default `false`); not a configurable input and not declared.
- **Disk/VM `diskIOPSReadWrite` / `diskMBpsReadWrite`** — only settable on the standalone disk resource for `UltraSSD_LRS`; at the VM `dataDisks[]` attachment level these are documented **read-only**. Not applicable to this module's `Premium_LRS` disks and not declared at either level.
- **NIC `privateIPAddress`** — only meaningful for `Static` allocation; this module uses `Dynamic` allocation, so Azure assigns and reports the value; it is never set by this module.
- **`adminUsername` shown as an unresolved expression in what-if.** This is a what-if display limitation, not a statement that any mismatch is harmless: `adminUsername` is [documented as immutable after VM creation](https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines), so Azure rejects an attempted *change* to it on an existing VM — but the parameter file's `adminUsername` value **must still match the VM's actual existing local administrator username**, or the deployment can fail outright rather than being silently and safely ignored. `@secure()` only prevents the value from being logged/resolved by what-if; it provides no mismatch protection. Always confirm the real value out-of-band before deploying against an already-converged VM; never assume immutability makes an incorrect value safe to supply.

**Known limitation:** the APP application data disk's caching is set to `None` as a conservative default since the task defining this capability did not specify a caching value for it (unlike the two SQL disks, which have explicit required values). OS disk size (`osDiskSizeGiB = 127`) preserves the current LIMS v1 OS disk size and must be kept in sync across the module, entrypoint, and both parameter files if it ever needs to change.

**Patch settings (added for the patch-onboarding pilot below).** Both VMs' `windowsConfiguration` declare `provisionVMAgent: true`, `enableAutomaticUpdates: true`, and `patchSettings` with `assessmentMode`/`patchMode` set to `AutomaticByPlatform` and `automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule: true`; no VM-level `rebootSetting` override is declared, so the existing maintenance configurations' `IfRequired` behavior is preserved. The real and example parameter files' `tags` now also include `dataClassification: 'non-production'`, which is what makes both VMs members of the existing `mc-lims-nonprod-westeu` maintenance configuration's dynamic scope. Bicep declares these desired VM-level settings; the Policy pilot below is what keeps them from drifting after initial deployment — see "LIMS WS2025 DEV v2 — patch onboarding (Policy pilot)" immediately below.

**Before the next redeployment of the already-converged v2 VMs — customer checklist.** All existing operational safeguards above (required live inputs, Entra object IDs, secret pipeline credentials) still apply; in addition:

1. Populate `appExistingUserAssignedIdentityResourceIds` / `sqlExistingUserAssignedIdentityResourceIds` in the real parameter file with the authoritative resource ID(s) of whichever user-assigned identity/identities Azure Policy (or anything else outside Bicep) has actually attached to each VM — see "Preserving existing VM identities" above. Do not leave these at the placeholder/empty default.
2. When syncing the customer's real parameter file with this repository's reviewed changes, preserve the customer's own real resource-ID values (`resourceGroupResourceId`, `subnetResourceId`, `diskEncryptionSetResourceId`), the populated `*LoginPrincipalIds` arrays, and the admin credential wiring exactly as the customer has them — only merge in the new identity parameters and any other reviewed code changes, do not overwrite real values with this repository's placeholders.
3. Confirm the customer parameter file's `tags` include `dataClassification: 'non-production'` (required for `mc-lims-nonprod-westeu` dynamic-scope membership — see "Patch settings" above); this should already be present from the prior patch-onboarding change, but verify it wasn't lost during sync.
4. Before deploying, confirm out-of-band that each disk's live `tier`, `networkAccessPolicy`, and `publicNetworkAccess` still match this module's defaults (`P10`/`P30`/`P20` baseline tiers, `AllowAll`, `Enabled`) — if any were manually changed since initial deployment (e.g. hardened to `DenyAll`/`Disabled`, or a disk's tier was manually burst-changed), either update the corresponding `*DiskTier` parameter to match, or treat the mismatch as a separate decision before deploying; this module does not read live state to detect that for you.
5. Expect the next `what-if` to show: both VMs' `identity` unchanged (`SystemAssigned, UserAssigned` retained, with every supplied UAI resource ID still present); the intended `patchMode`/`assessmentMode` and tag changes applying as before; disk `tier`/`networkAccessPolicy`/`publicNetworkAccess`, NIC `auxiliaryMode`/`auxiliarySku`/`disableTcpStateTracking`/`privateIPAddressVersion`, and data-disk `name`/`deleteOption` all showing `NoChange` (now explicitly declared, matching current state); the v1 LIMS DEV resources still ignored (untouched).
6. Review the "Remaining what-if differences reviewed, confirmed as service-generated" list above for anything still shown by what-if after this change — none of those require a code change or a live check beyond the `adminUsername` match called out there.

This module declares no `Microsoft.Authorization/locks` resource and this change does not introduce one; resource locking remains out of scope unless a separate, explicit architecture decision approves it (see [`docs/scope.md`](scope.md)).

### LIMS WS2025 DEV v2 — patch onboarding (Policy pilot)

Assigns two Microsoft built-in Azure Policy definitions (never copied into custom definitions) to maintain the Windows Update Manager patch settings declared on the two LIMS WS2025 DEV v2 virtual machines above, reusing their existing non-prod maintenance schedule membership. Approved under the narrow, named exception recorded in [`docs/scope.md`](scope.md#lims-ws2025-dev-v2--patch-onboarding-policy-pilot); it is not general Policy authority and does not extend to any other VM, workload, or environment.

- **Reusable module:** [`modules/compute/lims-ws2025-dev-patch-policy/main.bicep`](../modules/compute/lims-ws2025-dev-patch-policy/main.bicep) — resource-group-scoped; references the two VMs as `existing` only (never creates or modifies them); no hardcoded subscription/resource-group/VM-name/identity values.
- **Reusable entrypoint:** [`src/compute/lims-ws2025-dev-patch-policy/main.bicep`](../src/compute/lims-ws2025-dev-patch-policy/main.bicep) — subscription-scoped; target subscription and resource group are both derived from the same `resourceGroupResourceId` shape used by the compute foundation (intentionally the same resource group — not a separate one).
- **Configuration:** see [`config/example/compute/lims-ws2025-dev-patch-policy.bicepparam`](../config/example/compute/lims-ws2025-dev-patch-policy.bicepparam) for the parameter shape; the real (non-secret) DEV configuration lives at [`config/nfi/lims/compute/lims-ws2025-dev-patch-policy.bicepparam`](../config/nfi/lims/compute/lims-ws2025-dev-patch-policy.bicepparam) and is not deployment-ready until its `REPLACE_WITH_REAL_VALUE:` placeholders are replaced — see the comments at the top of that file.
- **Deployment pipeline:** [`deploy-lims-ws2025-dev-patch-policy.yml`](../.azuredevops/pipelines/deploy-lims-ws2025-dev-patch-policy.yml) — `trigger: none`/`pr: none`; supports an explicit `what-if` (default) or `deploy` action, run manually; kept independently runnable from the compute-foundation pipeline. Needs no admin-credential pipeline variables (unlike the compute-foundation pipeline). Each `AzureCLI@2` task independently selects and verifies the target subscription from an explicit `targetSubscriptionId` pipeline parameter mapped through that task's own `env:` block, the same reviewed pattern used by the compute-foundation pipeline.

**What this creates:** exactly four `Microsoft.Authorization/policyAssignments` resources, individually scoped to the two named VMs (never to the subscription or resource group):

| VM | Assignment | Built-in policy | Effect | Key parameters |
|---|---|---|---|---|
| `vm-lims-dev-v2-westeu-001` (APP) | `lims-dev-v2-app-patch-assessment` | Configure periodic checking for missing system updates on azure virtual machines (`59efceea-0c96-497e-a4a1-4eb2290dac15`) | Modify (fixed) | `assessmentMode=AutomaticByPlatform`, `osType=Windows` |
| `vm-lims-dev-v2-westeu-001` (APP) | `lims-dev-v2-app-patch-schedule-prereq` | Set prerequisite for Scheduling recurring updates on Azure virtual machines. (`9905ca54-1471-49c6-8291-7582c04cd4d4`) | DeployIfNotExists | `operatingSystemTypes=[Windows]`, `effect=DeployIfNotExists` |
| `vm-lims-dev-v2-westeu-002` (SQL) | `lims-dev-v2-sql-patch-assessment` | Configure periodic checking for missing system updates on azure virtual machines (`59efceea-0c96-497e-a4a1-4eb2290dac15`) | Modify (fixed) | `assessmentMode=AutomaticByPlatform`, `osType=Windows` |
| `vm-lims-dev-v2-westeu-002` (SQL) | `lims-dev-v2-sql-patch-schedule-prereq` | Set prerequisite for Scheduling recurring updates on Azure virtual machines. (`9905ca54-1471-49c6-8291-7582c04cd4d4`) | DeployIfNotExists | `operatingSystemTypes=[Windows]`, `effect=DeployIfNotExists` |

Each assignment's `identity` is `UserAssigned`, keyed by the `userAssignedIdentityResourceId` parameter — see "Managed identity reuse" below.

**What this does not do:** does not assign the broader "Schedule recurring updates using Azure Update Manager" policy; does not create or modify any maintenance configuration, dynamic scope, or direct/static maintenance assignment (schedule membership is supplied entirely by the existing `mc-lims-nonprod-westeu` dynamic scope and the `dataClassification=non-production` tag set by the compute foundation, not by this composition); does not create an automatic remediation task; does not create any identity, Entra object, custom role, or new RBAC grant; does not touch the v1 LIMS DEV VMs, `mc-lims-prod-westeu`, or any other existing maintenance configuration.

**Managed identity reuse.** `userAssignedIdentityResourceId` is a required, explicit, non-secret parameter holding the full resource ID of one existing, already-approved user-assigned managed identity used for deployment/remediation — see [`docs/scope.md`](scope.md#managed-identity-reuse-user-assigned-existing-identity-only--lims-ws2025-dev-v2-patch-onboarding). It is never guessed or reconstructed. Both built-in definitions above list the built-in Contributor role for remediation; **before running a `deploy` action**, verify out-of-band that this identity already holds effective Contributor (or equivalent) permission at the scope of the two VMs, and that the service connection used by the pipeline has permission to attach (reference) this existing identity on a policy assignment. Neither check is performed by this repository, and no new RBAC grant is declared anywhere in this composition.

**Required live inputs before this can be deployed (not available in this repository):**

- The resource ID of the existing `rg-compute-lims-dev-westeu` resource group (same value as the compute foundation's `resourceGroupResourceId`).
- The resource ID of the existing, already-approved user-assigned managed identity to reuse for remediation (`userAssignedIdentityResourceId`).

**Remediation and verification is a separate, explicit, post-deployment step — not part of this implementation.** No automatic remediation task is created. After a `deploy` action:

- `what-if` does not preview downstream Policy remediation or runtime patch operations — it only shows the four `policyAssignment` resources themselves.
- Creating an assignment does not, by itself, correct any resource that is already non-compliant; existing non-compliance on either VM is not resolved merely because the assignment now exists.
- A successful periodic assessment does not prove successful scheduled patching — assessment and patch installation are separate operations.
- After deploying, manually (outside this repository, outside Team Ruby working hours, and only against these two VMs) confirm: both VMs show `dataClassification=non-production` and are members of `mc-lims-nonprod-westeu`'s dynamic scope; neither VM is a member of `mc-lims-prod-westeu`'s scope; both VMs report a successful update assessment; both policy assignments report compliant (remediating only these two resources if not, per the "Managed identity reuse" permission checks above); and, once the next maintenance window has run, that a scheduled patch installation actually completed.

**Explicitly out of scope** (for this pilot and for the compute foundation it builds on): monitoring/alerting on patch compliance, backup, Azure Machine Configuration guest baselines, VM power scheduling/start-stop automation, SQL Server installation/configuration, guest disk initialization, and any application/data migration. Expansion of this patch-onboarding approach to `tst`/`acc`/`preprd`/`prd` or to the v1 LIMS VMs requires a separate, specifically reviewed change — this pilot covers only the two named v2 DEV VMs.

### LIMS WS2025 DEV v2 — time-zone enforcement (Machine Configuration + dedicated policy assignments)

Installs the Azure Machine Configuration (Guest Configuration) extension on the two LIMS WS2025 DEV v2 virtual machines above, and assigns a **dedicated**, VM-scoped copy of the built-in time-zone policy to each of those two VMs — deliberately separate from, and without granting any permission to, an already-existing, separately-managed subscription-scoped time-zone enforcement policy assignment. Approved under the two narrow, named exceptions recorded in [`docs/scope.md`](scope.md#lims-ws2025-dev-v2--time-zone-enforcement-machine-configuration-extension); it does not create, modify, or reference the existing subscription-scoped assignment itself, and does not extend to any other VM, workload, or environment.

**Given/existing (not created by this repository):** a subscription-scoped policy assignment named `configure-windows-timezone-dev`, using built-in definition "Configure time zone on Windows machines" (`6141c932-9384-44c6-a395-59e4c057d7c9`, version `3.1.0`), with `TimeZone="(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna"`, `IncludeArcMachines=false`, enforcement `Default`, and a system-assigned identity whose principal ID is `2dea906c-2e98-4b2c-ab4b-2d002de614e7`. Both VMs currently report `GCExtensionMissing`.

**Corrected record — v1/v2 resource-group membership is confirmed, not unknown.** An earlier version of this section stated it was unresolved whether the v1 LIMS DEV VMs share `rg-compute-lims-dev-westeu` with the two v2 VMs. Customer-supplied what-if screenshots confirm both v1 and v2 VMs reside in that same resource group. This is now treated as established fact throughout this document and in `docs/scope.md`, and is the direct reason the implementation below does not grant any permission to the existing subscription-scoped assignment's identity — see "Why a dedicated composition" below.

**Why a dedicated composition instead of granting the existing broader assignment's identity permission at `rg-compute-lims-dev-westeu` scope:** granting `2dea906c-2e98-4b2c-ab4b-2d002de614e7` (the existing `configure-windows-timezone-dev` identity) Guest Configuration Resource Contributor at the resource-group scope, combined with selecting only the two v2 VMs during manual remediation, does **not** isolate enforcement to v2. That broader assignment's own `policyRule` is not scoped to any particular VM — it evaluates every eligible Windows VM within its subscription-wide assignment scope, v1 included. A role grant only controls *permission*, not *evaluation scope*: once granted, that assignment could deploy a guest configuration assignment against any v1 VM that later becomes newly eligible (e.g. after an applicable image/configuration update), with no further action from this repository. The only way to structurally prevent that is to never grant that broader assignment's identity any additional permission, and instead give the two v2 VMs their own dedicated, VM-scoped policy assignments whose `policyRule` can only ever evaluate the one VM each is scoped to. The implementation below does this. The existing subscription-scoped assignment is left completely unchanged — see "Explicitly out of scope" below.

**Research performed for this change (verified against official Microsoft sources, not assumed):**

- The policy definition's nested-deployment template (fetched directly from the published source: `https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Guest%20Configuration/SetWindowsTimeZone_DINE.json`) sets `"assignmentType": "ApplyAndAutoCorrect"` on the Azure-VM resource branch of its nested template, not only the Arc-machine branch — i.e. applied once, then auto-corrected on drift, for Azure VMs specifically. Re-verified for this correction; unchanged from the prior research.
- `TimeZone="(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna"` is present verbatim in that definition's own `allowedValues` list. It is a free-form **display string**, distinct from the Windows time-zone **ID** (`W. Europe Standard Time`) that the `Get-TimeZone` PowerShell cmdlet reports for the same zone — the two must never be conflated or substituted for each other in policy/Bicep parameters.
- **`IncludeArcMachines` is declared by the definition as type `string`** (`"type": "string"`), with `allowedValues: ["true", "false"]` and `defaultValue: "false"` — not a Bicep boolean. The implementation below passes the literal string `'false'`, matching the definition's own declared type exactly, correcting an earlier assumption that this could be treated as a boolean.
- The Machine Configuration extension is documented as supported on Windows Server 2025 (Microsoft's guest-configuration baseline documentation), requires outbound HTTPS/443 connectivity (or Private Link) to the Guest Configuration service (a network prerequisite, not a repository code change, since this repository does not manage networking), and requires the VM to have a system-assigned managed identity — already satisfied by both VMs regardless of any user-assigned identity configuration (see the compute-foundation section above). **Installing this extension is not inert**: once present, it enables **any** applicable Guest Configuration policy in this subscription whose scope reaches these VMs — not only the two dedicated assignments created below, but also (for example) the existing subscription-scoped `configure-windows-timezone-dev` assignment, or any other current or future Guest-Configuration-based policy assigned at a scope that includes these VMs — to evaluate and potentially remediate them. This extension addition should be understood as broadening what *can* evaluate/act on these VMs, not merely as a prerequisite for the two assignments below.
- The Guest Configuration Resource Contributor role (`088ab73d-1256-47ae-bea9-9de8e7131f31`) is the single role the policy definition's own `policyRule.then.details.roleDefinitionIds` requires for remediation. Its action list already includes `Microsoft.Resources/deployments/*` alongside the `guestConfigurationAssignments` actions, so no second role is needed. Microsoft's "Remediate non-compliant resources" documentation confirms `deployIfNotExists` remediation's `existenceScope` defaults to `ResourceGroup`, and that the nested template deployment executes at the resource group of the target resource — so a VM-scoped-only grant would not cover the deployment-creation step even though the final `guestConfigurationAssignments` resource is itself a child of the VM. Microsoft's own documented quickstart pattern grants this role at resource-group scope (e.g. `--scope "$RG_ID" --identity-scope "$RG_ID"`), consistent with this conclusion. **This conclusion is unchanged by the correction below — only which identity receives the grant changed, not the scope reasoning.**

**What this implementation creates:**

- **Extension (via the existing compute-foundation composition, unchanged by this correction):** two `Microsoft.Compute/virtualMachines/extensions` resources (`AzurePolicyforWindows`, publisher `Microsoft.GuestConfiguration`, type `ConfigurationforWindows`) in [`modules/compute/lims-ws2025-dev-foundation/main.bicep`](../modules/compute/lims-ws2025-dev-foundation/main.bicep), one per VM, deployed unconditionally — mirroring how the existing `AADLoginForWindows` extension is declared. No change to [`src/compute/lims-ws2025-dev-foundation/main.bicep`](../src/compute/lims-ws2025-dev-foundation/main.bicep) was required. Deploying this change goes through the existing [`deploy-lims-ws2025-dev-foundation.yml`](../.azuredevops/pipelines/deploy-lims-ws2025-dev-foundation.yml) pipeline.
- **Dedicated time-zone policy + RBAC composition (replaces the earlier, rejected "grant the existing subscription identity a role" composition — renamed, not merely edited, to describe the final implementation):**
  - **Reusable module:** [`modules/compute/lims-ws2025-dev-timezone-policy/main.bicep`](../modules/compute/lims-ws2025-dev-timezone-policy/main.bicep) — resource-group-scoped; references the two VMs as `existing` only; declares two `Microsoft.Authorization/policyAssignments` resources (each `scope:`-ed to one VM, each with its own `identity: { type: 'SystemAssigned' }`) and two `Microsoft.Authorization/roleAssignments` resources (resource-group scope — the module's own default scope, no `scope:` override) whose `principalId` is resolved from each policy assignment's own `identity.principalId` output — never hardcoded or guessed — using deterministic names (`guid(resourceGroup().id, <policyAssignment.id>, <roleDefinitionId>)`) and `principalType: 'ServicePrincipal'`.
  - **Reusable entrypoint:** [`src/compute/lims-ws2025-dev-timezone-policy/main.bicep`](../src/compute/lims-ws2025-dev-timezone-policy/main.bicep) — subscription-scoped; target subscription and resource group are both derived from the same `resourceGroupResourceId` shape used by the compute foundation and the patch-policy pilot (intentionally the same resource group).
  - **Configuration:** see [`config/example/compute/lims-ws2025-dev-timezone-policy.bicepparam`](../config/example/compute/lims-ws2025-dev-timezone-policy.bicepparam) for the parameter shape; the real (non-secret) DEV configuration lives at [`config/nfi/lims/compute/lims-ws2025-dev-timezone-policy.bicepparam`](../config/nfi/lims/compute/lims-ws2025-dev-timezone-policy.bicepparam) and is not deployment-ready until its `REPLACE_WITH_REAL_VALUE:` resource-group-ID placeholder is replaced. This file contains **no** parameter referencing the existing `configure-windows-timezone-dev` assignment or its identity — that obsolete input was removed along with the rejected approach.
  - **Deployment pipeline:** [`deploy-lims-ws2025-dev-timezone-policy.yml`](../.azuredevops/pipelines/deploy-lims-ws2025-dev-timezone-policy.yml) — `trigger: none`/`pr: none`; supports an explicit `what-if` (default) or `deploy` action, run manually; every `AzureCLI@2` task independently selects and verifies the target subscription via an explicit `targetSubscriptionId` pipeline parameter, the same pattern used by the other pipelines; kept independently runnable from the compute-foundation and patch-policy pipelines. Needs no admin-credential pipeline variables. Creates no automatic remediation task.

**Exact policy scopes:** two `Microsoft.Authorization/policyAssignments` resources (`lims-dev-v2-app-timezone`, `lims-dev-v2-sql-timezone`), each scoped to exactly one VM resource (`vm-lims-dev-v2-westeu-001` and `vm-lims-dev-v2-westeu-002` respectively) — never the resource group, never the subscription.

**Exact RBAC scopes:** two `Microsoft.Authorization/roleAssignments` resources; role **Guest Configuration Resource Contributor** (`088ab73d-1256-47ae-bea9-9de8e7131f31`) in both cases; principal = each new dedicated policy assignment's own system-assigned identity (resolved at deployment time, never the existing `2dea906c-2e98-4b2c-ab4b-2d002de614e7`); scope = resource group `rg-compute-lims-dev-westeu` in both cases (not subscription, not a VM). **This RBAC grant's scope is the resource group — it is the policy assignments above, not this role grant, that are restricted to one VM each; do not describe the RBAC grant itself as VM-restricted.**

**What this does not do:** does not create, modify, delete, or exclude resources from the existing subscription-scoped `configure-windows-timezone-dev` policy assignment, its parameters, or its identity — that assignment, and its existing identity's existing permissions (it currently has none, per the Azure portal evidence supplied for this change), are left exactly as is; does not grant any permission to that existing identity; does not create any `Microsoft.GuestConfiguration/guestConfigurationAssignments` resource directly (created only by an applicable policy's own remediation, outside this repository's authority); does not create any custom policy or role definition; does not create any standalone user-assigned identity; does not grant subscription-wide Owner/Contributor or any subscription-scope role; does not create a remediation task; does not touch the four existing patch-policy assignments, the v1 LIMS DEV VMs, or any other resource.

**Expected `what-if` changes:**

- `deploy-lims-ws2025-dev-foundation.yml` what-if: two new `Microsoft.Compute/virtualMachines/extensions` resources shown as **Create** (one per VM, name `AzurePolicyforWindows`); every other resource (VMs, NICs, disks, `AADLoginForWindows` extensions, VM-login role assignments, tags, `patchSettings`, `encryptionAtHost`, identities) unchanged.
- `deploy-lims-ws2025-dev-timezone-policy.yml` what-if: two new `Microsoft.Authorization/policyAssignments` resources shown as **Create** (each scoped to one VM, each declaring a new `SystemAssigned` identity), and two new `Microsoft.Authorization/roleAssignments` resources shown as **Create**, scoped to `rg-compute-lims-dev-westeu`.
- Neither what-if touches the existing `configure-windows-timezone-dev` policy assignment, the four patch-policy assignments, or any VM property — what-if does not preview downstream Policy evaluation/remediation or prove either VM will subsequently become compliant.

**Identity/RBAC deployment-order considerations:** each role assignment's `principalId` is resolved from its own policy assignment's `identity.principalId` output within the same module deployment, so Azure Resource Manager handles the dependency ordering automatically (the role assignment is implicitly dependent on its policy assignment, via the symbolic reference) — no manual two-phase deployment is required. However, Azure Policy's own system-assigned identity provisioning for a brand-new assignment can occasionally lag slightly behind the ARM deployment's completion in Microsoft Entra ID; if a `deploy` action's role-assignment step were ever to fail with a "principal not found" class of error (not expected, but possible with newly created policy identities), the standard remediation is to re-run the same `deploy` action — the policy assignments are idempotent (`Incremental` mode) and will not be recreated, only the role assignment retried.

**Remaining customer inputs required before deployment (not available in this repository):**

- The resource ID of the existing `rg-compute-lims-dev-westeu` resource group (same value needed by the compute foundation and patch-policy `REPLACE_WITH_REAL_VALUE:` placeholders — replace all three together).
- No input referencing the existing `configure-windows-timezone-dev` assignment or its identity is required — this composition does not use it.

**Future consolidation decision (explicitly deferred, not decided here):** once the two dedicated v2 assignments are deployed and validated (see the procedure below), the two v2 VMs will be covered by **two overlapping** time-zone policy assignments — the existing subscription-scoped `configure-windows-timezone-dev` assignment and the two new dedicated assignments — all enforcing the same `TimeZone` value. This overlap is intentional and temporary: it lets the legacy scheduled script and both policy mechanisms coexist safely during cutover (see below), and is not itself a conflict (both assignments converge on the same desired state). Whether to later narrow `configure-windows-timezone-dev`'s scope to exclude the two v2 VMs (e.g. via `notScopes`), retire it in favor of the dedicated assignments, or leave the overlap in place long-term is a **separate, future decision** — it is explicitly out of scope for this change and must not be made implicitly by this implementation.

**Customer validation procedure (separate from, and after, this deployment — not automated by this repository):**

1. Verify the `AzurePolicyforWindows` extension's provisioning state is `Succeeded` on both VMs (e.g. `az vm extension show --resource-group rg-compute-lims-dev-westeu --vm-name vm-lims-dev-v2-westeu-001 --name AzurePolicyforWindows --query provisioningState`, and the same for `-002`), and that each VM no longer reports `GCExtensionMissing`.
2. In the Azure portal (or CLI), create a remediation task scoped to **only** the two new dedicated assignments (`lims-dev-v2-app-timezone`, `lims-dev-v2-sql-timezone`) — one remediation task per assignment is the normal Azure Policy pattern. Do **not** create or trigger a remediation task against the existing subscription-scoped `configure-windows-timezone-dev` assignment as part of this procedure.
3. After remediation completes, verify the resulting `Microsoft.GuestConfiguration/guestConfigurationAssignments` resource on each VM reports `assignmentType=ApplyAndAutoCorrect` and a `Compliant` state.
4. On each VM, run `Get-TimeZone` and confirm it returns `W. Europe Standard Time` — the Windows time-zone ID equivalent of the policy's display-string `TimeZone` parameter value above (same zone, different string representation; do not expect the display string itself to appear in `Get-TimeZone`'s output).
5. Do **not** deliberately change either VM's time zone to test drift/auto-correction without separate, explicit authorization.
6. Leave the legacy scheduled time-zone script enabled on both VMs until after this replacement has been cut over and validated per steps 1–4 above — do not disable it as part of this change.

**Explicitly out of scope:** any change to the existing `configure-windows-timezone-dev` policy assignment, its parameters, or its identity's permissions; any grant of permission to that existing identity; any new/duplicate direct guest configuration assignment; any custom policy or role definition; the broader "Deploy prerequisites to enable Guest Configuration policies on virtual machines" initiative; the v1 LIMS DEV VMs; any VM power/restart action; any remediation task creation (step 2 above is a manual, separate customer action); the future consolidation decision described above; and expansion to `tst`/`acc`/`preprd`/`prd` — this capability covers only the two named v2 DEV VMs.

## Continuous Integration

[`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml) is the only *automatically triggered* pipeline in this repository. It runs on every push to every branch, including `main`, and performs static validation only — it does not deploy or otherwise mutate Azure. There is no PR-specific trigger.

1. **Bicep build and lint** — every `*.bicep` file is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search unconditionally blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, or subscription creation, and separately blocks any *custom* `Microsoft.Authorization/roleDefinitions` resource declaration everywhere. It does not block `Microsoft.Authorization/roleAssignments`, or a `subscriptionResourceId(...)` reference to a built-in role definition, since assigning an existing Entra principal to an Azure role is not an Entra ID mutation (see [`docs/scope.md`](scope.md#rbac-and-entra-id-mutation-are-distinct)) — RBAC assignments are still governed by the "Explicit architecture decision required" boundary in that document, not by this guard.

Capability deployment pipelines (VM Availability, Cost Management Dashboard, Cost Management LAW Ingestion Foundation, Backup & Restore Dashboard, LIMS WS2025 DEV Compute Foundation, LIMS WS2025 DEV v2 Patch-Onboarding Policy Pilot, LIMS WS2025 DEV v2 Time-Zone Enforcement Policy) exist alongside `ci.yml`; none triggers automatically (`trigger: none`, `pr: none`) — each must be run manually. The workbook pipelines share their full validate/what-if/deploy steps via [`templates/deploy-observability-workbook-steps.yml`](../.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml); the LAW Ingestion Foundation pipeline reuses that same template only for its `what-if` action; the LIMS compute-foundation pipeline does not reuse it at all (see above).

One further manual, non-deployment pipeline exists: [`collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml) (the collector, no `schedules:` block). It wraps a script rather than performing a Bicep deployment, and is kept out of `ci.yml`'s automatic trigger for the same reason as the deployment pipelines — it must never run unattended before its output is reviewed.

Real, deployable configuration for any of the above (subscription IDs, workspace/resource-group names, policy allowlists, service-connection names) is supplied by a private configuration overlay, not committed to this repository — see the example parameter files under `config/example/observability/` for the shape each capability expects.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

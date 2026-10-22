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

**What this creates:** two VMs (`Standard_D4ads_v5`, Gen2, Trusted Launch with Secure Boot + vTPM, `encryptionAtHost` enabled, system-assigned managed identity, no public IP), one NIC per VM on the existing `snet-routable` subnet, a 127 GiB OS disk per VM (`osDiskSizeGiB`, explicitly set — not left at the Marketplace image default), a 128 GiB APP application data disk (future `A:`, not initialized or formatted here), a 1024 GiB SQL DATA disk (`ReadOnly` caching) and a 512 GiB SQL LOG disk (`None` caching), and the `AADLoginForWindows` extension on both VMs. All five managed disks use the existing Disk Encryption Set supplied via `diskEncryptionSetResourceId`.

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
- A secret pipeline variable group (or equivalent) providing the local administrator username/password used only as a deployment/break-glass credential — never committed to source.

**Known limitation:** the APP application data disk's caching is set to `None` as a conservative default since the task defining this capability did not specify a caching value for it (unlike the two SQL disks, which have explicit required values). OS disk size (`osDiskSizeGiB = 127`) preserves the current LIMS v1 OS disk size and must be kept in sync across the module, entrypoint, and both parameter files if it ever needs to change.

**Patch settings (added for the patch-onboarding pilot below).** Both VMs' `windowsConfiguration` declare `provisionVMAgent: true`, `enableAutomaticUpdates: true`, and `patchSettings` with `assessmentMode`/`patchMode` set to `AutomaticByPlatform` and `automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule: true`; no VM-level `rebootSetting` override is declared, so the existing maintenance configurations' `IfRequired` behavior is preserved. The real and example parameter files' `tags` now also include `dataClassification: 'non-production'`, which is what makes both VMs members of the existing `mc-lims-nonprod-westeu` maintenance configuration's dynamic scope. Bicep declares these desired VM-level settings; the Policy pilot below is what keeps them from drifting after initial deployment — see "LIMS WS2025 DEV v2 — patch onboarding (Policy pilot)" immediately below.

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

## Continuous Integration

[`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml) is the only *automatically triggered* pipeline in this repository. It runs on every push to every branch, including `main`, and performs static validation only — it does not deploy or otherwise mutate Azure. There is no PR-specific trigger.

1. **Bicep build and lint** — every `*.bicep` file is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search unconditionally blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, or subscription creation, and separately blocks any *custom* `Microsoft.Authorization/roleDefinitions` resource declaration everywhere. It does not block `Microsoft.Authorization/roleAssignments`, or a `subscriptionResourceId(...)` reference to a built-in role definition, since assigning an existing Entra principal to an Azure role is not an Entra ID mutation (see [`docs/scope.md`](scope.md#rbac-and-entra-id-mutation-are-distinct)) — RBAC assignments are still governed by the "Explicit architecture decision required" boundary in that document, not by this guard.

Capability deployment pipelines (VM Availability, Cost Management Dashboard, Cost Management LAW Ingestion Foundation, Backup & Restore Dashboard, LIMS WS2025 DEV Compute Foundation, LIMS WS2025 DEV v2 Patch-Onboarding Policy Pilot) exist alongside `ci.yml`; none triggers automatically (`trigger: none`, `pr: none`) — each must be run manually. The workbook pipelines share their full validate/what-if/deploy steps via [`templates/deploy-observability-workbook-steps.yml`](../.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml); the LAW Ingestion Foundation pipeline reuses that same template only for its `what-if` action; the LIMS compute-foundation pipeline does not reuse it at all (see above).

One further manual, non-deployment pipeline exists: [`collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml) (the collector, no `schedules:` block). It wraps a script rather than performing a Bicep deployment, and is kept out of `ci.yml`'s automatic trigger for the same reason as the deployment pipelines — it must never run unattended before its output is reviewed.

Real, deployable configuration for any of the above (subscription IDs, workspace/resource-group names, policy allowlists, service-connection names) is supplied by a private configuration overlay, not committed to this repository — see the example parameter files under `config/example/observability/` for the shape each capability expects.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

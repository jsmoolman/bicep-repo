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

Reports Azure costs by Environment and Service, six calendar months at a time, with a month-over-month Trend and a Trend vs 5M Avg column on the Service grid.

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
- The Service grid's Trend vs 5M Avg compares the selected Report Month against the arithmetic average of the other five displayed months, computed independently per service, using the same symbols/rounding as Trend; it is `-` for the current month, when the selected month's snapshot is unavailable, or when any one of the five preceding months' snapshots is unavailable — the average is never computed from fewer than all five.
- The six monthly monetary columns and Total column on the Environment and Service grids are right-aligned; Environment, Service, and trend columns are not.
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

## Continuous Integration

[`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml) is the only *automatically triggered* pipeline in this repository. It runs on every push to every branch, including `main`, and performs static validation only — it does not deploy or otherwise mutate Azure. There is no PR-specific trigger.

1. **Bicep build and lint** — every `*.bicep` file is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, subscription creation, or role assignment/definition resource types, enforcing the boundaries in [`docs/scope.md`](scope.md).

Capability deployment pipelines (VM Availability, Cost Management Dashboard, Cost Management LAW Ingestion Foundation, Backup & Restore Dashboard) exist alongside `ci.yml`; none triggers automatically (`trigger: none`, `pr: none`) — each must be run manually. The workbook pipelines share their full validate/what-if/deploy steps via [`templates/deploy-observability-workbook-steps.yml`](../.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml); the LAW Ingestion Foundation pipeline reuses that same template only for its `what-if` action.

One further manual, non-deployment pipeline exists: [`collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml) (the collector, no `schedules:` block). It wraps a script rather than performing a Bicep deployment, and is kept out of `ci.yml`'s automatic trigger for the same reason as the deployment pipelines — it must never run unattended before its output is reviewed.

Real, deployable configuration for any of the above (subscription IDs, workspace/resource-group names, policy allowlists, service-connection names) is supplied by a private configuration overlay, not committed to this repository — see the example parameter files under `config/example/observability/` for the shape each capability expects.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

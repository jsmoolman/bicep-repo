# Operations

This document describes only the operational behavior that actually exists in this repository today.

## Current state

### VM Availability SLA Dashboard v2 — lims

The first migrated observability capability. This is a lossless migration of a pre-existing, customer-approved LIMS Azure Monitor Workbook from a legacy repository — the workbook's KQL, layout, parameters, and behavior were preserved as-is; only file location and the module reference path changed.

- **Reusable entrypoint:** [`src/observability/vm-availability-sla-dashboard-v2/main.bicep`](../src/observability/vm-availability-sla-dashboard-v2/main.bicep) — subscription-scoped orchestrator, no LIMS-specific values, suitable for reuse by another project with a different parameter file.
- **Reusable module:** [`modules/observability/vm-availability-sla-dashboard-v2/main.bicep`](../modules/observability/vm-availability-sla-dashboard-v2/main.bicep) — the workbook resource definition, migrated unchanged from the legacy implementation.
- **LIMS configuration:** [`config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam`](../config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam) — one central workbook covering the `dev`/`tst`/`acc`/`preprd`/`prd` LIMS environments via `subscriptionEnvironmentMappings`, converted from the legacy ARM parameter JSON with all effective values unchanged.
- **Deployment pipeline:** [`.azuredevops/pipelines/deploy-vm-availability-sla-dashboard-v2.yml`](../.azuredevops/pipelines/deploy-vm-availability-sla-dashboard-v2.yml) exists but is **temporarily non-triggering** (`trigger: none`, `pr: none`) during commissioning. It supports an explicit `what-if` (default) or `deploy` action and must be run manually. It has not been run from this repository.
- **Live validation status:** No Azure what-if or deployment has been performed from this repository for this capability yet. This migration is a static, local-build-only change. Operational proof (a successful what-if against the live environment, followed by a reviewed deployment) is a separate future step.

**Known legacy naming detail:** the repository/capability name `VM Availability SLA Dashboard v2 - lims` refers to this capability in documentation and file paths only. It is not the literal customer-visible name produced by the deployed workbook. The existing (unchanged) legacy implementation actually produces:

- an in-workbook title of `VM Availability SLA Dashboard v2 — lims` (note: em dash, not a hyphen), and
- an Azure Portal workbook gallery `displayName` of `workbook-vm-availability-v2-lims-westeu`, which does not resemble the descriptive name at all.

This migration intentionally preserved both values unchanged, since the deployed workbook, its resource GUID/name logic, and its customer-visible display name/title must not change as part of relocating the implementation into this repository.

### Cost Management — lims

**Purpose.** Reports LIMS Azure costs by Environment and Service, six calendar months at a time, with a month-over-month Trend on the Service grid.

**Components:**

- **Snapshot Collector:** [`scripts/observability/Invoke-CostManagementSnapshotCollector.ps1`](../scripts/observability/Invoke-CostManagementSnapshotCollector.ps1), run via [`.azuredevops/pipelines/collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml).
- **LAW Ingestion Foundation:** [`modules/observability/cost-management-data-foundation/main.bicep`](../modules/observability/cost-management-data-foundation/main.bicep) / [`src/observability/cost-management-data-foundation/main.bicep`](../src/observability/cost-management-data-foundation/main.bicep) / [`cost-management-data-foundation.bicepparam`](../config/nfi/lims/observability/cost-management-data-foundation.bicepparam), deployed via [`deploy-cost-management-data-foundation.yml`](../.azuredevops/pipelines/deploy-cost-management-data-foundation.yml). Creates the `CostManagementSnapshot_CL` custom table (Analytics plan, 730/730-day retention) and a `kind: Direct` Data Collection Rule (`dcr-cost-snapshot-westeu`) against the existing central workspace `law-reports-mgmt-westeu`. No workspace, DCE, identity, or role assignment is created.
- **Dashboard workbook:** [`modules/observability/cost-management-workbook/main.bicep`](../modules/observability/cost-management-workbook/main.bicep) / [`src/observability/cost-management-workbook/main.bicep`](../src/observability/cost-management-workbook/main.bicep) / [`cost-management-workbook.bicepparam`](../config/nfi/lims/observability/cost-management-workbook.bicepparam), deployed via [`deploy-cost-management-workbook.yml`](../.azuredevops/pipelines/deploy-cost-management-workbook.yml).

**Data flow:**

```text
Azure Cost Management API
  -> Snapshot Collector (one management-group query per month)
  -> Logs Ingestion API / Data Collection Rule
  -> CostManagementSnapshot_CL (Log Analytics, law-reports-mgmt-westeu)
  -> Cost Management Dashboard workbook
```

**How to collect a monthly snapshot.** Run `collect-cost-management-snapshot.yml` manually with `billingMonth` = `current` or a completed `YYYY-MM`. It issues exactly one management-group Cost Management query, resolves response columns by name, maps `SubscriptionId` to `Environment` via `subscriptionEnvironmentMappings`, and performs exactly one Logs Ingestion POST of the normalized 9-column rows. Any validation failure (missing column, `nextLink` pagination, zero rows, unmapped subscription) or non-2xx response from either API aborts the run before ingesting — a failed run never writes partial data. No schedule is configured; this is a manual operation today.

**How to deploy/update the workbook or foundation.** `deploy-cost-management-data-foundation.yml` and `deploy-cost-management-workbook.yml` are both manual (`trigger: none`, `pr: none`), default to `what-if`, and accept an explicit `deploy` action.

**Required permissions/prerequisites:**

- The collector's identity (the Azure DevOps service connection) requires the **Monitoring Metrics Publisher** role at the DCR's scope to ingest data. This role assignment is managed outside this repository — see [`docs/scope.md`](scope.md).
- Read/query access to `law-reports-mgmt-westeu` is required to view the workbook; granted separately.
- Read access to Cost Management at the configured management-group scope is required for the collector to query costs.

**Workbook behavior that matters operationally:**

- The workbook reads only `CostManagementSnapshot_CL`; it never calls the Cost Management API directly.
- The collector's writes are append-only. For each `Project` + `BillingMonth`, the workbook selects only the rows belonging to the newest complete `CollectionRunId` (identified by the `cost-{workloadName}-` prefix, excluding synthetic/diagnostic probes) — never a per-row `arg_max()`, which could mix rows from different runs.
- A cell/Total renders `€ 0,00` only when a valid snapshot exists with genuinely zero matching cost; it renders `-` when no valid snapshot exists for that month.
- The Environment grid's row order follows `subscriptionEnvironmentMappings`' configured order; `Total` is always last.
- The Service grid's `Trend` compares only the selected Report Month against the immediately preceding calendar month (not the six-month window), using cent-rounded aggregates so it matches the displayed money values; it is `-` for the current month or when either month's snapshot is unavailable.
- `managementGroupId` and `subscriptionEnvironmentMappings` in `cost-management-workbook.bicepparam` remain the collector script's own configuration source (read via `az bicep build-params`) — do not remove or restructure them for the workbook alone.

**Known final limitations:**

- The collector is manual-only; no `schedules:` block is configured.
- No Data Collection Endpoint (DCE) is configured; the DCR uses its own Direct ingestion endpoint. Adopting a DCE later requires updating both the foundation's parameter file (`dataCollectionEndpointResourceId`) and the collector's ingestion-endpoint configuration.
- A temporary synthetic Logs Ingestion probe pipeline ([`test-cost-management-ingestion.yml`](../.azuredevops/pipelines/test-cost-management-ingestion.yml)) remains available for diagnostics.

No other operational capability (alerts, Logic Apps, VM maintenance, backup automation, or other scripts under `operations/`) has been implemented yet.

## Continuous Integration

[`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml) is the only *automatically triggered* pipeline in this repository. It runs on every push to every branch, including `main`, and performs static validation only — it does not deploy or otherwise mutate Azure. There is no PR-specific trigger. Capability-specific deployment pipelines (see above) exist alongside it but are commissioning-safe and do not trigger automatically.

1. **Bicep build and lint** — every `*.bicep` file in the repository is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, subscription creation, or role assignment/definition resource types, enforcing the boundaries in [`docs/scope.md`](scope.md).

There is currently no automatic *deployment* pipeline. The three capability deployment pipelines described above (VM Availability SLA Dashboard v2, Cost Management Dashboard, Cost Management LAW Ingestion Foundation) exist alongside `ci.yml`; none triggers automatically (`trigger: none`, `pr: none` on all three) — each must be run manually. The first two share their full validate/what-if/deploy steps via [`.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml`](../.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml); the third reuses that same template only for its `what-if` action (its `deploy` action does not fit the template's workbook-specific output handling — see that pipeline's own header comment).

Two further manual, non-deployment pipelines exist for Cost Management, also `trigger: none`/`pr: none` and not triggered by `ci.yml`: [`collect-cost-management-snapshot.yml`](../.azuredevops/pipelines/collect-cost-management-snapshot.yml) (the collector, no `schedules:` block — see above) and the temporary [`test-cost-management-ingestion.yml`](../.azuredevops/pipelines/test-cost-management-ingestion.yml) synthetic-ingestion probe. Neither performs a Bicep deployment; both are kept out of `ci.yml`'s automatic trigger for the same reason as the deployment pipelines — they must never run unattended before their outputs are reviewed.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

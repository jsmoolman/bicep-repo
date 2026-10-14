# Architecture

## Purpose

This repository is a small, maintainable foundation for Azure operational automation, observability, reporting, and approved maintenance-as-code. See [`docs/scope.md`](scope.md) for the exact capability boundaries.

## Scope boundary

This repository does not manage management groups, subscription vending, tenant-wide policy, tenant-wide RBAC, or general landing-zone infrastructure. See [`docs/scope.md`](scope.md) for the full boundary.

A small number of specific, named workloads have an explicitly approved infrastructure exception recorded in `docs/scope.md` (e.g. the LIMS WS2025 compute foundation) — each exception states exactly which resources it covers. This is not general infrastructure authority: it does not extend to other workloads, and it does not change the default observability/reporting/maintenance-as-code scope for everything else in this repository.

## Design principles

1. **Reuse over duplication.** One reusable Bicep composition per deployment unit; environment and target differences are driven by configuration, not by duplicated Bicep.
2. **Configuration-driven targeting.** Target environment, subscription, management group (where relevant), region, and workload-specific values are supplied through configuration (`config/` — a private overlay for real deployments, examples under `config/example/` in this repository), not hardcoded into reusable modules or compositions, which stay environment- and customer-neutral.
3. **Bicep for declarative operational resources.** Workbooks, alerts, dashboards, diagnostic settings, and Logic Apps are declared in Bicep.
4. **PowerShell/Azure CLI for imperative actions.** Actions that are inherently imperative rather than declarative are implemented as scripts, not forced into Bicep. Standalone imperative maintenance actions not tied to any specific Bicep composition (e.g. a VM start/stop/restart) live under `operations/`. Imperative scripts that exist specifically to populate or support a declared observability composition (e.g. the Cost Management Snapshot Collector, which populates the table a Bicep-declared Data Collection Rule ingests into) live under `scripts/observability/` instead, alongside the composition they support.
5. **No state backend.** Normal idempotent ARM/Bicep deployment behavior is sufficient — no Terraform-style state, and no Azure Deployment Stacks used purely for resource-ownership tracking.
6. **No ALZ provisioning framework.** This repository does not manage management groups, subscription vending, tenant-wide policy, or tenant-wide RBAC.
7. **No default manual approval gates.** Deployment relies on CI validation and review, not enterprise approval-gate machinery, unless a specific future requirement calls for it.
8. **Simple merge-to-deploy target operating model:**

   ```
   feature branch → static validation (CI) → review → merge to main → automated validation → what-if where applicable → deployment
   ```

   A change intended for `prd` is not forced through `dev`/`tst`/`acc`/`preprd` first — environment applicability is explicit configuration, not a duplicated implementation or a mandatory promotion chain.

## Current state

Five real operational capabilities exist, following the same reusable-module + configuration pattern (one is a script, not a Bicep module, but follows the same "one reusable implementation, configuration drives differences" discipline):

- **VM Availability SLA Dashboard** — reusable module (`modules/observability/vm-availability-sla-dashboard-v2/`), subscription-scoped composition (`src/observability/vm-availability-sla-dashboard-v2/`), a manual-only deployment pipeline.
- **Cost Management Dashboard** workbook (`modules/observability/cost-management-workbook/`, `src/observability/cost-management-workbook/`) that reads monthly cost snapshots from `CostManagementSnapshot_CL` (below).
- **Cost Management LAW Ingestion Foundation** — a custom Log Analytics table (`CostManagementSnapshot_CL`) plus a Direct-ingestion Data Collection Rule, against an existing central Log Analytics workspace (`modules/observability/cost-management-data-foundation/`, `src/observability/cost-management-data-foundation/`).
- **Cost Management Snapshot Collector** (`scripts/observability/Invoke-CostManagementSnapshotCollector.ps1`) — one management-group Cost Management query per run, normalized into the foundation's 9-column shape, Environment mapped from repository configuration, written via one Logs Ingestion API POST. Run manually via `.azuredevops/pipelines/collect-cost-management-snapshot.yml`; no schedule is enabled yet.
- **Backup & Restore Dashboard** workbook (`modules/observability/backup-restore-workbook/`, `src/observability/backup-restore-workbook/`) that reads exclusively from existing Azure Backup Log Analytics tables (`AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy`) — it creates or modifies no vault, backup policy, protected item, diagnostic setting, or RBAC/identity resource.

Data flow (Cost Management):

```text
Cost Management API -> Snapshot Collector -> Logs Ingestion API / DCR ->
    CostManagementSnapshot_CL -> Cost Management Dashboard workbook
```

The workbook pipelines (VM Availability, Cost Management Dashboard, Backup & Restore) share their full validate/what-if/deploy steps via one template (`.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml`). The Cost Management LAW Ingestion Foundation's pipeline reuses that same template only for its `what-if` action. The Cost Management Snapshot Collector's pipeline deploys nothing; it wraps the collector script in a single step.

See [`docs/operations.md`](operations.md) for full operational detail.

No other operational capability (alerts, Logic Apps, or operational scripts under `operations/`) exists yet. Further capabilities are added only once specifically scoped and approved.

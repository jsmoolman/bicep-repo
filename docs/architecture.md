# Architecture

## Purpose

This repository is a small, maintainable foundation for NFI Azure operational automation, observability, reporting, and approved maintenance-as-code — primarily supporting LIMS. See [`docs/scope.md`](scope.md) for the exact capability boundaries.

## Scope boundary

This repository does not manage management groups, subscription vending, tenant-wide policy, tenant-wide RBAC, or general landing-zone infrastructure. The Azure DevOps service connection has no Entra ID permissions, so identity/RBAC-owning deployments cannot run. See [`docs/scope.md`](scope.md) for the full boundary.

## Design principles

1. **Reuse over duplication.** One reusable Bicep composition per deployment unit; environment and target differences are driven by configuration, not by duplicated Bicep.
2. **Configuration-driven targeting.** Target environment, subscription, management group (where relevant), region, and workload-specific values are supplied through configuration (`config/` — see "Current state" below), not hardcoded into reusable modules or compositions, which stay environment- and customer-neutral.
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

Four real operational capabilities exist, following the same reusable-module + configuration pattern (the fourth is a script, not a Bicep module, but follows the same "one reusable implementation, configuration drives differences" discipline):

- The LIMS **VM Availability SLA Dashboard v2** — reusable module (`modules/observability/vm-availability-sla-dashboard-v2/`), subscription-scoped composition (`src/observability/vm-availability-sla-dashboard-v2/`), LIMS configuration (`config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam`), and a commissioning-safe deployment pipeline run manually.
- A **Cost Management Dashboard** workbook (`modules/observability/cost-management-workbook/`, `src/observability/cost-management-workbook/`, `config/nfi/lims/observability/cost-management-workbook.bicepparam`) that reads monthly cost snapshots from `CostManagementSnapshot_CL` (below).
- A **Cost Management LAW Ingestion Foundation** — a custom Log Analytics table (`CostManagementSnapshot_CL`) plus a Direct-ingestion Data Collection Rule, against the existing central Log Analytics workspace (`modules/observability/cost-management-data-foundation/`, `src/observability/cost-management-data-foundation/`, `config/nfi/lims/observability/cost-management-data-foundation.bicepparam`).
- A **Cost Management Snapshot Collector** (`scripts/observability/Invoke-CostManagementSnapshotCollector.ps1`) — one management-group Cost Management query per run, normalized into the foundation's 9-column shape, Environment mapped from repository configuration, written via one Logs Ingestion API POST. Run manually via `.azuredevops/pipelines/collect-cost-management-snapshot.yml`; no schedule is enabled yet.

Data flow:

```text
Cost Management API -> Snapshot Collector -> Logs Ingestion API / DCR ->
    CostManagementSnapshot_CL -> Cost Management Dashboard workbook
```

The first two capabilities' deployment pipelines share their full validate/what-if/deploy steps via one template (`.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml`). The third capability's pipeline reuses that same template only for its `what-if` action. The fourth capability's pipeline deploys nothing; it wraps the collector script in a single step.

See [`docs/operations.md`](operations.md) for full operational detail.

No other operational capability (alerts, Logic Apps, or operational scripts under `operations/`) exists yet. Further capabilities are added only once specifically scoped and approved.

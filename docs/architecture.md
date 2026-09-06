# Architecture

## Purpose

This repository is a small, maintainable foundation for NFI Azure operational automation, observability, reporting, and approved maintenance-as-code — primarily supporting LIMS. See [`docs/scope.md`](scope.md) for the exact capability boundaries.

## Why this replaced the previous design

An earlier version of this repository was designed as a full Azure Landing Zone (ALZ) tenant-provisioning framework: management group hierarchy, subscription vending, platform connectivity/identity subscriptions, tenant-wide policy and RBAC, and a layered platform → landing-zone → workload deployment model with approval-gated pipelines per layer.

That design was replaced because:

- The Azure DevOps service connection has no Entra ID permissions, so identity/RBAC-owning deployments could never actually run.
- Tenant-wide infrastructure (management groups, subscription vending, hub networking) is outside this repository's authority and belongs to a separate, explicitly-approved decision if it is ever needed.
- The layered ALZ model and its approval-gate machinery added significant complexity for a repository whose real job is LIMS operational automation and observability, not tenant provisioning.

The old platform/landing-zone/subscription-vending/tenant-RBAC code and pipelines have been removed rather than kept for backward compatibility. They are not active capabilities of this repository.

## Design principles

1. **Reuse over duplication.** One reusable Bicep composition per deployment unit; environment and target differences are driven by configuration, not by duplicated Bicep.
2. **Configuration-driven targeting.** Target environment, subscription, management group (where relevant), region, and workload-specific values are supplied through configuration (`config/` — see "Current state" below), not hardcoded into reusable modules or compositions, which stay environment- and customer-neutral.
3. **Bicep for declarative operational resources.** Workbooks, alerts, dashboards, diagnostic settings, and Logic Apps are declared in Bicep.
4. **PowerShell/Azure CLI for imperative maintenance.** Operational actions that are inherently imperative (e.g. a VM start/stop/restart) are implemented as scripts under `operations/`, not forced into Bicep.
5. **No state backend.** Normal idempotent ARM/Bicep deployment behavior is sufficient — no Terraform-style state, and no Azure Deployment Stacks used purely for resource-ownership tracking.
6. **No ALZ provisioning framework.** This repository does not manage management groups, subscription vending, tenant-wide policy, or tenant-wide RBAC.
7. **No default manual approval gates.** Deployment relies on CI validation and review, not enterprise approval-gate machinery, unless a specific future requirement calls for it.
8. **Simple merge-to-deploy target operating model:**

   ```
   feature branch → static validation (CI) → review → merge to main → automated validation → what-if where applicable → deployment
   ```

   A change intended for `prd` is not forced through `dev`/`tst`/`acc`/`preprd` first — environment applicability is explicit configuration, not a duplicated implementation or a mandatory promotion chain.

## Current state

Three real operational capabilities now exist, following the same reusable-module + configuration pattern:

- The LIMS **VM Availability SLA Dashboard v2**, migrated losslessly from a prior, customer-approved implementation. It consists of a reusable module (`modules/observability/vm-availability-sla-dashboard-v2/`), a reusable subscription-scoped composition (`src/observability/vm-availability-sla-dashboard-v2/`), LIMS-specific configuration (`config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam`), and a commissioning-safe deployment pipeline that does not trigger automatically and must be run manually.
- A from-scratch **Cost Management Dashboard** single-query pivot proof of concept, following the identical pattern (`modules/observability/cost-management-workbook/`, `src/observability/cost-management-workbook/`, `config/nfi/lims/observability/cost-management-workbook.bicepparam`), reusing the existing central Log Analytics workspace purely as a stateless KQL compute engine (no data ingestion, no new LAW resources). It has not yet been live-validated. Its interactive, direct Cost Management API query is no longer the intended production data path — see the next capability and [`docs/operations.md`](operations.md).
- A **Cost Management LAW Ingestion Foundation** — the persisted-reporting-data destination (a custom Log Analytics table, `CostManagementSnapshot_CL`, plus a Direct-ingestion Data Collection Rule) that a future scheduled collector will write normalized monthly cost snapshots into, again against the same existing central Log Analytics workspace (`modules/observability/cost-management-data-foundation/`, `src/observability/cost-management-data-foundation/`, `config/nfi/lims/observability/cost-management-data-foundation.bicepparam`). Only the destination exists so far — no collector and no workbook refactor yet, and it has not been deployed.

The first two capabilities' deployment pipelines share their full validate/what-if/deploy steps via one small template (`.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml`) — extracted because there were two genuine consumers, not speculatively ahead of need. The third capability's pipeline reuses that same template only for its `what-if` action, since the template's deploy-time output handling is workbook-specific.

See [`docs/operations.md`](operations.md) for full operational detail on all three, including current live-validation status.

No other operational capability (alerts, Logic Apps, or operational scripts under `operations/`) exists yet. Further capabilities continue to be added only once specifically scoped and approved, avoiding speculative framework code for capabilities that do not exist yet.

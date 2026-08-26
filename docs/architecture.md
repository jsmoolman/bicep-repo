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
2. **Configuration-driven targeting.** Target environment, subscription, management group (where relevant), region, and workload-specific values are supplied through configuration (`config/`, once it has content — see "Current state" below), not hardcoded into reusable modules or compositions, which stay environment- and customer-neutral.
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

As of this milestone, the repository contains no deployable Bicep, modules, configuration, or operational scripts — only the pipeline and documentation foundation. There is no `config/` content yet; it is added alongside the first real composition that needs it. A deployment pipeline and the first real operational capability (e.g. a LIMS availability workbook or alert) will be added together in a future change, once specifically scoped and approved. This avoids speculative framework code for capabilities that do not exist yet.

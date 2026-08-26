---
applyTo: "**"
---

# Repository Structure Standards

## Purpose

This repository is a small, maintainable foundation for **NFI Azure operational automation, observability, reporting, and approved maintenance-as-code**, primarily supporting LIMS. It is **not** a general Azure Landing Zone / tenant-provisioning framework and must not be extended to manage the NFI tenant, landing zones, identity, networking, or general workload infrastructure by default.

See `docs/scope.md` for the full allowed / explicit-decision-required / prohibited capability boundaries before adding any new resource type.

## LIMS environments

The supported LIMS environments are exactly: `dev`, `tst`, `acc`, `preprd`, `prd`. Do not use a different environment list.

## Core design rule

- **One reusable deployment composition** per deployment unit.
- **Many parameter/config files** driving environment and target differences.
- **Small deployment units** with clear scope boundaries.
- No per-environment duplication of Bicep implementation.

## Area responsibilities

| Area | Purpose |
|---|---|
| `src/observability/` | Deployable compositions for workbooks, alerts, dashboards, monitoring |
| `src/automation/` | Declarative operational automation (approved Logic Apps) |
| `modules/` | Genuinely reusable, environment-neutral Bicep modules |
| `operations/` | Imperative operational functions (e.g. VM start/stop/restart) |
| `config/nfi/lims/` | LIMS-specific configuration per environment (dev/tst/acc/preprd/prd) |
| `config/nfi/shared/` | Configuration for reusable services targeting other subscriptions/management groups |
| `.azuredevops/` | Pipeline definitions — no portal usage |
| `docs/` | Purpose, scope, and architecture documentation |

## The critical distinction

```
modules  =  reusable, environment-neutral building blocks
src      =  deployable compositions / orchestration entry points
config   =  target environment, subscription, management group, and workload values
```

## Rules

- Bicep files must not be duplicated per environment — reuse the same composition with different param files.
- Modules must not contain hardcoded environment names or workload names.
- Do not create Entra ID / Microsoft Graph resources, application registrations, service principals, directory roles, or RBAC/managed-identity mutations. Identity is out of this repository's authority — see `docs/scope.md`.
- Do not provision general infrastructure (virtual networks, subnets, firewalls, VMs, storage, databases, Key Vault, application hosting, management groups, subscription vending, landing-zone topology) by default. These require an explicit, separate architecture decision.
- Do not introduce Terraform-style state, state storage, or Azure Deployment Stacks used purely for resource-ownership tracking.
- Do not create empty directories or placeholder modules for capabilities that do not yet exist — only add a directory once it has real, deployable content.
- No manual Azure Portal changes — all changes flow through pipelines.
- A reusable module is only justified when it is genuinely reused, or extracting it materially simplifies the calling composition. Do not create wrapper/orchestrator/factory layers solely for architectural appearance.

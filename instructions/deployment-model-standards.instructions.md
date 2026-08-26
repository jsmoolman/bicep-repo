---
applyTo: "**"
---

# Deployment Model Standards

## Operating model

```
feature branch → static validation (CI) → review → merge to main → automated validation → what-if where applicable → deployment
```

There is no layered platform → landing-zone → workload-vending deployment sequence in this repository, and no default manual Azure DevOps approval gate. A change intended for `prd` must not be forced artificially through `dev`, `tst`, `acc`, and `preprd` — environment applicability is explicit configuration, not a duplicated implementation or a mandatory promotion chain.

## Current pipeline

The only pipeline is `.azuredevops/pipelines/ci.yml`. It performs static validation on pull requests (Bicep build/lint, Bicep parameter file build, and a prohibited-resource-type guard) and does not deploy anything.

A deployment pipeline is added alongside the first real operational capability — do not build deployment/what-if/approval machinery ahead of an actual deployable composition.

## Identity boundary

The Azure DevOps service connection used by this repository has intentionally been granted **no Entra ID permissions** (customer policy). Never implement or plan around Entra/Graph mutations, RBAC creation, service principal management, or managed-identity creation. Do not treat the lack of identity permission as a defect to work around, and do not broaden permissions. See `docs/scope.md`.

## Deployment Stacks

Do not use Azure Deployment Stacks purely to introduce resource-ownership/state tracking. Normal idempotent ARM/Bicep deployment behavior is sufficient unless a later, specific requirement approves Deployment Stacks.

## Scope discipline

Infrastructure, networking, policy, RBAC, and subscription/management-group configuration changes require an explicit architecture decision before implementation — they are not default repository authority. See `docs/scope.md` for the full boundary.

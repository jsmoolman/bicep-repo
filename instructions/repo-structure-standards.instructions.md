---
applyTo: "**"
---

# Repository Structure Standards

## Core design rule

The repo must NOT be one folder per environment with duplicated Bicep.
It must be:

- **One reusable deployment composition** per deployment unit
- **Many parameter/config files** driving environment differences
- **Pipeline-controlled promotion** between environments
- **Small deployment units** with clear scope boundaries

## Area responsibilities

| Area | Purpose |
|---|---|
| `src/platform` | Tenant-wide and platform shared services |
| `src/landing-zones` | Subscription vending and landing zone baselines |
| `src/workloads` | Workload-specific resources (e.g. lims) |
| `modules/` | Reusable building blocks — no environment names, no hardcoded workload names |
| `config/` | Customer, landing zone, subscription, and environment-specific values |
| `lib/alz` | ALZ policy/archetype library and customer overrides |
| `.azuredevops/` | All deployment orchestration — no portal usage |
| `tests/` | Linting, PSRule, validation, policy tests |

## The critical distinction

```
modules  =  reusable, environment-neutral building blocks
src      =  deployable compositions / orchestration entry points
config   =  customer, landing zone, subscription, environment values
lib      =  ALZ policy/archetype library and overrides
```

## Rules

- Bicep files must not be duplicated per environment — reuse the same composition with different param files.
- Modules must not contain hardcoded environment names or workload names (e.g. `lims`).
- Workload deployments must not modify tenant-wide platform resources.
- Platform deployments must not contain workload-specific details.
- Scripts support deployments; they do not replace Bicep where Bicep is suitable.
- No manual Azure Portal changes — all changes flow through pipelines.

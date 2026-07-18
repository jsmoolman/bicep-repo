---
applyTo: "**"
---

# Deployment Model Standards

## Layered deployment order

Always deploy in this sequence — later layers depend on earlier ones.

| Step | Layer | Scope |
|---|---|---|
| 0 | **Bootstrap** _(manual, once)_ — identities, service connections, initial RBAC | tenant |
| 1 | **Platform Core** — MG hierarchy, role definitions, policy definitions, initiatives, assignments | management group |
| 2 | **Platform Subscriptions** — management, connectivity, identity/security subscriptions | management group |
| 3 | **Platform Shared Services** — Log Analytics, Automation, Defender/Sentinel, DCRs, alerts, hub network | subscription |
| 4 | **Subscription Vending** — create workload subscriptions, MG placement, budgets, baseline RBAC | management group |
| 5 | **Landing Zone Baseline** — resource groups, tags, diagnostics, monitoring, backup, RBAC per subscription | subscription |
| 6 | **Workload Deployment** — application resources, alerts, VM extensions, backup policies | subscription / resource group |

## Pipeline model

```
Pull Request
  -> bicep restore → build → lint
  -> PSRule for Azure
  -> what-if  (plan identity — read/what-if only)
  -> publish what-if output as artefact

Merge to main
  -> what-if again  (plan identity)
  -> manual approval gate for protected environments
  -> deploy  (apply identity — scoped write, post-approval only)
```

## Identity separation

| Identity | Permissions | Used by |
|---|---|---|
| **Plan identity** | Reader + What-if | PR pipelines |
| **Apply identity** | Contributor (scoped to deployment scope) | Deploy pipelines, after approval |

Scope as narrowly as possible: prefer resource group scope for workload resources; only use management group or tenant scope where strictly required.

## Deployment Stacks guidance

Consider Azure Deployment Stacks for platform and baseline layers.

**Good candidates** — `detach-on-unmanage` safe to start:
- Management group policy assignments
- Landing zone baseline resources
- Standard monitoring resources
- Dev/test environments

**Avoid delete-on-unmanage for:**
- Production workload resources
- Shared connectivity resources
- Anything with persistent data
- Anything where accidental deletion would be dangerous

Start with `actionOnUnmanage: detachAll`. Only move to `deleteAll` for well-understood, non-data stacks.

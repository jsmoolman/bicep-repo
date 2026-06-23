# Deployment Flow

## Overview

Deployments follow a strict layered ordering to ensure dependencies are satisfied before dependent layers are applied. Each deployment unit maps to a pipeline in `.azuredevops/pipelines/`.

Portal changes are not allowed. All Azure changes must flow through this pipeline model.

---

## Layered Deployment Model

### 0. Bootstrap _(manual / one-time)_

> Executed once per tenant. Requires elevated access. Not managed by the standard pipelines.

- Deployment identities (managed identities or service principals)
- Federated credentials and Azure DevOps service connections
- Initial RBAC to allow pipeline identities to operate
- Pipeline permissions and environment approvals

### 1. Platform Core

> **Pipeline:** `deploy-platform-core.yml` — Scope: management group

- Management group hierarchy
- Custom role definitions
- Policy definitions
- Policy initiatives
- Root-level policy assignments

### 2. Platform Subscriptions

> **Pipeline:** `deploy-platform-core.yml` (subscription placement)

- Management subscription provisioning
- Connectivity subscription provisioning
- Identity / security subscription (if applicable)

### 3. Platform Shared Services

> **Pipelines:** `deploy-platform-management.yml`, `deploy-platform-connectivity.yml`

- Log Analytics workspace
- Automation Account
- Microsoft Defender for Cloud / Sentinel (if required)
- Data Collection Rules
- Baseline metric and activity log alerts
- Hub VNet / vWAN / Azure Firewall integration

### 4. Subscription Vending

> **Pipeline:** `deploy-subscription-vending.yml` — Scope: management group

- Create or configure workload subscriptions
- Place subscriptions in correct management groups
- Apply subscription-level budgets
- Apply baseline RBAC
- Optional empty spoke network baseline

### 5. Landing Zone Baseline

> **Pipeline:** `deploy-landing-zone-baseline.yml` — Scope: subscription (per subscription)

- Resource groups
- Tags
- Diagnostic settings pointing to central Log Analytics
- Monitoring (activity log alerts, resource health alerts)
- Backup baseline
- Standard RBAC assignments

### 6. Workload Deployment

> **Pipeline:** `deploy-workload.yml` — Scope: subscription or resource group

- Application resources
- Workload-specific monitoring and alerting
- VM extensions
- Backup policies
- Application-specific infrastructure (e.g., App Services, SQL VMs)

---

## Deployment Dependency Graph

```
0. Bootstrap (manual)
       │
       ▼
1. Platform Core  ──────────────────────────────────────────────┐
       │                                                         │
       ▼                                                         │ (policies applied at MG)
2. Platform Subscriptions                                        │
       │                                                         │
       ▼                                                         │
3. Platform Shared Services                                      │
   (management + connectivity + identity + security)            │
       │                                                         │
       ▼                                                         │
4. Subscription Vending ─────────────────────────────────────────┘
       │
       ▼
5. Landing Zone Baseline (per subscription, parallelisable)
       │
       ▼
6. Workload Deployment (per environment, parallelisable after step 5)
```

---

## Pipeline Flow

### Pull Request

```
PR opened / updated
  ├── bicep restore
  ├── bicep build (compile check)
  ├── bicep lint
  ├── PSRule for Azure
  └── What-if (using plan identity — read only)
        └── Publish what-if output as pipeline artefact
```

All PR gates must pass before merge is allowed. What-if output must be reviewed by a reviewer before approving.

### Merge to `main`

```
Merge to main
  ├── What-if (repeated using plan identity)
  ├── Manual approval gate (for protected environments)
  └── Deploy (using apply identity — scoped write permissions)
        └── Publish deployment evidence as pipeline artefact
```

---

## Identity and Access Model

Two separate identities are used to enforce review before apply.

| Identity | Permissions | When used |
|---|---|---|
| **Plan identity** | Reader + What-if | PR pipelines and pre-deploy what-if |
| **Apply identity** | Contributor (scoped) | Post-approval deploy pipelines |

The apply identity is protected by Azure DevOps environment approval gates. No pipeline can use the apply identity without an explicit approval by an authorised reviewer.

Privileged access is scoped as narrowly as possible:

| Deployment scope | Required for |
|---|---|
| Tenant | Bootstrap only |
| Management group | Policy assignments, hierarchy, role definitions |
| Subscription | Subscription baseline, vending |
| Resource group | Workload resources (preferred) |

---

## Branching Strategy

| Branch | Purpose | Pipeline triggered |
|---|---|---|
| `main` | Production-ready state | Deploy pipelines (with approval gates) |
| `release/*` | Release candidates | Deploy to preprd |
| `feature/*` | Developer branches | PR what-if only |
| `fix/*` | Hotfix branches | PR what-if only |

---

## Environment Promotion

```
dev → tst → acc → preprd → prd
```

Promotion between environments requires:
1. Successful deployment to the previous environment.
2. Manual approval gate in Azure DevOps for `acc`, `preprd`, and `prd`.
3. What-if reviewed and signed off for `preprd` and `prd`.

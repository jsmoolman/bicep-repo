# azure-nfi-iac

**NFI Azure operational automation and observability-as-code** foundation, built with Bicep — for operational automation, observability, reporting, and approved maintenance-as-code, not general infrastructure provisioning.

The primary consumer is **LIMS**. Selected reusable capabilities (for example availability or cost workbooks) may also target other NFI project subscriptions or a management-group scope, without duplicating implementation per consumer.

## What this repository is not

This repository is **not** a general Azure Landing Zone or tenant-provisioning framework. It does not manage the NFI tenant, landing zones, identity, networking, or general workload infrastructure. See [`docs/scope.md`](docs/scope.md) for the exact boundary between what is allowed by default, what requires an explicit architecture decision, and what is prohibited.

Key boundaries:

- **Identity is out of scope.** The Azure DevOps service connection used by this repository has intentionally been granted no Entra ID permissions. This repository contains no deployable functionality for Entra users/groups, app registrations, service principals, directory roles, Microsoft Graph mutations, or RBAC/managed-identity creation.
- **General infrastructure provisioning is out of scope by default.** Networking, virtual machines, storage, databases, Key Vault, application hosting, management groups, subscription vending, and landing-zone construction are not provisioned from this repository unless a specific, separate architecture decision approves it.
- **No Terraform-style state.** This repository relies on normal idempotent Azure Resource Manager / Bicep deployment behavior — no state files, state storage accounts, or deployment-state databases.

## Supported LIMS environments

Exactly:

- `dev`
- `tst`
- `acc`
- `preprd`
- `prd`

## Repository structure

```
azure-nfi-iac/
├── .azuredevops/pipelines/   # Pipeline definitions (currently: one static-validation CI pipeline)
├── docs/                     # Purpose, scope, and architecture documentation
├── bicepconfig.json
└── README.md
```

Additional areas are added only once they contain real, deployable content:

| Area | Purpose |
|---|---|
| `src/observability/` | Deployable compositions for workbooks, alerts, dashboards, monitoring |
| `src/automation/` | Declarative operational automation (approved Logic Apps) |
| `modules/` | Genuinely reusable, environment-neutral Bicep modules |
| `operations/` | Imperative operational functions (e.g. VM start/stop/restart) |
| `config/nfi/lims/` | LIMS-specific configuration per environment (dev/tst/acc/preprd/prd) |
| `config/nfi/shared/` | Configuration for reusable services targeting other subscriptions/management groups |

This repository was reset from a prior Azure Landing Zone-style tenant-provisioning design (see [`docs/architecture.md`](docs/architecture.md) for why) — those directories will only reappear once there is real operational capability to put in them. No feature backlog (workbooks, alerts, Logic Apps, etc.) has been implemented yet.

## Development / deployment philosophy

```
feature branch → static validation (CI) → review → merge to main → automated validation → what-if where applicable → deployment
```

- Implementation is reusable; **configuration** (parameter files) drives differences between environments and targets.
- A change intended for `prd` is not artificially routed through `dev`/`tst`/`acc`/`preprd` — environment applicability is explicit configuration, not a forced promotion chain.
- There are no default manual Azure DevOps approval gates in this repository's model.
- A deployment pipeline is added alongside the first real operational capability, not speculatively ahead of it.

See [`docs/architecture.md`](docs/architecture.md) for more detail.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli), which installs and manages the [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install#azure-cli) automatically (`az bicep install` / `az bicep upgrade`) — Bicep is a standalone CLI, not an Azure CLI extension
- [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) >= 7.4 (for any operational scripts under `operations/` or `scripts/`, once added)

## Documentation

| Document | Description |
|---|---|
| [`docs/scope.md`](docs/scope.md) | Allowed / explicit-decision / prohibited capability boundaries |
| [`docs/architecture.md`](docs/architecture.md) | Design principles and deployment model |
| [`docs/operations.md`](docs/operations.md) | Operational behavior that actually exists today |

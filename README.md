# Azure Operational Automation & Observability-as-Code

A small, maintainable Bicep foundation for Azure operational automation, observability, reporting, and approved maintenance-as-code — not general infrastructure provisioning.

Selected reusable capabilities (for example availability, cost, or backup workbooks) can target one project's subscriptions or a management-group scope, without duplicating implementation per consumer — differences between environments and targets are driven entirely by configuration.

## What this repository is not

This repository is **not** a general Azure Landing Zone or tenant-provisioning framework. It does not manage a tenant's landing zones, identity, networking, or general workload infrastructure. See [`docs/scope.md`](docs/scope.md) for the exact boundary between what is allowed by default, what requires an explicit architecture decision, and what is prohibited.

Key boundaries:

- **Identity is out of scope.** No deployable functionality for Entra users/groups, app registrations, service principals, directory roles, Microsoft Graph mutations, or RBAC/managed-identity creation.
- **General infrastructure provisioning is out of scope by default.** Networking, virtual machines, storage, databases, Key Vault, application hosting, management groups, subscription vending, and landing-zone construction are not provisioned from this repository unless a specific, separate architecture decision approves it.
- **No Terraform-style state.** This repository relies on normal idempotent Azure Resource Manager / Bicep deployment behavior — no state files, state storage accounts, or deployment-state databases.

## Repository structure

```
├── .azuredevops/pipelines/   # ci.yml (static validation) + per-capability deployment/collector pipelines
├── src/observability/        # Deployable compositions (entrypoints) for workbooks, alerts, dashboards
├── modules/observability/    # Genuinely reusable, environment-neutral Bicep modules
├── scripts/observability/    # Operational scripts invoked by pipelines (e.g. the Cost Management collector)
├── config/example/           # Example parameter files showing the shape each capability expects
├── docs/                     # Purpose, scope, and architecture documentation
├── bicepconfig.json
└── README.md
```

Real, deployable configuration (real subscription/environment mappings, workspace/resource-group IDs, service-connection names, policy allowlists) is supplied by a private configuration overlay and is not part of this repository — see `config/example/observability/` for the shape each capability's parameter file expects.

## Implemented capabilities

- **VM Availability SLA Dashboard** (`src/observability/vm-availability-sla-dashboard-v2/`, `modules/observability/vm-availability-sla-dashboard-v2/`) — per-VM daily availability against an SLA target, split by environment.
- **Cost Management Dashboard** (`src/observability/cost-management-workbook/`, `modules/observability/cost-management-workbook/`) — reads monthly cost snapshots from the `CostManagementSnapshot_CL` Log Analytics table below.
- **Cost Management LAW Ingestion Foundation** (`src/observability/cost-management-data-foundation/`, `modules/observability/cost-management-data-foundation/`) — the `CostManagementSnapshot_CL` table and Data Collection Rule that the collector below writes to and the dashboard above reads from.
- **Cost Management Snapshot Collector** (`scripts/observability/Invoke-CostManagementSnapshotCollector.ps1`, run manually via `.azuredevops/pipelines/collect-cost-management-snapshot.yml`) — queries Azure Cost Management once per run and writes a normalized monthly snapshot; manual-only, no schedule enabled.
- **Backup & Restore Dashboard** (`src/observability/backup-restore-workbook/`, `modules/observability/backup-restore-workbook/`) — reads exclusively from three existing Azure Backup Log Analytics tables (`AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy`); creates/modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity, and calls no ARM/Resource Graph/Recovery Services API.

See [`docs/operations.md`](docs/operations.md) for full operational detail on all five.

There are three kinds of pipeline in `.azuredevops/pipelines/`:

- **`ci.yml`** — triggers automatically on every push to every branch; static Bicep/parameter validation only, no deployment.
- **Per-capability deployment pipelines** (e.g. `deploy-vm-availability-sla-dashboard-v2.yml`, `deploy-cost-management-workbook.yml`, `deploy-cost-management-data-foundation.yml`, `deploy-backup-restore-workbook.yml`) — do not trigger automatically (`trigger: none`, `pr: none`); run manually to `what-if` (default) or `deploy` a specific capability. Their validate/what-if steps largely share `.azuredevops/pipelines/templates/deploy-observability-workbook-steps.yml`.
- **Manual operational/collector pipelines** (e.g. `collect-cost-management-snapshot.yml`) — also `trigger: none`/`pr: none`; wrap a script under `scripts/` rather than performing a Bicep deployment. No `schedules:` block is configured yet — see [`docs/operations.md`](docs/operations.md).

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
- [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) >= 7.4 (used by operational scripts under `scripts/`, e.g. the Cost Management Snapshot Collector)
- A private configuration overlay supplying real subscription/environment mappings, workspace/resource-group IDs, and service-connection names for the target environment (see `config/example/observability/` for the expected shape)

## Documentation

| Document | Description |
|---|---|
| [`docs/scope.md`](docs/scope.md) | Allowed / explicit-decision / prohibited capability boundaries |
| [`docs/architecture.md`](docs/architecture.md) | Design principles and deployment model |
| [`docs/operations.md`](docs/operations.md) | Operational behavior that actually exists today |

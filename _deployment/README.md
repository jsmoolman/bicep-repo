# azure-nfi-iac

Infrastructure as Code repository for the nfi Azure tenant, built on Azure Landing Zones (ALZ) principles using Bicep.

All Azure changes must be deployed, reviewed, tracked, and managed through this repository and its CI/CD pipelines. **No manual Azure Portal changes are allowed.**

## Repository Structure

```
azure-nfi-iac/
├── docs/               # Architecture decisions and standards documentation
├── .azuredevops/       # Azure DevOps pipeline definitions and reusable templates
├── src/                # Deployment entry points (platform, landing zones, workloads)
├── modules/            # Reusable Bicep modules (org, platform, workload, policy)
├── lib/                # ALZ library artifacts (policy definitions, archetypes, etc.)
├── config/             # Customer-specific parameter files per environment
├── scripts/            # PowerShell helper scripts (supporting tasks only)
└── tests/              # PSRule, Bicep test harnesses, and policy tests
```

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) >= 2.60
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) >= 0.29
- [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) >= 7.4
- [PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/) >= 1.38

## Getting Started

1. Clone this repository.
2. Authenticate with Azure: `az login --tenant <tenant-id>`
3. Review and update parameter files under `config/customer-a/`.
4. Run a what-if deployment: `./scripts/Invoke-BicepWhatIf.ps1 -TemplateFile src/platform/core/main.bicep -ParameterFile config/customer-a/platform/core.bicepparam -DeploymentScope managementGroup`
5. Submit a PR — the CI pipeline will run validate, lint, PSRule, and what-if automatically.

## Deployment Order

Deployments follow a strict layered order. See [`docs/architecture/deployment-flow.md`](docs/architecture/deployment-flow.md) for the full dependency graph and pipeline flow.

| Step | Layer | Pipeline |
|---|---|---|
| 0 | **Bootstrap** _(manual, one-time)_ | — |
| 1 | **Platform Core** — management groups, policies, RBAC | `deploy-platform-core.yml` |
| 2 | **Platform Subscriptions** — management, connectivity, identity | `deploy-platform-core.yml` |
| 3 | **Platform Shared Services** — Log Analytics, hub networking, Defender | `deploy-platform-management.yml`, `deploy-platform-connectivity.yml` |
| 4 | **Subscription Vending** — workload subscriptions, budgets, baseline RBAC | `deploy-subscription-vending.yml` |
| 5 | **Landing Zone Baseline** — resource groups, tags, diagnostics, monitoring | `deploy-landing-zone-baseline.yml` |
| 6 | **Workload Deployment** — application resources, backup, alerting | `deploy-workload.yml` |

## Identity and Access Model

Two identities separate planning from applying:

| Identity | Permissions | Used by |
|---|---|---|
| **Plan identity** | Reader + What-if | PR pipelines |
| **Apply identity** | Contributor (scoped) | Deploy pipelines, post-approval only |

The apply identity requires an Azure DevOps environment approval before any pipeline can use it for protected environments (`acc`, `preprd`, `prd`).

## Bicep Design Rules

1. Bicep files must not be duplicated per environment — reuse the same composition with different parameter files.
2. Environment-specific values belong in `config/` parameter files, not in `src/` or `modules/`.
3. Reusable modules must not contain hardcoded environment names or application names.
4. Naming and tagging must be centralised and consistently applied (see [`docs/architecture/naming-standard.md`](docs/architecture/naming-standard.md)).
5. Policy and RBAC must be managed as code.
6. Workload deployments must not directly modify tenant-wide platform resources.
7. Platform deployments must not contain workload-specific implementation details.
8. Scripts support deployments but do not replace Bicep where Bicep is suitable.
9. What-if output must be reviewed before applying to protected environments.
10. Portal changes are not allowed except for approved break-glass scenarios.

## Documentation

| Document | Description |
|---|---|
| [`docs/architecture/management-group-hierarchy.md`](docs/architecture/management-group-hierarchy.md) | Management group structure and policy inheritance |
| [`docs/architecture/subscription-strategy.md`](docs/architecture/subscription-strategy.md) | Subscription catalogue and placement strategy |
| [`docs/architecture/naming-standard.md`](docs/architecture/naming-standard.md) | Resource naming convention and examples |
| [`docs/architecture/tagging-standard.md`](docs/architecture/tagging-standard.md) | Mandatory and optional tags |
| [`docs/architecture/policy-strategy.md`](docs/architecture/policy-strategy.md) | Policy assignment scopes and ALZ alignment |
| [`docs/architecture/deployment-flow.md`](docs/architecture/deployment-flow.md) | Layered deployment model, pipeline flow, identity model |
| [`docs/decisions/adr-0001-modern-azure-tenant-iac-repository-structure.md`](docs/decisions/adr-0001-modern-azure-tenant-iac-repository-structure.md) | Architecture decision record for this repository structure |

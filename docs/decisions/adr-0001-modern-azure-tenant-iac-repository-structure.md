# ADR-0001: Modern Azure Tenant Infrastructure-as-Code Repository Structure

## Status

Proposed

## Date

2026-06-21

## Owner

Cloud / Platform Engineering Team

---

## Context

We have been tasked with designing a new Infrastructure-as-Code repository for managing a customer Azure tenant. The repository must support the deployment and ongoing management of Azure resources across the full tenant, including:

- Management groups
- Subscriptions
- Landing zones
- Platform services
- Workload/application resources
- RBAC
- Azure Policy
- Monitoring and alerting
- Budgets
- Backup and recovery configuration
- Automation scripts and pipelines

The customer does not allow Azure Portal-based changes in their landing zones. All Azure changes must therefore be deployed, reviewed, tracked, and managed through Infrastructure-as-Code and CI/CD pipelines.

### Problems with the Existing Structure

The existing repository structure was designed around a single application landing zone with separate subscriptions for:

- `mgmt`
- `dev`
- `tst`
- `acc`
- `preprd`
- `prd`

Although this structure worked for the initial application, it has several limitations:

- It is application-specific.
- It contains duplicated Bicep files and parameter files.
- It does not scale well to multiple landing zones.
- It mixes platform concerns with workload concerns.
- It does not clearly separate tenant-wide governance from subscription-level or workload-level deployments.
- It makes it difficult to standardise management groups, policies, RBAC, monitoring, budgets, and shared platform services across the customer tenant.

A new repository design is required that can support both the current lims-style subscription model and future landing zones for other applications or business domains.

---

## Decision

We will create a modern Azure Infrastructure-as-Code repository structured around **Azure deployment scope, lifecycle, and ownership boundaries**, rather than around a single application or environment.

### Principles

- Tenant/platform concerns are separated from workload concerns.
- Reusable Bicep modules are kept environment-neutral.
- Environment and landing zone differences are driven by configuration and parameter files.
- All deployments are executed through Azure DevOps pipelines.
- No manual Azure Portal changes are allowed.
- Policy, RBAC, budgets, diagnostics, and monitoring are managed as code.
- The structure must support multiple landing zones and multiple workloads.
- The structure must support current `mgmt`/`dev`/`tst`/`acc`/`preprd`/`prd` subscription patterns.
- The repository should align with Azure Landing Zone, Azure Verified Modules, Azure Citadel, and Terraform-style separation-of-concern practices.

### Repository Top-Level Areas

```
azure-tenant-iac/
│
├── docs/
├── .azuredevops/
├── src/
├── modules/
├── lib/
├── config/
├── scripts/
└── tests/
```

---

## Scope Boundaries

### `src/`

The `src` folder contains **deployable Bicep compositions**.

These files represent deployment entry points and orchestration files. They should not be treated as small reusable modules. They are responsible for combining reusable modules into a meaningful deployment unit.

Examples:
- `src/platform/core/main.bicep`
- `src/landing-zones/baseline/main.bicep`
- `src/workloads/lims/main.bicep`

### `modules/`

The `modules` folder contains **reusable Bicep modules**.

Modules must be:
- Environment-neutral
- Subscription-neutral where possible
- Reusable across landing zones
- Small enough to test and maintain
- Free from hardcoded application names such as `lims`, unless they are placed under `modules/workload/lims-specific`, which should be avoided unless absolutely required

Examples:
- `modules/platform/log-analytics/`
- `modules/org/resource-groups/`
- `modules/org/role-assignments/`
- `modules/workload/vm-baseline/`

### `config/`

The `config` folder contains **customer-specific and environment-specific configuration**.

This is where differences between `dev`, `tst`, `acc`, `preprd`, and `prd` are defined.

The same Bicep composition should be reused across environments, with differences supplied through:
- `.bicepparam` files
- `.json` files
- `.yaml` files, where appropriate

### `lib/alz/`

The `lib/alz` folder contains **Azure Landing Zone library content** and customer-specific overrides.

This includes:
- Management group architecture definitions
- Archetype definitions
- Policy definitions
- Policy set definitions
- Policy assignments
- Custom role definitions

This keeps governance artifacts separate from workload deployment code.

### `.azuredevops/`

The `.azuredevops` folder contains all **Azure DevOps pipeline definitions and reusable pipeline templates**.

Pipelines must handle:
- Bicep validation
- Bicep build
- Bicep linting
- What-if
- Security and quality checks
- Approval gates
- Deployment
- Deployment evidence and logs

### `scripts/`

The `scripts` folder contains **supporting scripts only**.

Scripts must not become the main deployment mechanism where Bicep can be used instead. They are allowed for supporting tasks such as:
- What-if wrappers
- Naming validation
- Changed file detection
- Bootstrap helper scripts
- Operational support tasks

### `tests/`

The `tests` folder contains **validation and quality controls**.

This should include:
- PSRule for Azure rules
- Bicep test harnesses
- Policy validation notes
- Naming/tagging tests where possible

---

## Deployment Model

Deployments follow a layered order to ensure dependencies are satisfied.

### 0. Bootstrap
- Deployment identities
- Federated credentials / service connections
- Initial RBAC
- Pipeline permissions

### 1. Platform Core
- Management group hierarchy
- Custom role definitions
- Policy definitions
- Policy initiatives
- Policy assignments

### 2. Platform Subscriptions
- Management subscription
- Connectivity subscription
- Identity/security subscription if applicable

### 3. Platform Shared Services
- Log Analytics
- Automation Account
- Defender / Sentinel if required
- Data Collection Rules
- Baseline alerts
- Hub networking / vWAN / firewall integration

### 4. Subscription Vending
- Create or configure workload subscriptions
- Place subscriptions in correct management groups
- Apply budgets
- Apply baseline RBAC
- Optional empty network baseline

### 5. Landing Zone Baseline
- Per-subscription resource groups
- Tags
- Diagnostic settings
- Monitoring
- Backup baseline
- Activity log alerts
- Standard RBAC

### 6. Workload Deployment
- Application resources
- Workload-specific monitoring
- VM extensions
- Backup policies
- Application-specific infrastructure

---

## Example Landing Zone Configuration

The current lims pattern can be represented as a landing zone with multiple subscriptions.

```yaml
landingZone: lims
businessOwner: nfi
managementGroup: landingzones/local
region: westeurope

subscriptions:
  - name: lims-mgmt
    environment: mgmt
    type: management
    workload: lims

  - name: lims-dev
    environment: dev
    type: application
    workload: lims

  - name: lims-tst
    environment: tst
    type: application
    workload: lims

  - name: lims-acc
    environment: acc
    type: application
    workload: lims

  - name: lims-preprd
    environment: preprd
    type: application
    workload: lims

  - name: lims-prd
    environment: prd
    type: application
    workload: lims
```

This allows the repository to support the existing subscription pattern while also allowing future landing zones to be added without changing the core structure.

---

## Pipeline Requirements

All deployments must be pipeline-driven.

**Pull requests must run:**
- `bicep restore`
- `bicep build`
- `bicep lint`
- PSRule for Azure
- what-if
- publish what-if output

**Merge to the protected branch must trigger deployment pipelines with approval gates where required.**

### Recommended Pipeline Flow

```
Pull Request
  -> Validate
  -> Lint
  -> PSRule
  -> What-if using plan/read identity

Merge to main
  -> What-if again
  -> Manual approval for protected environments
  -> Deploy using apply identity
```

For production or high-risk scopes, deployment must require manual approval before apply.

---

## Identity and Access Model

The repository supports a separation between planning and applying changes.

### Plan Identity
- Read permissions
- What-if permissions
- No broad write permissions

### Apply Identity
- Write permissions only for required deployment scope
- Protected by Azure DevOps environment approvals
- Used only after review and approval

### Scope Principle

Privileged access should be scoped as narrowly as possible:

| Scope | When required |
|---|---|
| Tenant scope | Initial bootstrap only |
| Management group scope | Policy and hierarchy deployments |
| Subscription scope | Subscription baseline |
| Resource group scope | Workload resources (preferred) |

---

## Bicep Design Rules

The following design rules are accepted:

1. Bicep files must not be duplicated per environment unless the deployment shape is genuinely different.
2. Environment-specific values must be stored in parameter/config files.
3. Reusable modules must not contain hardcoded environment names.
4. Naming and tagging must be centralised and consistently applied.
5. Policy and RBAC must be managed as code.
6. Workload deployments must not directly modify tenant-wide platform resources.
7. Platform deployments must not contain workload-specific implementation details.
8. Scripts must support deployments but must not replace Bicep where Bicep is suitable.
9. What-if output must be reviewed before applying changes to protected environments.
10. Portal changes are not allowed except for approved break-glass scenarios.

---

## Consequences

**Positive:**
- Clear blast radius isolation: changes to a workload cannot accidentally affect platform resources.
- Config/code separation allows the same Bicep to be deployed for multiple customers or environments without duplication.
- Aligns with ALZ best practices, reducing custom policy maintenance burden.
- Reusable pipeline templates in `.azuredevops/templates/` apply consistently across all deployment units.
- Supports both the existing lims subscription pattern and future landing zones without structural changes.
- The identity separation (plan vs. apply) reduces the risk of unreviewed deployments reaching production.

**Negative:**
- Slightly more complex initial setup compared to a flat structure.
- Teams must understand which layer owns which resources and must not cross scope boundaries.
- Bootstrap step (step 0) requires elevated permissions and careful execution outside the normal pipeline flow.

---

## References

- [Azure Landing Zones documentation](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/)
- [ALZ Bicep repository](https://github.com/Azure/ALZ-Bicep)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [Azure Citadel — Bicep](https://www.azurecitadel.com/automation/bicep/)
- [PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/)

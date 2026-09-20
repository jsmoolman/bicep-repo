# Repository Scope

This repository is a foundation for **Azure operational automation, observability, reporting, and approved maintenance-as-code**. It is not a general Azure Landing Zone or tenant-provisioning framework.

This document defines the three scope categories that apply to everything deployed from this repository.

## Allowed by default

### Observability

- Azure Monitor workbooks
- Azure dashboards
- Availability reporting
- Cost/costing workbooks
- Metric alerts
- Log/scheduled-query alerts
- Activity/service-health style alerts where appropriate
- Alert processing rules
- Saved operational queries
- Monitoring configuration
- Diagnostic settings where justified
- Data collection configuration where justified

### Security monitoring

Where permissions allow and without any identity change:

- Sentinel workbooks
- Sentinel analytics/detection content
- Sentinel operational configuration
- Defender-related monitoring/alerting configuration where specifically required

Subscription-wide Defender configuration is **not** automatically allowed — it requires an explicit decision (see below).

### Automation and maintenance

- Logic Apps used primarily for maintenance, observability, reporting, backup orchestration, operational notifications, or operational remediation
- VM lifecycle operations (start, stop, deallocate, restart) where explicitly implemented for operational purposes
- Health checks, reporting, and approved maintenance tasks

Logic Apps are an approved resource type in this repository when their purpose aligns with this operational scope, and provided they introduce no prohibited identity changes.

### Cross-project reusable services

Reusable observability/costing capabilities may target another subscription, multiple subscriptions, or a management-group scope, without duplicating implementation per target. Targeting is controlled through configuration, not through duplicated Bicep.

## Explicit architecture decision required

The following are not treated as normal repository authority. Each requires a separate, specific decision before implementation:

- Networking changes (including new IP-range assignment/configuration)
- Policy assignments
- RBAC
- Subscription configuration
- Resource locks
- Infrastructure creation (virtual networks, subnets, firewalls, route tables, private endpoints, virtual machines, VM scale sets, storage infrastructure, SQL/database infrastructure, Key Vault infrastructure, application hosting infrastructure, management groups, subscription vending, resource-group topology, general landing-zone/platform infrastructure)
- Security posture changes outside operational monitoring
- Anything destructive beyond a specifically designed and approved maintenance operation

## Prohibited

No deployable functionality for:

- Entra ID users or groups
- Application registrations or enterprise applications
- Service principals
- Directory roles
- Microsoft Graph mutations
- Identity lifecycle management
- RBAC creation or modification by default
- Creation or modification of managed identities

The deployment identity used by this repository is intentionally granted no Entra ID permissions. Lack of identity permission is never treated as a defect to work around, and permissions are not broadened to compensate. Existing Azure resources and identities may be referenced read-only where necessary, but this repository does not create or modify identity.

This repository also does not introduce Terraform-style state (state files, state storage accounts, deployment-state databases, state locking, or custom deployment inventory databases), and does not use Azure Deployment Stacks purely to introduce resource-ownership/state tracking.

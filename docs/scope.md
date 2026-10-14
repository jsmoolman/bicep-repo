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

Once a specific decision of this kind is made, it is recorded as a named, narrowly scoped exception below — it does not become general repository authority, and it does not authorize anything beyond what the exception explicitly states.

## Explicitly approved workload-infrastructure exceptions

This repository's default authority remains observability, reporting, and approved maintenance-as-code only (see above). The following exceptions are each a separate, specific architecture decision for one named workload, not a general grant of infrastructure authority. Each exception lists exactly what it covers; anything not listed stays outside repository authority.

### LIMS WS2025 Phase 1 — compute foundation

Approved: a parallel/replacement compute foundation for the LIMS DEV Windows Server 2025 environment.

This exception covers, for this workload only:

- The LIMS replacement APP and SQL virtual machines (Windows Server 2025 Datacenter, non-Azure Edition).
- NICs directly coupled to those VMs.
- Managed OS, application, and SQL data/log disks directly coupled to those VMs.
- VM extensions required by the approved workload design (e.g. the Microsoft Entra sign-in extension — see the managed-identity and RBAC exceptions below).
- Read-only references to existing VNet/subnet, Disk Encryption Set, Key Vault (via the DES), monitoring, and other shared platform resources needed to attach the above.

It does **not** authorize creation or modification of: VNets, subnets, route tables, shared NSGs/firewalls, private endpoints, Key Vaults, Disk Encryption Sets, Log Analytics workspaces, Data Collection Rules, Recovery Services Vaults, or any other general platform/landing-zone infrastructure. It does not authorize SQL Server installation/configuration, application content migration, or any other capability listed under "Explicitly out of scope" in the LIMS compute-foundation entry in `docs/operations.md`. It does not extend to any other workload's compute/VM infrastructure.

### Managed identity exception (system-assigned only)

For a VM explicitly covered by an approved workload-infrastructure exception (such as the one above), enabling a **system-assigned** managed identity is allowed where it is an intrinsic property of that VM and required by Azure-native functionality the exception calls for (for the LIMS WS2025 Phase 1 VMs, this is Microsoft Entra VM sign-in).

This does **not** authorize: user-assigned managed identity creation, standalone managed identity resources, service principals, application registrations, Entra users/groups, Microsoft Graph mutations, directory-role management, or any broader identity lifecycle management. The "Prohibited" section below otherwise still applies in full.

### RBAC exception (VM login roles only)

RBAC remains prohibited by default (see "Prohibited" below). For a VM explicitly covered by an approved workload-infrastructure exception, narrowly scoped Azure RBAC assignments may be created **only** where required to preserve that workload's existing VM access model, and only when all of the following hold:

- The principal is an existing Entra security group (never a user, service principal, or newly created group).
- The role is limited to **Virtual Machine Administrator Login** and/or **Virtual Machine User Login**.
- The assignment preserves the existing access mapping for that workload (e.g. which group gets administrator vs. user login on which machine) — it is not a new access decision.
- The scope is the individual VM/resource, not the subscription or resource group, unless the existing approved design for that workload clearly uses a different least-privilege scope.

This does **not** authorize creating or modifying Entra groups, broadening group membership, inventing/guessing principal IDs, using any other role, or assigning VM-login roles at subscription scope for convenience. Where the authoritative principal IDs or exact access mapping for a workload are not yet available in source, the role assignments are parameterized/deferred rather than guessed, and the required live inputs are reported.

### Networking exception (NIC attachment only)

For a VM explicitly covered by an approved workload-infrastructure exception, creating the NIC(s) directly coupled to that VM is allowed. The NIC(s) must attach only to an existing subnet already approved for that workload — no VNet, subnet, address-space, or network-security redesign is authorized by this exception.

## Prohibited

No deployable functionality for:

- Entra ID users or groups
- Application registrations or enterprise applications
- Service principals
- Directory roles
- Microsoft Graph mutations
- Identity lifecycle management
- RBAC creation or modification by default (narrow exception: see "RBAC exception (VM login roles only)" above)
- Creation or modification of managed identities (narrow exception: see "Managed identity exception (system-assigned only)" above)

The deployment identity used by this repository is intentionally granted no Entra ID permissions. Lack of identity permission is never treated as a defect to work around, and permissions are not broadened to compensate. Existing Azure resources and identities may be referenced read-only where necessary, but this repository does not create or modify identity. The two narrow exceptions above are the only departures from this section, and only for the specific workload(s) they each name.

This repository also does not introduce Terraform-style state (state files, state storage accounts, deployment-state databases, state locking, or custom deployment inventory databases), and does not use Azure Deployment Stacks purely to introduce resource-ownership/state tracking.

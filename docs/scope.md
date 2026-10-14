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

### RBAC and Entra ID mutation are distinct

RBAC appears in the list above because any RBAC assignment still requires a separate, specific, approved decision before implementation — it is never default repository authority. However, RBAC assignment of an already-existing Entra principal is **not** itself a form of Entra ID mutation, and must not be documented or guarded as one.

Prohibited as Entra ID mutation (see "Prohibited" below — this is unaffected and unchanged):

- Creating or modifying Entra users
- Creating or modifying Entra groups
- Changing Entra group membership
- Application registrations or enterprise applications
- Service principals
- Directory roles
- Microsoft Graph mutations
- General Entra identity lifecycle management

Not prohibited as Entra ID mutation:

- Assigning an already-existing Entra object/principal to an Azure RBAC role.

This is still subject to the "Explicit architecture decision required" rule above: it must be deliberate, narrowly scoped to a specific, approved workload decision (see the exceptions below), and never a general or standing grant. It simply is not categorized, guarded, or described as identity mutation.

## Explicitly approved workload-infrastructure exceptions

This repository's default authority remains observability, reporting, and approved maintenance-as-code only (see above). The following exceptions are each a separate, specific architecture decision for one named workload, not a general grant of infrastructure authority. Each exception lists exactly what it covers; anything not listed stays outside repository authority.

### LIMS WS2025 Phase 1 — compute foundation

Approved: a parallel/replacement compute foundation for the LIMS DEV Windows Server 2025 environment.

This exception covers, for this workload only:

- The LIMS replacement APP and SQL virtual machines (Windows Server 2025 Datacenter, non-Azure Edition).
- NICs directly coupled to those VMs.
- Managed OS, application, and SQL data/log disks directly coupled to those VMs.
- VM extensions required by the approved workload design (e.g. the Microsoft Entra sign-in extension — see the managed-identity exception and RBAC decision below).
- Read-only references to existing VNet/subnet, Disk Encryption Set, Key Vault (via the DES), monitoring, and other shared platform resources needed to attach the above.

It does **not** authorize creation or modification of: VNets, subnets, route tables, shared NSGs/firewalls, private endpoints, Key Vaults, Disk Encryption Sets, Log Analytics workspaces, Data Collection Rules, Recovery Services Vaults, or any other general platform/landing-zone infrastructure. It does not authorize SQL Server installation/configuration, application content migration, or any other capability listed under "Explicitly out of scope" in the LIMS compute-foundation entry in `docs/operations.md`. It does not extend to any other workload's compute/VM infrastructure.

### Managed identity exception (system-assigned only)

For a VM explicitly covered by an approved workload-infrastructure exception (such as the one above), enabling a **system-assigned** managed identity is allowed where it is an intrinsic property of that VM and required by Azure-native functionality the exception calls for (for the LIMS WS2025 Phase 1 VMs, this is Microsoft Entra VM sign-in).

This does **not** authorize: user-assigned managed identity creation, standalone managed identity resources, service principals, application registrations, Entra users/groups, Microsoft Graph mutations, directory-role management, or any broader identity lifecycle management. The "Prohibited" section below otherwise still applies in full.

### RBAC decision (VM login roles only) — LIMS WS2025

RBAC always requires an explicit, specific decision before implementation (see "Explicit architecture decision required" and "RBAC and Entra ID mutation are distinct" above) — it is not categorically prohibited, and assigning an existing Entra principal to an Azure role is not an Entra mutation. For the LIMS WS2025 VMs explicitly covered by the compute-foundation exception above, that decision is: narrowly scoped Azure RBAC assignments may be created **only** where required to preserve this workload's approved VM access model, and only when all of the following hold:

- The principal is an existing Entra security group (never a user, service principal, or newly created group).
- The role is limited to **Virtual Machine Administrator Login** and/or **Virtual Machine User Login**.
- The assignment preserves the approved access mapping for this workload (e.g. which group gets administrator vs. user login on which machine) — it is not a new access decision made by this repository.
- The scope is the individual VM resource, not the subscription or resource group.

**Approved DEV mapping** (object IDs supplied via the real parameter file, never hardcoded in Bicep source):

| VM | Virtual Machine Administrator Login | Virtual Machine User Login |
|---|---|---|
| `vm-lims-dev-v2-westeu-001` (APP) | `AZ-TC-LIMS-Infra`, `AZ-TC-LIMS-Func`, `AZ-TC-LIMS-App` | none currently required |
| `vm-lims-dev-v2-westeu-002` (SQL) | `AZ-TC-LIMS-Infra`, `AZ-TC-LIMS-App` | none currently required |

`AZ-TC-LIMS-Data` currently has no DEV VM-login assignment on either VM. This table records group *names* for traceability only; the Bicep module and parameter files reference only the groups' Entra object IDs, never their display names (see `docs/operations.md` for exactly which object IDs are still required).

This does **not** authorize creating or modifying Entra groups, broadening group membership, inventing/guessing principal IDs, using any other role, or assigning VM-login roles at subscription or resource-group scope. Where an authoritative object ID for one of the groups above is not yet available, that group's entry in the real parameter file's role array is left out rather than guessed.

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
- Creation or modification of managed identities (narrow exception: see "Managed identity exception (system-assigned only)" above)

RBAC assignment is deliberately not listed here: assigning an already-existing Entra principal to an Azure role is not an Entra ID mutation (see "RBAC and Entra ID mutation are distinct" above). RBAC still requires its own explicit, specific, approved decision per the "Explicit architecture decision required" section — it is simply categorized correctly rather than guarded as identity mutation.

The deployment identity used by this repository is intentionally granted no Entra ID permissions. Lack of identity permission is never treated as a defect to work around, and permissions are not broadened to compensate. Existing Azure resources and identities may be referenced read-only where necessary, but this repository does not create or modify identity — that remains unconditional. The managed-identity exception above is the only departure from this section, and only for the specific workload(s) it names.

This repository also does not introduce Terraform-style state (state files, state storage accounts, deployment-state databases, state locking, or custom deployment inventory databases), and does not use Azure Deployment Stacks purely to introduce resource-ownership/state tracking.

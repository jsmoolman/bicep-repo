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

### LIMS WS2025 DEV v2 — patch onboarding (Policy pilot)

"Policy assignments" always requires an explicit, specific decision before implementation (see "Explicit architecture decision required" above) — it is not categorically prohibited. For the two LIMS WS2025 DEV v2 virtual machines explicitly covered by the compute-foundation exception above, that decision is: a narrow pilot that uses two Microsoft built-in Azure Policy definitions, never copied into custom definitions, to maintain Azure Update Manager patch settings on those VMs, reusing their existing non-prod maintenance schedule membership.

This exception covers, for this workload only, exactly:

- Four `Microsoft.Authorization/policyAssignments` resources, each individually scoped to one of the two named VMs (`vm-lims-dev-v2-westeu-001`, `vm-lims-dev-v2-westeu-002`) — never at subscription or resource-group scope, and never applied via a tag filter at a broader scope.
- Assignment of exactly these two built-in definitions, unmodified:
  - "Configure periodic checking for missing system updates on azure virtual machines" (`59efceea-0c96-497e-a4a1-4eb2290dac15`) — Modify effect.
  - "Set prerequisite for Scheduling recurring updates on Azure virtual machines." (`9905ca54-1471-49c6-8291-7582c04cd4d4`) — DeployIfNotExists effect.
- Reuse (not creation) of one existing, already-approved user-assigned managed identity for policy remediation — see "Managed identity reuse (user-assigned, existing identity only)" below.

It does **not** authorize: the broader "Schedule recurring updates using Azure Update Manager" built-in policy; any custom policy definition; any policy assignment at subscription, management-group, or resource-group scope; any new maintenance configuration, dynamic scope, or direct/static maintenance assignment (schedule membership continues to be supplied entirely by the existing `mc-lims-nonprod-westeu` dynamic scope together with the `dataClassification` tag set by the compute foundation); any automatic remediation task; any change to the v1 LIMS DEV VMs, `mc-lims-prod-westeu`, or any other existing maintenance configuration; or expansion to any other VM, workload, or environment. Expansion beyond these two VMs requires its own separate, specific decision recorded as a new exception.

### Managed identity reuse (user-assigned, existing identity only) — LIMS WS2025 DEV v2 patch onboarding

The "Managed identity exception (system-assigned only)" above does not authorize user-assigned managed identity use. For the narrow patch-onboarding pilot above only, the four policy assignments may reference (attach to) one existing, already-approved user-assigned managed identity for Policy Modify/DeployIfNotExists remediation, supplied as an explicit, non-secret resource-ID parameter (`userAssignedIdentityResourceId`) — never guessed, reconstructed, or inferred from any source (including screenshots).

This does **not** authorize: creating a user-assigned managed identity resource, creating any new RBAC role assignment for that identity (both built-in definitions list the built-in Contributor role for remediation; whether the identity already holds that effective permission at the target scope, and whether the pipeline's service connection has permission to attach an existing identity to a policy assignment, must be verified outside this repository before any `deploy` action — see [`docs/operations.md`](operations.md)), or any other identity/RBAC change beyond referencing the existing identity's resource ID on these four assignments.

### LIMS WS2025 DEV v2 — time-zone enforcement (Machine Configuration extension)

"Infrastructure creation" always requires an explicit, specific decision before implementation (see "Explicit architecture decision required" above) — it is not categorically prohibited. For the two LIMS WS2025 DEV v2 virtual machines explicitly covered by the compute-foundation exception above, that decision is: install the Azure Machine Configuration (Guest Configuration) VM extension so Guest-Configuration-based Azure Policy definitions — including, but not limited to, the dedicated v2 time-zone policy assignments below — can evaluate and act against those two VMs. Installing this extension is not inert: it is a prerequisite that enables **any** applicable Guest Configuration policy (any policy using the `Microsoft.GuestConfiguration/guestConfigurationAssignments` DeployIfNotExists mechanism, in this subscription, that is scoped to reach these VMs) to evaluate and potentially remediate them, not only the two assignments created below — see `docs/operations.md`.

This exception covers, for this workload only, exactly:

- Two `Microsoft.Compute/virtualMachines/extensions` resources, each a child of one of the two named VMs (`vm-lims-dev-v2-westeu-001`, `vm-lims-dev-v2-westeu-002`), publisher `Microsoft.GuestConfiguration`, type `ConfigurationforWindows`, instance name `AzurePolicyforWindows` (this exact instance name is required by Microsoft's own baseline/Guest-Configuration policies, not an arbitrary choice here), with `autoUpgradeMinorVersion` and `enableAutomaticUpgrade` set per Microsoft's documented settings.

It does **not** authorize: creating any `Microsoft.GuestConfiguration/guestConfigurationAssignments` resource directly (such a resource is created only by an applicable policy's own remediation, outside this repository's authority); creating any custom policy definition; introducing any broader Guest-Configuration prerequisite initiative (e.g. the built-in "Deploy prerequisites to enable Guest Configuration policies on virtual machines" initiative); installing this or any other Guest Configuration extension on the v1 LIMS DEV VMs or any other workload; or any new identity (the extension relies on the VM's existing system-assigned identity — see "Managed identity exception (system-assigned only)" above, which already covers it). Expansion beyond these two VMs requires its own separate, specific decision recorded as a new exception.

### LIMS WS2025 DEV v2 — dedicated time-zone policy assignments and RBAC (Policy pilot)

"Policy assignments" and "RBAC" each always require an explicit, specific decision before implementation (see "Explicit architecture decision required" above) — neither is categorically prohibited, and assigning an already-existing Entra principal (here, a policy assignment's own newly created system-assigned identity) to an Azure role is not an Entra mutation. For the two LIMS WS2025 DEV v2 virtual machines explicitly covered by the compute-foundation exception above, that decision is: assign the Microsoft built-in Azure Policy definition "Configure time zone on Windows machines." (`6141c932-9384-44c6-a395-59e4c057d7c9`, never copied into a custom definition) individually to each of the two named VMs — resource scope only — each with its own dedicated, newly created system-assigned identity, and grant each identity the one built-in role its policy definition requires for remediation, at the narrowest scope that role's mechanics permit.

**Why this capability is a dedicated, VM-scoped composition rather than a grant of permission to the existing broader subscription-scoped `configure-windows-timezone-dev` assignment's identity (`2dea906c-2e98-4b2c-ab4b-2d002de614e7`):** supplied customer what-if evidence confirms both the v1 and v2 LIMS DEV VMs reside in the same resource group, `rg-compute-lims-dev-westeu` (this is now established fact, not an open question — see the corrected record in `docs/operations.md`). Granting that broader assignment's identity a resource-group-scope role, while manually selecting only the two v2 VMs during remediation, does **not** isolate enforcement to v2: that broader assignment's own `policyRule` already evaluates every eligible Windows VM in its subscription-wide scope, so a future applicable update to a v1 resource could still cause it to deploy a guest configuration assignment against v1, independent of any role grant decision made here. Two dedicated, VM-scoped assignments avoid this structurally: each one's own `policyRule` only ever evaluates the single VM it is scoped to, regardless of any future v1 change.

This decision covers, for this workload only, exactly:

- Two `Microsoft.Authorization/policyAssignments` resources, each individually scoped to one of the two named VMs (`vm-lims-dev-v2-westeu-001`, `vm-lims-dev-v2-westeu-002`) — never at subscription or resource-group scope — assigning built-in definition `6141c932-9384-44c6-a395-59e4c057d7c9` unmodified, with `TimeZone="(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna"` (that definition's own display-string parameter value, verified present in its `allowedValues`), `IncludeArcMachines="false"` (verified as that definition's own **string**-typed parameter, not a Bicep boolean), and `enforcementMode="Default"`.
- Each assignment declares its own dedicated **system-assigned** identity (never the existing broader assignment's identity, and never a standalone user-assigned identity).
- Two `Microsoft.Authorization/roleAssignments` resources granting **Guest Configuration Resource Contributor** (`088ab73d-1256-47ae-bea9-9de8e7131f31`) — resolved from each policy assignment's own `identity.principalId` output, never hardcoded or guessed — scoped to exactly the resource group hosting the two named v2 VMs (`rg-compute-lims-dev-westeu`), using deterministic role-assignment names and `principalType: 'ServicePrincipal'`.
- Resource-group scope for these role assignments, rather than VM scope, is the architecturally minimum viable grant for this specific policy's DeployIfNotExists mechanics: Microsoft's own "Remediate non-compliant resources" documentation confirms the nested remediation deployment executes at the resource group of the target resource by default, and the Guest Configuration Resource Contributor role's own action list already includes `Microsoft.Resources/deployments/*` alongside the guest-configuration-assignment actions — so no second role is required, only this scope. **This RBAC grant's scope is the resource group, not a VM — it is the *policy assignments* above, not this role grant, that are restricted to the two named VMs; this distinction must not be blurred when describing this capability.** See `docs/operations.md` for the full verification.

This does **not** authorize: creating, modifying, deleting, or excluding resources from the existing subscription-scoped `configure-windows-timezone-dev` policy assignment, its parameters, or its identity — that assignment is left completely unchanged and continues to overlap with the two VM-scoped assignments above until a separate, future consolidation decision after cutover (see `docs/operations.md`); granting any permission to that existing assignment's identity (`2dea906c-2e98-4b2c-ab4b-2d002de614e7`); creating any `Microsoft.GuestConfiguration/guestConfigurationAssignments` resource directly; creating any custom policy or role definition; creating any standalone user-assigned identity; subscription-wide Owner or Contributor, or any role at subscription scope; any role beyond Guest Configuration Resource Contributor; any automatic remediation task; any change to the v1 LIMS DEV VMs or the four existing patch-policy assignments; or expansion to any other VM, workload, or environment. Expansion beyond these two VMs/assignments/role grants requires its own separate, specific decision recorded as a new exception.

### LIMS WS2025 DEV v2 — guest data-disk preparation (opt-in, disabled by default)

Guest-level disk initialization/formatting is not default repository authority — it is a guest OS mutation, not Azure resource infrastructure, and falls outside the normal "Explicit architecture decision required" list above only because that list enumerates Azure Resource Manager-level capabilities, not guest-OS actions; it is treated with at least the same level of deliberateness. For the two LIMS WS2025 DEV v2 virtual machines explicitly covered by the compute-foundation exception above, that decision is: deliver one Microsoft-documented, reviewable PowerShell script via `Microsoft.Compute/virtualMachines/runCommands`, scoped individually to each of the two named VMs, that may initialize, partition, format, and label **only** the specific, named, pre-approved data disk(s) on that VM, strictly behind an explicit opt-in parameter that defaults to disabled, plus an explicit per-VM Validate/Apply execution selector that also defaults to performing nothing.

This exception covers, for this workload only, exactly:

- Two `Microsoft.Compute/virtualMachines/runCommands` resources (API version `2024-11-01`), each a child of exactly one of the two named VMs (`vm-lims-dev-v2-westeu-001`, `vm-lims-dev-v2-westeu-002`) — never a subscription/resource-group-scoped Run Command, never targeting any other VM, and never created unless the module's `enableGuestDiskPreparation` parameter is explicitly set to `true` (default `false`) **and** that VM is selected by `guestDiskPreparationExecutionTarget` (`None` | `ValidateApp` | `ValidateSql` | `ValidateBoth` | `ApplyApp` | `ApplySql`, default `None`). There is deliberately no `ApplyBoth` value — applying to both VMs in a single deployment is structurally impossible, not merely discouraged by convention.
- A fully inline script (`source.script`, no storage account, no public URL, no secret) that runs in one of two modes, `Validate` or `Apply`. `Validate` is fully read-only — every mutating function is unreachable from that code path by construction — and reports the guest's current state and the action it would take. `Apply` always rebuilds and re-runs every check fresh (fixed allowlist, identity, disk mapping, stable disk identity, existing layout, destination-letter occupancy) immediately before mutating; a prior report, including one from an earlier run of this same script, is never trusted as authorization.
- Independent, duplicated verification: the script carries its own fixed, hardcoded allowlist of the exact approved subscription/resource group/VM/computer name and disk descriptors below. Caller-supplied parameters and the Azure Instance Metadata Service (IMDS) are each checked separately against that fixed allowlist — never only against each other — so a caller/IMDS pair that is internally self-consistent but points at the wrong VM, subscription, resource group, or disk still fails closed.
- Exactly these disk targets, identified by managed-disk resource name and Azure LUN (never by disk number, ordinal position, size alone, or "all RAW disks"), after excluding the OS disk by its actual reported `IsBoot`/`IsSystem` role and excluding the Azure temporary/resource disk by positive cross-reference against the Instance Metadata Service's own authoritative `compute.storageProfile.resourceDisk.size` value (never a hardcoded disk number, SCSI port, or controller co-location assumption; a missing/unreadable IMDS value fails the run closed rather than guessing):
  - APP (`vm-lims-dev-v2-westeu-001`): LUN 0, the existing `appDataDiskName` managed disk (128 GiB) — destination `A:`, NTFS, 4 KiB allocation unit, label `LIMS-App`.
  - SQL (`vm-lims-dev-v2-westeu-002`): LUN 0, the existing `sqlDataDiskName` managed disk (1024 GiB) — destination `E:`, NTFS, 64 KiB allocation unit, label `SQL-Data`; LUN 1, the existing `sqlLogDiskName` managed disk (512 GiB) — destination `F:`, NTFS, 64 KiB allocation unit, label `SQL-Logs`.
- On the SQL VM only, a conditional, narrowly defined move of the empty virtual DVD-ROM drive letter from `E:` to `Z:`, performed before SQL DATA's partition is created at `E:` — only performed if `E:` is independently, positively confirmed (via `Win32_CDROMDrive`) to be the single expected `Microsoft Virtual DVD-ROM` device with no media loaded, and `Z:` is confirmed free (across the optical-device inventory, the DVD volume inventory, the ordinary volume inventory, and the partition inventory), and the move's success is independently re-confirmed afterward; any missing, unexpected, or ambiguous device identity, any loaded or unknown media state, or an occupied destination stops the entire VM's run (no mutation of any kind, on either SQL disk) instead. The APP VM's DVD-ROM letter is never touched.

This does **not** authorize: selecting or mutating any disk by size, ordinal number, drive-letter guess, tag, or "all RAW disks" discovery; touching the OS disk, the Azure temporary disk, `C:`, `D:`, any v1 LIMS DEV resource, or any disk/VM not explicitly named above; `Clear-Disk`, `diskpart clean`, partition deletion, storage pools, or any blanket disk-state operation; repairing, reformatting, or auto-resuming an already-initialized disk that does not exactly match the intended layout (the script fails closed and stops for manual review instead); retrying a failed format automatically; weakening the Azure Instance Metadata Service identity/LUN/resource-name/capacity verification described in `docs/operations.md` to make execution succeed — if that verification cannot establish an unambiguous mapping, the correct outcome is a failed run, never a broader match; or expansion to any other VM, workload, or environment. Expansion beyond these two VMs/disks requires its own separate, specific decision recorded as a new exception.

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

// Example parameters for the LIMS WS2025 Phase 1 compute foundation —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription ID, resource group, subnet, and Disk Encryption Set resource
// IDs below are fictional.
//
// This creates only the replacement LIMS APP and SQL virtual machines
// (Windows Server 2025 Datacenter, non-Azure Edition), their directly
// coupled NICs and managed disks, and the Microsoft Entra sign-in
// extension — into an existing resource group. It creates no VNet, subnet,
// NSG, Key Vault, Disk Encryption Set, Log Analytics workspace, DCR, or
// Recovery Services Vault, and installs no SQL Server. Approved under the
// narrow LIMS WS2025 Phase 1 exception recorded in docs/scope.md.
//
// enableGuestDiskPreparation (near the bottom of this file) is a separate,
// disabled-by-default opt-in for initializing/formatting only the approved
// APP/SQL data disks — see the "LIMS WS2025 DEV v2 — guest data-disk
// preparation" exception in docs/scope.md and the matching section in
// docs/operations.md before ever setting it to true.
//
// adminUsername / adminPassword are read from environment variables via
// readEnvironmentVariable() rather than assigned a literal value — the
// pipeline sets LIMS_WS2025_DEV_ADMIN_USERNAME / LIMS_WS2025_DEV_ADMIN_PASSWORD
// from a secret pipeline variable immediately before calling `bicep
// build-params` / `az deployment ... create`, so the real value is never
// written to this file or to Bicep source. The local administrator account
// is a deployment/break-glass account only; normal personnel access is
// through Microsoft Entra sign-in (see the *LoginPrincipalIds parameters
// below).
//
// tags.dataClassification = 'non-production' is what makes both v2 VMs
// members of the existing mc-lims-nonprod-westeu maintenance configuration's
// dynamic scope — see config/example/compute/lims-ws2025-dev-patch-policy.bicepparam
// for the built-in Policy assignments that configure/maintain the matching
// VM-level patch settings this tag depends on.
//
// *ExistingUserAssignedIdentityResourceIds below preserve existing
// user-assigned managed identities already attached to each VM outside this
// Bicep composition (e.g. an identity attached by Azure Policy remediation,
// such as Built-In-Identity-westeurope) across redeployments. This is
// DIFFERENT from the patch-policy composition's userAssignedIdentityResourceId
// (config/example/compute/lims-ws2025-dev-patch-policy.bicepparam), which is
// only referenced by policy assignments for remediation and is never attached
// to a VM. Leaving these arrays empty reproduces the original initial-creation
// identity shape (SystemAssigned only) and does NOT preserve a user-assigned
// identity that was attached outside Bicep after creation — see
// docs/operations.md before redeploying an already-converged VM.
//
// osDiskSizeGiB = 127 preserves the current LIMS v1 OS disk size for both the
// APP and SQL OS disks rather than relying on the Marketplace image default.
//
// The *AdministratorLoginPrincipalIds / *UserLoginPrincipalIds parameters are
// left empty below. Assigning an already-existing Entra security group to the
// built-in VM-login roles is not an Entra ID mutation (see docs/scope.md,
// "RBAC and Entra ID mutation are distinct"), but populating these arrays
// still requires the authoritative existing Entra security group object IDs
// for this workload's approved VM-login mapping — see docs/operations.md for
// exactly what is required before they can be set.
using '../../../src/compute/lims-ws2025-dev-foundation/main.bicep'

param resourceGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param subnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-network-lims-dev-westeu/providers/Microsoft.Network/virtualNetworks/vnet-lims-dev-westeu/subnets/snet-routable'

param diskEncryptionSetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-security-lims-dev-westeu/providers/Microsoft.Compute/diskEncryptionSets/des-lims-dev-westeu'

// The default values below are deliberately non-functional placeholders that
// only satisfy static `bicep build-params` validation (e.g. in CI, where
// these environment variables are never set); the deploy pipeline always
// supplies the real value, which overrides the default.
param adminUsername = readEnvironmentVariable('LIMS_WS2025_DEV_ADMIN_USERNAME', 'not-set-see-pipeline-secret-variable')

param adminPassword = readEnvironmentVariable('LIMS_WS2025_DEV_ADMIN_PASSWORD', 'not-set-see-pipeline-secret-variable')

param vmSize = 'Standard_D4ads_v5'

param osDiskSizeGiB = 127

param appVmName = 'vm-lims-dev-v2-westeu-001'

param appComputerName = 'lims-dev-v2-001'

param appNicName = 'nic-vm-lims-dev-v2-westeu-001'

param appOsDiskName = 'osdisk-vm-lims-dev-v2-westeu-001'

param appDataDiskName = 'appdata-vm-lims-dev-v2-westeu-001'

param appDataDiskSizeGiB = 128

// Must match the baseline tier for appDataDiskSizeGiB per the Premium SSD
// size/tier table (128 GiB -> P10) — update together if the size ever changes.
param appDataDiskTier = 'P10'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param sqlComputerName = 'lims-dev-v2-002'

param sqlNicName = 'nic-vm-lims-dev-v2-westeu-002'

param sqlOsDiskName = 'osdisk-vm-lims-dev-v2-westeu-002'

param sqlDataDiskName = 'sqldata-vm-lims-dev-v2-westeu-002'

param sqlDataDiskSizeGiB = 1024

// Must match the baseline tier for sqlDataDiskSizeGiB (1024 GiB -> P30).
param sqlDataDiskTier = 'P30'

param sqlLogDiskName = 'sqllog-vm-lims-dev-v2-westeu-002'

param sqlLogDiskSizeGiB = 512

// Must match the baseline tier for sqlLogDiskSizeGiB (512 GiB -> P20).
param sqlLogDiskTier = 'P20'

param tags = {
  environment: 'development'
  purpose: 'lims'
  dataClassification: 'non-production'
}

// Example only: preserves a fictional existing Policy-managed identity
// (Built-In-Identity-westeurope) on both VMs across redeployments. Supply the
// authoritative existing resource ID(s) actually attached to each VM — never
// guessed. Leave as [] if no user-assigned identity is attached outside Bicep.
param appExistingUserAssignedIdentityResourceIds = [
  '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-identity-example-westeu/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-westeurope'
]

param sqlExistingUserAssignedIdentityResourceIds = [
  '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-identity-example-westeu/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-westeurope'
]

param appAdministratorLoginPrincipalIds = []

param appUserLoginPrincipalIds = []

param sqlAdministratorLoginPrincipalIds = []

param sqlUserLoginPrincipalIds = []

// Guest data-disk preparation (initialize/partition/format/assign drive
// letter) is disabled by default — enableGuestDiskPreparation = false means
// a normal redeployment of this example never formats anything. Flip to
// true only after confirming the approved targets below (drive letters,
// labels, allocation unit sizes) and after reading the full behavioral
// contract in docs/operations.md. Every mutation target is still
// independently re-verified at execution time via Azure Instance Metadata
// Service identity, LUN, managed-disk resource name, and capacity checks —
// this flag only controls whether the guest Run Command resource exists.
param enableGuestDiskPreparation = false

// Explicitly 'None' (also the default) — neither VM's guest data-disk
// preparation Run Command is deployed, regardless of
// enableGuestDiskPreparation. See docs/operations.md for the full set of
// allowed values and the six-step customer validate -> apply -> reverify
// sequence (there is deliberately no 'ApplyBoth' value).
param guestDiskPreparationExecutionTarget = 'None'

param appDataVolumeDriveLetter = 'A'

param appDataVolumeLabel = 'LIMS-App'

param appDataVolumeAllocationUnitBytes = 4096

param sqlDataVolumeDriveLetter = 'E'

param sqlDataVolumeLabel = 'SQL-Data'

param sqlDataVolumeAllocationUnitBytes = 65536

param sqlLogVolumeDriveLetter = 'F'

param sqlLogVolumeLabel = 'SQL-Logs'

param sqlLogVolumeAllocationUnitBytes = 65536

param guestDiskPreparationTimeoutInSeconds = 1800

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

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param sqlComputerName = 'lims-dev-v2-002'

param sqlNicName = 'nic-vm-lims-dev-v2-westeu-002'

param sqlOsDiskName = 'osdisk-vm-lims-dev-v2-westeu-002'

param sqlDataDiskName = 'sqldata-vm-lims-dev-v2-westeu-002'

param sqlDataDiskSizeGiB = 1024

param sqlLogDiskName = 'sqllog-vm-lims-dev-v2-westeu-002'

param sqlLogDiskSizeGiB = 512

param tags = {
  environment: 'development'
  purpose: 'lims'
  dataClassification: 'non-production'
}

param appAdministratorLoginPrincipalIds = []

param appUserLoginPrincipalIds = []

param sqlAdministratorLoginPrincipalIds = []

param sqlUserLoginPrincipalIds = []

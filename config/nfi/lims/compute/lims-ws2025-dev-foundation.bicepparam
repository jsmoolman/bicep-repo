// Real (non-secret) DEV parameters for the LIMS WS2025 Phase 1 compute
// foundation. Approved under the narrow LIMS WS2025 Phase 1 exception
// recorded in docs/scope.md — see that file before changing the scope of
// what this composition is allowed to create.
//
// *** NOT YET DEPLOYMENT-READY ***
// resourceGroupResourceId, subnetResourceId, and diskEncryptionSetResourceId
// below are REPLACE_WITH_REAL_VALUE placeholders. No authoritative resource
// ID for the existing rg-compute-lims-dev-westeu resource group, the existing
// snet-routable subnet, or the existing DEV Disk Encryption Set was found
// anywhere in this repository (all branches searched). These three values
// MUST be replaced with the real resource IDs before this file can be used
// for `bicep build-params` against live resources or for any deployment.
// Until then this file is suitable for local static validation only.
//
// adminUsername / adminPassword are read from environment variables via
// readEnvironmentVariable() rather than assigned a literal value — the
// pipeline sets LIMS_WS2025_DEV_ADMIN_USERNAME / LIMS_WS2025_DEV_ADMIN_PASSWORD
// from a secret pipeline variable immediately before calling `bicep
// build-params` / `az deployment ... create`, so the real value is never
// written to this file or to Bicep source. The local administrator account
// is a deployment/break-glass account only; normal personnel access is
// through Microsoft Entra sign-in.
//
// osDiskSizeGiB = 127 preserves the current LIMS v1 OS disk size for both the
// APP and SQL OS disks — do not remove; the Marketplace image default is not
// relied upon.
//
// --- Approved DEV VM-login mapping (see docs/scope.md, "RBAC decision (VM
// login roles only) — LIMS WS2025", and docs/operations.md) ---
//   APP VM (vm-lims-dev-v2-westeu-001) Administrator Login: AZ-TC-LIMS-Infra, AZ-TC-LIMS-Func, AZ-TC-LIMS-App
//   SQL VM (vm-lims-dev-v2-westeu-002) Administrator Login: AZ-TC-LIMS-Infra, AZ-TC-LIMS-App
//   No Virtual Machine User Login assignment is currently required for either VM.
//   AZ-TC-LIMS-Data currently has no DEV VM-login assignment on either VM.
//
// Assigning an already-existing Entra security group to the built-in VM-login
// roles below is not an Entra ID mutation (see docs/scope.md) — it is still a
// deliberate, approved, narrowly scoped decision, which is why the mapping
// above is recorded explicitly rather than left to guesswork.
//
// The four arrays below are intentionally left EMPTY: the object IDs for the
// groups named above are not available in this repository and are never
// guessed (including from screenshots). No role assignment is created for an
// empty array. Required live inputs before these can be populated:
//   - Object ID of AZ-TC-LIMS-Infra
//   - Object ID of AZ-TC-LIMS-Func
//   - Object ID of AZ-TC-LIMS-App
// (AZ-TC-LIMS-Data needs no object ID here, since it has no DEV VM-login
// assignment on either VM.)
//
// Once the object IDs above are known, populate as e.g.:
//   param appAdministratorLoginPrincipalIds = [
//     '<AZ-TC-LIMS-Infra object id>'
//     '<AZ-TC-LIMS-Func object id>'
//     '<AZ-TC-LIMS-App object id>'
//   ]
//   param sqlAdministratorLoginPrincipalIds = [
//     '<AZ-TC-LIMS-Infra object id>'
//     '<AZ-TC-LIMS-App object id>'
//   ]
using '../../../../src/compute/lims-ws2025-dev-foundation/main.bicep'

param resourceGroupResourceId = 'REPLACE_WITH_REAL_VALUE:/subscriptions/<lims-dev-subscription-id>/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param subnetResourceId = 'REPLACE_WITH_REAL_VALUE:<resource ID of the existing snet-routable subnet>'

param diskEncryptionSetResourceId = 'REPLACE_WITH_REAL_VALUE:<resource ID of the existing LIMS DEV Disk Encryption Set>'

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
}

param appAdministratorLoginPrincipalIds = []

param appUserLoginPrincipalIds = []

param sqlAdministratorLoginPrincipalIds = []

param sqlUserLoginPrincipalIds = []

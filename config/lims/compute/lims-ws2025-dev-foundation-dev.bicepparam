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
// appAdministratorLoginPrincipalIds / appUserLoginPrincipalIds /
// sqlAdministratorLoginPrincipalIds / sqlUserLoginPrincipalIds are left at
// their empty-array defaults (omitted below), so this deployment creates NO
// Virtual Machine Administrator/User Login role assignment until the real
// existing Entra security group object IDs for this workload's current
// access model are supplied — see docs/operations.md for exactly what is
// required.
using '../../../src/compute/lims-ws2025-dev-foundation/main.bicep'

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

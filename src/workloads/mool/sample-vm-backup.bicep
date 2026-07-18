// =============================================================================
// SAMPLE COMPOSITION: lims — VM Backup
// =============================================================================
// PURPOSE
//   A worked, end-to-end EXAMPLE of a deployable composition for the lims
//   workload. It creates a resource group and protects the lims application VMs
//   with a Recovery Services vault + daily backup policy by calling the reusable
//   `modules/workload/recovery-services` module.
//
//   Use this file as the reference pattern when scaffolding any new workload
//   deployment in this repository.
//
// SCAFFOLDING GUIDE (read this if you are an AI agent creating a new deployment)
//   A composition in `src/` is the DEPLOYABLE ENTRY POINT. It MUST:
//     1. Choose the correct `targetScope`. VM backup resources live in a
//        resource group, so this composition runs at 'subscription' scope: it
//        creates the resource group, then deploys the module INTO that group via
//        `scope: rg`.
//     2. Contain NO environment-specific VALUES. Names are BUILT from the
//        `environment` + `location` parameters using the naming standard:
//            {type}-{workload}-{environment}-{region}   (region = full name)
//        Concrete values (which subscription, which VM IDs, tag values) come
//        from a `.bicepparam` file under `config/`.
//     3. Honour the parameter contract: environment, location, purpose,
//        subscriptionId, tags (see bicep-authoring-standards).
//     4. Delegate all real resource logic to modules — keep the composition thin.
//
// HOW TO DEPLOY (what-if first, then apply — see deployment-model-standards)
//   az deployment sub create \
//     --location westeurope \
//     --template-file   src/workloads/lims/sample-vm-backup.bicep \
//     --parameters      config/nfi/workloads/lims/sample-vm-backup.dev.bicepparam \
//     --what-if
// =============================================================================

targetScope = 'subscription'

metadata name = 'lims — VM Backup (Sample)'
metadata description = 'Sample composition: resource group + Recovery Services vault + VM backup policy protecting the lims VMs.'

// -----------------------------------------------------------------------------
// PARAMETER CONTRACT — the five standard params plus this deployment's inputs.
// -----------------------------------------------------------------------------

@description('Azure region. Always the full region name, e.g. "westeurope".')
param location string = 'westeurope'

@description('Environment code. Drives naming and retention defaults.')
@allowed(['dev', 'tst', 'acc', 'preprd', 'prd'])
param environment string

@description('Workload / purpose identifier used in naming and tagging.')
param purpose string = 'lims'

// Part of the standard parameter contract. It is consumed by the pipeline (to
// select the service connection), not by the template itself, so we disable the
// unused-parameter rule for it.
@description('Subscription ID this deployment targets. Used by pipelines to select the service connection.')
#disable-next-line no-unused-params
param subscriptionId string

@description('Resource IDs of the lims VMs to protect. Leave empty on first run to create the vault + policy before the VMs exist.')
param protectedVmResourceIds array = []

@description('Tags applied to all resources.')
param tags object = {}

// -----------------------------------------------------------------------------
// NAMING — build names from the contract, never hardcode them.
//   Pattern: {type}-{workload}-{environment}-{region}
// -----------------------------------------------------------------------------

var resourceGroupName = 'rg-${purpose}-backup-${environment}-${location}'
var vaultName = 'rsv-${purpose}-${environment}-${location}'

// Production keeps data geo-redundant and retains longer; non-prod is cheaper.
var isProduction = environment == 'prd'
var storageRedundancy = isProduction ? 'GeoRedundant' : 'LocallyRedundant'
var dailyRetentionDays = isProduction ? 90 : 30

// -----------------------------------------------------------------------------
// RESOURCES
// -----------------------------------------------------------------------------

// 1) Resource group that will hold the vault. The composition owns RG creation;
//    the module assumes the group already exists.
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// 2) Deploy the reusable backup module INTO the resource group above.
module backup '../../../modules/workload/recovery-services/main.bicep' = {
  name: 'lims-vm-backup'
  scope: rg
  params: {
    location: location
    vaultName: vaultName
    storageRedundancy: storageRedundancy
    dailyRetentionDays: dailyRetentionDays
    protectedVmResourceIds: protectedVmResourceIds
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// OUTPUTS — surface the module outputs for downstream deployments / pipelines.
// -----------------------------------------------------------------------------

@description('Resource ID of the Recovery Services vault.')
output vaultId string = backup.outputs.vaultId

@description('Resource ID of the VM backup policy.')
output backupPolicyId string = backup.outputs.backupPolicyId

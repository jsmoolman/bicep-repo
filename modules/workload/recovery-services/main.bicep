// =============================================================================
// MODULE: workload/recovery-services
// =============================================================================
// PURPOSE
//   Reusable, environment-neutral building block that deploys an Azure Recovery
//   Services vault, a VM (Azure IaaS) backup policy, and — optionally — protects
//   one or more existing virtual machines with that policy.
//
// SCAFFOLDING GUIDE (read this if you are an AI agent extending the repo)
//   This file is the canonical example of a "module" in this repository.
//   A module MUST:
//     1. Be reusable and environment-neutral — NO hardcoded environment codes
//        (dev/tst/prd) and NO hardcoded workload names (e.g. "mool"). All such
//        values arrive as parameters from the composition in `src/`.
//     2. Declare `targetScope = 'resourceGroup'` for resources that live inside
//        a resource group (the caller in `src/` owns RG creation).
//     3. Expose a small, explicit parameter contract with @description on every
//        parameter and @allowed / @minLength / @maxLength guards where useful.
//     4. Return outputs the composition needs to chain further resources.
//
// AUTHORING LOOKUP CHAIN (mandatory — see bicep-authoring-standards)
//   Before writing or changing resource blocks, ALWAYS run, in order:
//     1. Azure Verified Modules (AVM)  — https://azure.github.io/Azure-Verified-Modules/
//        AVM equivalent of this module: `br/public:avm/res/recovery-services/vault`.
//        Prefer AVM when a suitable module exists. This native implementation is
//        kept deliberately explicit so it can be read as a teaching example.
//     2. Bicep Registry source         — https://github.com/Azure/bicep-registry-modules
//     3. Microsoft Learn Bicep docs    — https://learn.microsoft.com/azure/azure-resource-manager/bicep/
//     4. Bicep MCP tools               — get_az_resource_type_schema, get_bicep_best_practices,
//                                         get_bicep_file_diagnostics, format_bicep_file
// =============================================================================

targetScope = 'resourceGroup'

metadata name = 'Workload — Recovery Services (VM Backup)'
metadata description = 'Reusable module: Recovery Services vault + Azure VM backup policy, with optional protection of existing VMs.'

// -----------------------------------------------------------------------------
// PARAMETERS — the module's public contract.
// Every value that differs between environments or workloads MUST be a parameter.
// -----------------------------------------------------------------------------

@description('Azure region for the vault. Always the full region name, e.g. "westeurope". Never a short code such as "weu".')
param location string

@description('Fully-resolved Recovery Services vault name. Built by the caller using the naming standard: rsv-{workload}-{environment}-{region}.')
@minLength(2)
@maxLength(50)
param vaultName string

@description('Name of the VM backup policy created inside the vault.')
param backupPolicyName string = 'vm-daily-backup-policy'

@description('Time of day (UTC) the daily backup runs. Use an ISO-8601 timestamp; only the time component is significant.')
param backupTimeUtc string = '2026-01-01T02:00:00Z'

@description('Number of daily restore points to retain.')
@minValue(7)
@maxValue(9999)
param dailyRetentionDays int = 30

@description('Number of weekly restore points to retain (taken on the days listed in weeklyRetentionDays).')
@minValue(1)
@maxValue(5163)
param weeklyRetentionWeeks int = 12

@description('Days of week on which the weekly retention point is kept.')
param weeklyRetentionDays array = ['Sunday']

@description('Storage redundancy for the vault. Use GeoRedundant for production, LocallyRedundant for non-production to reduce cost.')
@allowed(['LocallyRedundant', 'GeoRedundant', 'ZoneRedundant'])
param storageRedundancy string = 'GeoRedundant'

@description('Resource IDs of existing VMs to protect with the policy. Leave empty to create the vault + policy only (e.g. before the VMs exist).')
param protectedVmResourceIds array = []

@description('Tags applied to every resource in this module.')
param tags object = {}

// -----------------------------------------------------------------------------
// VARIABLES — derived values. Keep logic here, not inline in resource blocks.
// -----------------------------------------------------------------------------

// Azure Backup requires a deterministic name for the protected item:
//   VM;iaasvmcontainerv2;{vm-resource-group};{vm-name}
// We derive both the container (fabric) name and the protected item name from
// each VM resource ID so callers only need to pass the VM's resourceId().
var protectedItems = [
  for vmId in protectedVmResourceIds: {
    vmResourceId: vmId
    vmName: last(split(vmId, '/'))
    vmResourceGroup: split(vmId, '/')[4]
  }
]

// -----------------------------------------------------------------------------
// RESOURCES
// -----------------------------------------------------------------------------

// 1) Recovery Services vault — the container for backup data and policies.
resource vault 'Microsoft.RecoveryServices/vaults@2023-06-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    // Disable public network access; expect private endpoints / trusted Azure
    // services. Tighten further per the security baseline as needed.
    publicNetworkAccess: 'Disabled'
  }
}

// 2) Storage redundancy is configured on the vault's backup config sub-resource.
//    It MUST be set before any backup item is protected, hence it is declared
//    here and the protected items below depend on the vault.
resource vaultConfig 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-06-01' = {
  parent: vault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: storageRedundancy
    crossRegionRestoreFlag: storageRedundancy == 'GeoRedundant'
  }
}

// 3) VM backup policy — daily schedule with daily + weekly retention.
resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  parent: vault
  name: backupPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2' // Enhanced policy — required for modern VM SKUs and multiple backups/day.
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [backupTimeUtc]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [backupTimeUtc]
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: weeklyRetentionDays
        retentionTimes: [backupTimeUtc]
        retentionDuration: {
          count: weeklyRetentionWeeks
          durationType: 'Weeks'
        }
      }
    }
    timeZone: 'UTC'
  }
}

// 4) Protected items — associate each existing VM with the policy above.
//    This loop runs only when protectedVmResourceIds is non-empty, so the same
//    module can be deployed first (vault + policy) and re-run later (protect VMs).
resource protection 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2023-06-01' = [
  for item in protectedItems: {
    // Resource name path:
    //   {vault}/Azure/iaasvmcontainerv2;{rg};{vm}/vm;iaasvmcontainerv2;{rg};{vm}
    name: '${vaultName}/Azure/iaasvmcontainerv2;${item.vmResourceGroup};${item.vmName}/vm;iaasvmcontainerv2;${item.vmResourceGroup};${item.vmName}'
    properties: {
      protectedItemType: 'Microsoft.Compute/virtualMachines'
      policyId: backupPolicy.id
      sourceResourceId: item.vmResourceId
    }
    dependsOn: [
      vaultConfig
    ]
  }
]

// -----------------------------------------------------------------------------
// OUTPUTS — values the composition in `src/` may need to chain further work.
// -----------------------------------------------------------------------------

@description('Resource ID of the Recovery Services vault.')
output vaultId string = vault.id

@description('Name of the Recovery Services vault.')
output vaultName string = vault.name

@description('Resource ID of the VM backup policy.')
output backupPolicyId string = backupPolicy.id

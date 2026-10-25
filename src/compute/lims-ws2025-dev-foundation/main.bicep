metadata description = 'Subscription-scoped orchestrator for the LIMS WS2025 Phase 1 compute foundation: deploys the replacement APP and SQL virtual machines, their NICs and managed disks, the Microsoft Entra sign-in extension, and (opt-in only, enableGuestDiskPreparation) guest data-disk preparation for their approved data disks, into the existing resource group that already hosts the LIMS DEV network/encryption foundation. Deploys no VNet, subnet, Key Vault, Disk Encryption Set, or any resource not explicitly covered by the LIMS WS2025 Phase 1 exception in docs/scope.md.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the existing resource group to deploy into, e.g. /subscriptions/<id>/resourceGroups/rg-compute-lims-dev-westeu. Both the target subscription and resource group are derived from this single authoritative value — there is no separate/duplicate subscription or resource-group parameter.')
param resourceGroupResourceId string

@description('Azure region for the VMs, NICs, and disks.')
param location string = 'westeurope'

@description('Full ARM resource ID of the existing subnet both NICs attach to.')
param subnetResourceId string

@description('Full ARM resource ID of the existing Disk Encryption Set used for customer-managed-key SSE on every managed disk.')
param diskEncryptionSetResourceId string

@description('Azure VM size for both the APP and SQL virtual machines.')
param vmSize string = 'Standard_D4ads_v5'

@description('Marketplace image publisher.')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Marketplace image offer.')
param imageOffer string = 'WindowsServer'

@description('Marketplace image SKU — plain Windows Server 2025 Datacenter, Gen2, Desktop Experience (not an Azure Edition SKU).')
param imageSku string = '2025-datacenter-g2'

@description('Marketplace image version.')
param imageVersion string = 'latest'

@description('Size in GiB of both the APP and SQL OS disks. Explicitly set to preserve the current LIMS v1 OS disk size rather than relying on the Windows Server 2025 Marketplace image default.')
param osDiskSizeGiB int = 127

@description('Azure resource name of the APP virtual machine.')
param appVmName string

@description('Windows computer name (NetBIOS, max 15 characters) of the APP virtual machine.')
@maxLength(15)
param appComputerName string

@description('Resource name of the APP NIC.')
param appNicName string

@description('Resource name of the APP OS disk.')
param appOsDiskName string

@description('Resource name of the APP application data disk (future A:).')
param appDataDiskName string

@description('Size in GiB of the APP application data disk.')
param appDataDiskSizeGiB int = 128

@description('Performance tier of the APP application data disk (e.g. P10). Explicitly preserved so it is not reset by redeployment. Keep in sync with appDataDiskSizeGiB — see modules/compute/lims-ws2025-dev-foundation for the full size/tier constraint.')
param appDataDiskTier string = 'P10'

@description('Azure resource name of the SQL virtual machine.')
param sqlVmName string

@description('Windows computer name (NetBIOS, max 15 characters) of the SQL virtual machine.')
@maxLength(15)
param sqlComputerName string

@description('Resource name of the SQL NIC.')
param sqlNicName string

@description('Resource name of the SQL OS disk.')
param sqlOsDiskName string

@description('Resource name of the SQL DATA disk.')
param sqlDataDiskName string

@description('Size in GiB of the SQL DATA disk.')
param sqlDataDiskSizeGiB int = 1024

@description('Performance tier of the SQL DATA disk (e.g. P30). Same purpose and constraints as appDataDiskTier. Keep in sync with sqlDataDiskSizeGiB.')
param sqlDataDiskTier string = 'P30'

@description('Resource name of the SQL LOG disk.')
param sqlLogDiskName string

@description('Size in GiB of the SQL LOG disk.')
param sqlLogDiskSizeGiB int = 512

@description('Performance tier of the SQL LOG disk (e.g. P20). Same purpose and constraints as appDataDiskTier. Keep in sync with sqlLogDiskSizeGiB.')
param sqlLogDiskTier string = 'P20'

@description('Local administrator username for both VMs — deployment/break-glass account only.')
@secure()
param adminUsername string

@description('Local administrator password for both VMs. Supplied as a secure deployment-time value only; never defaulted, never stored in source or parameter files.')
@secure()
param adminPassword string

@description('Common tags applied to every resource (e.g. environment, purpose). A role tag (application/sql) is added internally per VM — do not duplicate role here.')
param tags object = {}

@description('Full ARM resource IDs of existing user-assigned managed identities that must remain attached to the APP VM across redeployments (e.g. an existing Policy-managed identity such as Built-In-Identity-westeurope). Distinct from src/compute/lims-ws2025-dev-patch-policy\'s userAssignedIdentityResourceId, which is only referenced by policy assignments for remediation and is never attached to a VM. Never creates an identity or new permission here — reuse/preservation only. Empty (default) preserves the original initial-creation identity shape (SystemAssigned only); see modules/compute/lims-ws2025-dev-foundation for full constraints.')
param appExistingUserAssignedIdentityResourceIds array = []

@description('Same purpose and constraints as appExistingUserAssignedIdentityResourceIds, applied to the SQL VM.')
param sqlExistingUserAssignedIdentityResourceIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the APP VM. Empty (default) creates no role assignment.')
param appAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the APP VM. Empty (default) creates no role assignment.')
param appUserLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the SQL VM. Empty (default) creates no role assignment.')
param sqlAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the SQL VM. Empty (default) creates no role assignment.')
param sqlUserLoginPrincipalIds array = []

@description('Opt-in switch for automated guest data-disk preparation. Defaults to false. See modules/compute/lims-ws2025-dev-foundation for the full behavioral contract and docs/operations.md for the customer opt-in/validation procedure.')
param enableGuestDiskPreparation bool = false

@description('Destination drive letter (single character, no colon) for the APP application data disk once enableGuestDiskPreparation is true.')
param appDataVolumeDriveLetter string = 'A'

@description('NTFS volume label applied to the APP application data disk once enableGuestDiskPreparation is true.')
param appDataVolumeLabel string = 'LIMS-App'

@description('NTFS allocation unit size, in bytes, for the APP application data disk once enableGuestDiskPreparation is true.')
param appDataVolumeAllocationUnitBytes int = 4096

@description('Destination drive letter (single character, no colon) for the SQL DATA disk once enableGuestDiskPreparation is true.')
param sqlDataVolumeDriveLetter string = 'E'

@description('NTFS volume label applied to the SQL DATA disk once enableGuestDiskPreparation is true.')
param sqlDataVolumeLabel string = 'SQL-Data'

@description('NTFS allocation unit size, in bytes, for the SQL DATA disk once enableGuestDiskPreparation is true.')
param sqlDataVolumeAllocationUnitBytes int = 65536

@description('Destination drive letter (single character, no colon) for the SQL LOG disk once enableGuestDiskPreparation is true.')
param sqlLogVolumeDriveLetter string = 'F'

@description('NTFS volume label applied to the SQL LOG disk once enableGuestDiskPreparation is true.')
param sqlLogVolumeLabel string = 'SQL-Logs'

@description('NTFS allocation unit size, in bytes, for the SQL LOG disk once enableGuestDiskPreparation is true.')
param sqlLogVolumeAllocationUnitBytes int = 65536

@description('Timeout, in seconds, for each guest data-disk preparation Run Command execution once enableGuestDiskPreparation is true.')
param guestDiskPreparationTimeoutInSeconds int = 1800

// ─── Derived scope ────────────────────────────────────────────────────────────
// Subscription ID and resource group name are parsed out of
// resourceGroupResourceId rather than accepted as separate parameters, mirroring
// the pattern already used by src/observability/cost-management-data-foundation.

var resourceGroupIdSegments = split(resourceGroupResourceId, '/')
var targetSubscriptionId = resourceGroupIdSegments[2]
var targetResourceGroupName = resourceGroupIdSegments[4]

// ─── Module ───────────────────────────────────────────────────────────────────

module foundation '../../../modules/compute/lims-ws2025-dev-foundation/main.bicep' = {
  scope: resourceGroup(targetSubscriptionId, targetResourceGroupName)
  params: {
    location: location
    subnetResourceId: subnetResourceId
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    vmSize: vmSize
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    osDiskSizeGiB: osDiskSizeGiB
    appVmName: appVmName
    appComputerName: appComputerName
    appNicName: appNicName
    appOsDiskName: appOsDiskName
    appDataDiskName: appDataDiskName
    appDataDiskSizeGiB: appDataDiskSizeGiB
    appDataDiskTier: appDataDiskTier
    sqlVmName: sqlVmName
    sqlComputerName: sqlComputerName
    sqlNicName: sqlNicName
    sqlOsDiskName: sqlOsDiskName
    sqlDataDiskName: sqlDataDiskName
    sqlDataDiskSizeGiB: sqlDataDiskSizeGiB
    sqlDataDiskTier: sqlDataDiskTier
    sqlLogDiskName: sqlLogDiskName
    sqlLogDiskSizeGiB: sqlLogDiskSizeGiB
    sqlLogDiskTier: sqlLogDiskTier
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
    appExistingUserAssignedIdentityResourceIds: appExistingUserAssignedIdentityResourceIds
    sqlExistingUserAssignedIdentityResourceIds: sqlExistingUserAssignedIdentityResourceIds
    appAdministratorLoginPrincipalIds: appAdministratorLoginPrincipalIds
    appUserLoginPrincipalIds: appUserLoginPrincipalIds
    sqlAdministratorLoginPrincipalIds: sqlAdministratorLoginPrincipalIds
    sqlUserLoginPrincipalIds: sqlUserLoginPrincipalIds
    enableGuestDiskPreparation: enableGuestDiskPreparation
    appDataVolumeDriveLetter: appDataVolumeDriveLetter
    appDataVolumeLabel: appDataVolumeLabel
    appDataVolumeAllocationUnitBytes: appDataVolumeAllocationUnitBytes
    sqlDataVolumeDriveLetter: sqlDataVolumeDriveLetter
    sqlDataVolumeLabel: sqlDataVolumeLabel
    sqlDataVolumeAllocationUnitBytes: sqlDataVolumeAllocationUnitBytes
    sqlLogVolumeDriveLetter: sqlLogVolumeDriveLetter
    sqlLogVolumeLabel: sqlLogVolumeLabel
    sqlLogVolumeAllocationUnitBytes: sqlLogVolumeAllocationUnitBytes
    guestDiskPreparationTimeoutInSeconds: guestDiskPreparationTimeoutInSeconds
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP virtual machine.')
output appVmResourceId string = foundation.outputs.appVmResourceId

@description('Full ARM resource ID of the SQL virtual machine.')
output sqlVmResourceId string = foundation.outputs.sqlVmResourceId

@description('System-assigned managed identity principal ID of the APP virtual machine.')
output appVmPrincipalId string = foundation.outputs.appVmPrincipalId

@description('System-assigned managed identity principal ID of the SQL virtual machine.')
output sqlVmPrincipalId string = foundation.outputs.sqlVmPrincipalId

@description('Full ARM resource ID of the APP NIC.')
output appNicResourceId string = foundation.outputs.appNicResourceId

@description('Full ARM resource ID of the SQL NIC.')
output sqlNicResourceId string = foundation.outputs.sqlNicResourceId

@description('Full ARM resource ID of the APP application data disk.')
output appDataDiskResourceId string = foundation.outputs.appDataDiskResourceId

@description('Full ARM resource ID of the SQL DATA disk.')
output sqlDataDiskResourceId string = foundation.outputs.sqlDataDiskResourceId

@description('Full ARM resource ID of the SQL LOG disk.')
output sqlLogDiskResourceId string = foundation.outputs.sqlLogDiskResourceId

@description('Resource group hosting the deployed VMs (derived from resourceGroupResourceId).')
output resourceGroupName string = targetResourceGroupName

@description('Subscription ID hosting the deployed VMs (derived from resourceGroupResourceId).')
output subscriptionId string = targetSubscriptionId

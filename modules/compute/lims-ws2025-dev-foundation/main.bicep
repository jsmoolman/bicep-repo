metadata description = 'LIMS WS2025 Phase 1 compute foundation: creates the replacement APP and SQL virtual machines (Windows Server 2025 Datacenter, non-Azure Edition), their directly coupled NICs and managed disks, the Microsoft Entra sign-in extension, and the Azure Machine Configuration (Guest Configuration) extension (AzurePolicyforWindows — a prerequisite for the existing, separately-managed time-zone enforcement policy; see the LIMS WS2025 DEV v2 time-zone enforcement exception in docs/scope.md). Approved under the narrow LIMS WS2025 Phase 1 workload-infrastructure exception in docs/scope.md. Creates no VNet, subnet, NSG, Key Vault, Disk Encryption Set, Log Analytics workspace, DCR, Recovery Services Vault, or Entra group, and assigns only the two approved built-in VM-login roles to already-existing Entra groups (not an Entra ID mutation — see docs/scope.md). Installs no SQL Server and performs no application/data migration. Optionally (enableGuestDiskPreparation, default false) also initializes/partitions/formats/labels the APP application data disk and the two SQL data/log disks to their approved drive letters via a Run Command resource scoped to exactly these two VMs — see docs/operations.md for the full guest data-disk preparation behavioral contract.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region for the VMs, NICs, and disks. Must match the resource group region.')
param location string = 'westeurope'

@description('Full ARM resource ID of the existing subnet both NICs attach to. Referenced only as an ID string — no VNet/subnet resource is declared, read, or modified.')
param subnetResourceId string

@description('Full ARM resource ID of the existing Disk Encryption Set used for customer-managed-key SSE on every managed disk created here. Referenced only as an ID string — no Disk Encryption Set or Key Vault resource is declared, read, or modified.')
param diskEncryptionSetResourceId string

@description('Azure VM size for both the APP and SQL virtual machines.')
param vmSize string = 'Standard_D4ads_v5'

@description('Marketplace image publisher. Defaults to the standard Windows Server publisher.')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Marketplace image offer. Defaults to the standard Windows Server offer.')
param imageOffer string = 'WindowsServer'

@description('Marketplace image SKU. Defaults to plain Windows Server 2025 Datacenter, Gen2, Desktop Experience — explicitly not an Azure Edition SKU.')
param imageSku string = '2025-datacenter-g2'

@description('Marketplace image version.')
param imageVersion string = 'latest'

@description('Size in GiB of both the APP and SQL OS disks. Explicitly set to preserve the current LIMS v1 OS disk size rather than relying on the Windows Server 2025 Marketplace image default.')
param osDiskSizeGiB int = 127

@description('Azure resource name of the APP virtual machine, e.g. vm-lims-dev-v2-westeu-001.')
param appVmName string

@description('Windows computer name (NetBIOS, max 15 characters) of the APP virtual machine, e.g. lims-dev-v2-001.')
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

@description('Performance tier of the APP application data disk (e.g. P10, P15, P20...). Explicitly preserved so it is not reset to a default by redeployment (see docs/operations.md). This is the free-form disk.properties.tier value, not the disk SKU name — Premium_LRS is unaffected. Must match the baseline tier implied by appDataDiskSizeGiB per the Premium SSD size/tier table (https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types#premium-ssd-size); defaults to P10, the baseline tier for the current 128 GiB size. This module does not derive the tier from the size automatically — if appDataDiskSizeGiB ever changes, update this parameter to the matching tier yourself, otherwise the disk would be deployed below its size baseline (not supported) or burst-billed above it (a real cost/performance change, not a default).')
param appDataDiskTier string = 'P10'

@description('Azure resource name of the SQL virtual machine, e.g. vm-lims-dev-v2-westeu-002.')
param sqlVmName string

@description('Windows computer name (NetBIOS, max 15 characters) of the SQL virtual machine, e.g. lims-dev-v2-002.')
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

@description('Performance tier of the SQL DATA disk. Same purpose and constraints as appDataDiskTier. Defaults to P30, the baseline tier for the current 1024 GiB size (https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types#premium-ssd-size). Keep in sync with sqlDataDiskSizeGiB.')
param sqlDataDiskTier string = 'P30'

@description('Resource name of the SQL LOG disk.')
param sqlLogDiskName string

@description('Size in GiB of the SQL LOG disk.')
param sqlLogDiskSizeGiB int = 512

@description('Performance tier of the SQL LOG disk. Same purpose and constraints as appDataDiskTier. Defaults to P20, the baseline tier for the current 512 GiB size (https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types#premium-ssd-size). Keep in sync with sqlLogDiskSizeGiB.')
param sqlLogDiskTier string = 'P20'

@description('Local administrator username for both VMs — a deployment/break-glass account only. Normal personnel access is through Microsoft Entra sign-in (see appAdministratorLoginPrincipalIds etc. below), not this account.')
@secure()
param adminUsername string

@description('Local administrator password for both VMs. Never defaulted, never present in source or parameter files — supplied as a secure deployment-time value only.')
@secure()
param adminPassword string

@description('Common tags applied to every resource in this module (e.g. environment, purpose). Each VM/disk additionally gets a role tag (application or sql) added internally — do not duplicate role here.')
param tags object = {}

@description('''Full ARM resource IDs of existing user-assigned managed identities that must remain attached to the APP VM across redeployments (e.g. an existing Policy-managed monitoring/CTI identity such as Built-In-Identity-westeurope). This is NOT the same thing as modules/compute/lims-ws2025-dev-patch-policy's userAssignedIdentityResourceId parameter: that identity is referenced only by Microsoft.Authorization/policyAssignments resources for Policy remediation and is never attached to either VM, while this parameter is attached directly to the VM's own identity property. This module never creates a user-assigned identity, grants it any new permission, or attaches the deployment/remediation identity to a VM — it only preserves identities already attached to the VM from outside this module (e.g. by Azure Policy's own remediation). Supply only authoritative existing resource IDs — never guessed, inferred, or reconstructed (including from screenshots). The system-assigned identity is always retained regardless of this parameter's value. Empty (default) preserves the VM's original initial-creation identity shape (SystemAssigned only) — on an already-converged VM that already has a user-assigned identity attached from outside Bicep, leaving this parameter empty on redeployment does NOT preserve that identity: Azure resets an omitted identity.userAssignedIdentities property on redeployment (see docs/operations.md and docs/scope.md).''')
param appExistingUserAssignedIdentityResourceIds array = []

@description('Same purpose and constraints as appExistingUserAssignedIdentityResourceIds, applied to the SQL VM.')
param sqlExistingUserAssignedIdentityResourceIds array = []

@description('''Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the APP VM. Empty (default) creates no role assignment. Assigning an existing Entra principal to this built-in role is not an Entra ID mutation (see docs/scope.md, "RBAC and Entra ID mutation are distinct"), but it is still a deliberate, approved decision scoped to this workload only — populate only with existing group object IDs already authoritative outside this repository (never invented/guessed). The approved DEV mapping for this parameter is AZ-TC-LIMS-Infra, AZ-TC-LIMS-Func, AZ-TC-LIMS-App (see docs/scope.md and docs/operations.md).''')
param appAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the APP VM. Same constraints as appAdministratorLoginPrincipalIds. No DEV User Login assignment is currently approved/required for this VM, so this is expected to stay empty for DEV.')
param appUserLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the SQL VM. Same constraints as appAdministratorLoginPrincipalIds. The approved DEV mapping for this parameter is AZ-TC-LIMS-Infra, AZ-TC-LIMS-App (see docs/scope.md and docs/operations.md).')
param sqlAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the SQL VM. Same constraints as appAdministratorLoginPrincipalIds. No DEV User Login assignment is currently approved/required for this VM, so this is expected to stay empty for DEV.')
param sqlUserLoginPrincipalIds array = []

@description('''Opt-in switch for automated guest data-disk preparation (initialize, partition, format, assign drive letter/label) on the APP application data disk and the two SQL data/log disks, delivered via Microsoft.Compute/virtualMachines/runCommands scoped to exactly these two VMs. Defaults to false — a normal foundation redeployment never formats a disk unless this is explicitly set to true. Every mutation target is still re-verified at execution time against Azure Instance Metadata Service identity, LUN, managed-disk resource name, and capacity before anything is touched — this flag only controls whether the Run Command resource is deployed at all. See docs/operations.md for the full behavioral contract, idempotency model, and customer opt-in/validation procedure.''')
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

@description('Timeout, in seconds, for each of the two guest data-disk preparation Run Command executions once enableGuestDiskPreparation is true. The managed Run Command resource blocks the deployment until the script completes or this timeout elapses (see docs/operations.md).')
param guestDiskPreparationTimeoutInSeconds int = 1800

// ─── Built-in role definition IDs (approved RBAC decision — see docs/scope.md) ───
// GUIDs verified against Microsoft Learn's built-in roles reference. These are
// read-only references to Microsoft's built-in role definitions via
// subscriptionResourceId() — no custom role definition is declared anywhere in
// this module, and no other role is used anywhere in this module.

var vmAdministratorLoginRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
var vmUserLoginRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')

var appTags = union(tags, { role: 'application' })
var sqlTags = union(tags, { role: 'sql' })

// ─── Guest data-disk preparation (opt-in — see enableGuestDiskPreparation) ───
// Source kept reviewable in this repository as a plain .ps1 file and loaded
// inline via loadTextContent() — never published to a storage account, never
// containing a secret. Delivered to the guest via
// Microsoft.Compute/virtualMachines/runCommands (see the two conditional
// resources below), scoped to exactly appVm/sqlVm. See
// modules/compute/lims-ws2025-dev-foundation/scripts/Initialize-LimsGuestDataDisks.ps1
// for the full safety model and docs/operations.md for the behavioral
// contract. Lun values below are the exact literal values already used by
// appVm/sqlVm's own storageProfile.dataDisks[] attachments further down in
// this file (0 for the APP data disk; 0/1 for the SQL data/log disks) — they
// are read from the same single source, so the script's verification target
// can never drift from the VM's actual disk attachment.
var guestDiskPreparationScript = loadTextContent('scripts/Initialize-LimsGuestDataDisks.ps1')

var appExpectedGuestDisks = [
  {
    Lun: 0
    DiskName: appDataDiskName
    SizeBytes: appDataDiskSizeGiB * 1024 * 1024 * 1024
    DriveLetter: appDataVolumeDriveLetter
    FileSystemLabel: appDataVolumeLabel
    AllocationUnitBytes: appDataVolumeAllocationUnitBytes
  }
]

var sqlExpectedGuestDisks = [
  {
    Lun: 0
    DiskName: sqlDataDiskName
    SizeBytes: sqlDataDiskSizeGiB * 1024 * 1024 * 1024
    DriveLetter: sqlDataVolumeDriveLetter
    FileSystemLabel: sqlDataVolumeLabel
    AllocationUnitBytes: sqlDataVolumeAllocationUnitBytes
  }
  {
    Lun: 1
    DiskName: sqlLogDiskName
    SizeBytes: sqlLogDiskSizeGiB * 1024 * 1024 * 1024
    DriveLetter: sqlLogVolumeDriveLetter
    FileSystemLabel: sqlLogVolumeLabel
    AllocationUnitBytes: sqlLogVolumeAllocationUnitBytes
  }
]

// ─── VM identity shape (preserve existing user-assigned identities, e.g. Azure Policy remediation identities) ───
// Always retains SystemAssigned. When *ExistingUserAssignedIdentityResourceIds is
// non-empty, declares SystemAssigned plus UserAssigned and includes every supplied
// ID. Empty input reproduces the original initial-creation behavior (SystemAssigned
// only) — it does not read live state and cannot discover identities on its own; see
// the parameter descriptions above and docs/operations.md.
var appIdentity = empty(appExistingUserAssignedIdentityResourceIds) ? {
  type: 'SystemAssigned'
} : {
  type: 'SystemAssigned, UserAssigned'
  userAssignedIdentities: toObject(appExistingUserAssignedIdentityResourceIds, id => id, id => {})
}

var sqlIdentity = empty(sqlExistingUserAssignedIdentityResourceIds) ? {
  type: 'SystemAssigned'
} : {
  type: 'SystemAssigned, UserAssigned'
  userAssignedIdentities: toObject(sqlExistingUserAssignedIdentityResourceIds, id => id, id => {})
}

// ─── APP: NIC, disks, VM ───────────────────────────────────────────────────────
// Dynamic private IPv4 on the existing subnet only; no public IP, no NSG created
// or attached here (subnet-level network controls are unchanged by this module).

resource appNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: appNicName
  location: location
  tags: appTags
  properties: {
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
    disableTcpStateTracking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

// Phase 1 foundation only: created, sized, encrypted, and attached at LUN 0.
// Not initialized, formatted, or assigned a drive letter — guest configuration
// and the eventual A:\ application-content migration are later tasks.
resource appDataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: appDataDiskName
  location: location
  tags: appTags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: appDataDiskSizeGiB
    tier: appDataDiskTier
    networkAccessPolicy: 'AllowAll'
    publicNetworkAccess: 'Enabled'
    encryption: {
      type: 'EncryptionAtRestWithCustomerKey'
      diskEncryptionSetId: diskEncryptionSetResourceId
    }
  }
}

resource appVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: appVmName
  location: location
  tags: appTags
  identity: appIdentity
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: appOsDiskName
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGiB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          diskEncryptionSet: {
            id: diskEncryptionSetResourceId
          }
        }
      }
      dataDisks: [
        {
          lun: 0
          name: appDataDiskName
          caching: 'None'
          createOption: 'Attach'
          deleteOption: 'Detach'
          managedDisk: {
            id: appDataDisk.id
          }
        }
      ]
    }
    osProfile: {
      computerName: appComputerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            bypassPlatformSafetyChecksOnUserSchedule: true
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: appNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      encryptionAtHost: true
    }
  }
}

// Microsoft Entra VM sign-in. The extension alone is not complete access
// configuration — it must be paired with Virtual Machine Administrator/User
// Login RBAC (see role assignments below) before any personnel can sign in.
resource appAadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: appVm
  name: 'AADLoginForWindows'
  location: location
  tags: appTags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Azure Machine Configuration (Guest Configuration) extension. Required so the
// existing, separately-managed subscription-scoped time-zone enforcement
// policy assignment (built-in definition 6141c932-9384-44c6-a395-59e4c057d7c9)
// can evaluate and remediate this VM — this module does not create, modify,
// or reference that policy assignment, or any guest configuration assignment,
// itself (see docs/scope.md). Instance name, publisher, type, and upgrade
// settings match Microsoft's documented deployment exactly
// (https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/guest-configuration).
// The VM's system-assigned identity (always retained — see appIdentity above)
// satisfies the extension's only other prerequisite. No settings/
// protectedSettings are declared: the agent reads its configuration from the
// guest configuration assignment resource, not from this extension.
resource appGuestConfigurationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: appVm
  name: 'AzurePolicyforWindows'
  location: location
  tags: appTags
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationforWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource appAdministratorLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in appAdministratorLoginPrincipalIds: {
  name: guid(appVm.id, principalId, vmAdministratorLoginRoleDefinitionId)
  scope: appVm
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: vmAdministratorLoginRoleDefinitionId
  }
}]

resource appUserLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in appUserLoginPrincipalIds: {
  name: guid(appVm.id, principalId, vmUserLoginRoleDefinitionId)
  scope: appVm
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: vmUserLoginRoleDefinitionId
  }
}]

// Opt-in only (see enableGuestDiskPreparation). Scoped to exactly appVm — no
// other resource reference, tag filter, or subscription/resource-group-wide
// discovery is used anywhere in this composition. asyncExecution is left at
// its documented default (false), and treatFailureAsDeploymentFailure is
// explicitly true, so this deployment genuinely waits for the guest script
// to finish and surfaces a non-zero script exit code as a deployment
// failure (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command-managed)
// — a successful ARM deployment of this resource is not presented as
// evidence of guest-script success independently of that behavior. No
// RunAsUser/RunAsPassword is supplied, so the script executes as SYSTEM, the
// documented default for Run Command on Windows. DvdLetterMoveTarget is
// empty — this VM's DVD-ROM letter is never touched.
resource appGuestDiskPreparation 'Microsoft.Compute/virtualMachines/runCommands@2024-11-01' = if (enableGuestDiskPreparation) {
  parent: appVm
  name: 'lims-guest-disk-preparation'
  location: location
  tags: appTags
  properties: {
    source: {
      script: guestDiskPreparationScript
    }
    parameters: [
      {
        name: 'ExpectedSubscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'ExpectedResourceGroupName'
        value: resourceGroup().name
      }
      {
        name: 'ExpectedVmName'
        value: appVmName
      }
      {
        name: 'ExpectedComputerName'
        value: appComputerName
      }
      {
        name: 'ExpectedDisksJson'
        value: string(appExpectedGuestDisks)
      }
      {
        name: 'DvdLetterMoveTarget'
        value: ''
      }
    ]
    timeoutInSeconds: guestDiskPreparationTimeoutInSeconds
    treatFailureAsDeploymentFailure: true
    asyncExecution: false
  }
}

// ─── SQL: NIC, disks, VM ─────────────────────────────────────────────────────
// Plain Windows Server 2025 Datacenter VM only — no SQL Server Marketplace
// image, no SQL Server installation, no SQL IaaS Agent registration. The two
// data disks are created, sized, encrypted, and attached at their target LUNs
// only; they are not initialized, formatted, or assigned drive letters (E:/F:
// guest configuration belongs to the later SQL configuration stage). No
// legacy backup disk is recreated.

resource sqlNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: sqlNicName
  location: location
  tags: sqlTags
  properties: {
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
    disableTcpStateTracking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

resource sqlDataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: sqlDataDiskName
  location: location
  tags: sqlTags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: sqlDataDiskSizeGiB
    tier: sqlDataDiskTier
    networkAccessPolicy: 'AllowAll'
    publicNetworkAccess: 'Enabled'
    encryption: {
      type: 'EncryptionAtRestWithCustomerKey'
      diskEncryptionSetId: diskEncryptionSetResourceId
    }
  }
}

resource sqlLogDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: sqlLogDiskName
  location: location
  tags: sqlTags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: sqlLogDiskSizeGiB
    tier: sqlLogDiskTier
    networkAccessPolicy: 'AllowAll'
    publicNetworkAccess: 'Enabled'
    encryption: {
      type: 'EncryptionAtRestWithCustomerKey'
      diskEncryptionSetId: diskEncryptionSetResourceId
    }
  }
}

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: sqlVmName
  location: location
  tags: sqlTags
  identity: sqlIdentity
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: sqlOsDiskName
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGiB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          diskEncryptionSet: {
            id: diskEncryptionSetResourceId
          }
        }
      }
      dataDisks: [
        {
          lun: 0
          name: sqlDataDiskName
          caching: 'ReadOnly'
          createOption: 'Attach'
          deleteOption: 'Detach'
          managedDisk: {
            id: sqlDataDisk.id
          }
        }
        {
          lun: 1
          name: sqlLogDiskName
          caching: 'None'
          createOption: 'Attach'
          deleteOption: 'Detach'
          managedDisk: {
            id: sqlLogDisk.id
          }
        }
      ]
    }
    osProfile: {
      computerName: sqlComputerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            bypassPlatformSafetyChecksOnUserSchedule: true
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      encryptionAtHost: true
    }
  }
}

resource sqlAadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: sqlVm
  name: 'AADLoginForWindows'
  location: location
  tags: sqlTags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Same purpose and constraints as appGuestConfigurationExtension above.
resource sqlGuestConfigurationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: sqlVm
  name: 'AzurePolicyforWindows'
  location: location
  tags: sqlTags
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationforWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource sqlAdministratorLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in sqlAdministratorLoginPrincipalIds: {
  name: guid(sqlVm.id, principalId, vmAdministratorLoginRoleDefinitionId)
  scope: sqlVm
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: vmAdministratorLoginRoleDefinitionId
  }
}]

resource sqlUserLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in sqlUserLoginPrincipalIds: {
  name: guid(sqlVm.id, principalId, vmUserLoginRoleDefinitionId)
  scope: sqlVm
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: vmUserLoginRoleDefinitionId
  }
}]

// Opt-in only (see enableGuestDiskPreparation). Scoped to exactly sqlVm —
// same constraints and reasoning as appGuestDiskPreparation above.
// DvdLetterMoveTarget is 'Z' — the one approved, conditional SQL-only DVD
// letter move (E: -> Z:, only if E: is confirmed to be the empty virtual
// DVD-ROM and Z: is free; the script fails rather than moving anything else
// or overwriting an occupied Z:).
resource sqlGuestDiskPreparation 'Microsoft.Compute/virtualMachines/runCommands@2024-11-01' = if (enableGuestDiskPreparation) {
  parent: sqlVm
  name: 'lims-guest-disk-preparation'
  location: location
  tags: sqlTags
  properties: {
    source: {
      script: guestDiskPreparationScript
    }
    parameters: [
      {
        name: 'ExpectedSubscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'ExpectedResourceGroupName'
        value: resourceGroup().name
      }
      {
        name: 'ExpectedVmName'
        value: sqlVmName
      }
      {
        name: 'ExpectedComputerName'
        value: sqlComputerName
      }
      {
        name: 'ExpectedDisksJson'
        value: string(sqlExpectedGuestDisks)
      }
      {
        name: 'DvdLetterMoveTarget'
        value: 'Z'
      }
    ]
    timeoutInSeconds: guestDiskPreparationTimeoutInSeconds
    treatFailureAsDeploymentFailure: true
    asyncExecution: false
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the APP virtual machine.')
output appVmResourceId string = appVm.id

@description('Full ARM resource ID of the SQL virtual machine.')
output sqlVmResourceId string = sqlVm.id

@description('System-assigned managed identity principal ID of the APP virtual machine.')
output appVmPrincipalId string = appVm.identity.principalId

@description('System-assigned managed identity principal ID of the SQL virtual machine.')
output sqlVmPrincipalId string = sqlVm.identity.principalId

@description('Full ARM resource ID of the APP NIC.')
output appNicResourceId string = appNic.id

@description('Full ARM resource ID of the SQL NIC.')
output sqlNicResourceId string = sqlNic.id

@description('Full ARM resource ID of the APP application data disk.')
output appDataDiskResourceId string = appDataDisk.id

@description('Full ARM resource ID of the SQL DATA disk.')
output sqlDataDiskResourceId string = sqlDataDisk.id

@description('Full ARM resource ID of the SQL LOG disk.')
output sqlLogDiskResourceId string = sqlLogDisk.id

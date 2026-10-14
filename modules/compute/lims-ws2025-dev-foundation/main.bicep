metadata description = 'LIMS WS2025 Phase 1 compute foundation: creates the replacement APP and SQL virtual machines (Windows Server 2025 Datacenter, non-Azure Edition), their directly coupled NICs and managed disks, and the Microsoft Entra sign-in extension. Approved under the narrow LIMS WS2025 Phase 1 workload-infrastructure exception in docs/scope.md. Creates no VNet, subnet, NSG, Key Vault, Disk Encryption Set, Log Analytics workspace, DCR, Recovery Services Vault, Entra group, or any RBAC beyond the narrowly scoped VM-login exception. Installs no SQL Server, performs no application/data migration, and configures no guest drive letters — those belong to later SQL-configuration/content-migration stages.'

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

@description('Resource name of the SQL LOG disk.')
param sqlLogDiskName string

@description('Size in GiB of the SQL LOG disk.')
param sqlLogDiskSizeGiB int = 512

@description('Local administrator username for both VMs — a deployment/break-glass account only. Normal personnel access is through Microsoft Entra sign-in (see appAdministratorLoginPrincipalIds etc. below), not this account.')
@secure()
param adminUsername string

@description('Local administrator password for both VMs. Never defaulted, never present in source or parameter files — supplied as a secure deployment-time value only.')
@secure()
param adminPassword string

@description('Common tags applied to every resource in this module (e.g. environment, purpose). Each VM/disk additionally gets a role tag (application or sql) added internally — do not duplicate role here.')
param tags object = {}

@description('''Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the APP VM. Empty (default) creates no role assignment — RBAC remains prohibited by default per docs/scope.md; only the narrow VM-login exception for this workload allows populating this list, and only with existing group object IDs already authoritative outside this repository (never invented/guessed).''')
param appAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the APP VM. Same constraints as appAdministratorLoginPrincipalIds.')
param appUserLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine Administrator Login on the SQL VM. Same constraints as appAdministratorLoginPrincipalIds.')
param sqlAdministratorLoginPrincipalIds array = []

@description('Existing Entra security group object IDs to grant Virtual Machine User Login on the SQL VM. Same constraints as appAdministratorLoginPrincipalIds.')
param sqlUserLoginPrincipalIds array = []

// ─── Built-in role definition IDs (VM-login exception only — see docs/scope.md) ───
// GUIDs verified against Microsoft Learn's built-in roles reference. No other
// role is used anywhere in this module.

var vmAdministratorLoginRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
var vmUserLoginRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')

var appTags = union(tags, { role: 'application' })
var sqlTags = union(tags, { role: 'sql' })

// ─── APP: NIC, disks, VM ───────────────────────────────────────────────────────
// Dynamic private IPv4 on the existing subnet only; no public IP, no NSG created
// or attached here (subnet-level network controls are unchanged by this module).

resource appNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: appNicName
  location: location
  tags: appTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
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
    osType: 'Windows'
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
  identity: {
    type: 'SystemAssigned'
  }
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
          caching: 'None'
          createOption: 'Attach'
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
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
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
    osType: 'Windows'
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
    osType: 'Windows'
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
  identity: {
    type: 'SystemAssigned'
  }
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
          caching: 'ReadOnly'
          createOption: 'Attach'
          managedDisk: {
            id: sqlDataDisk.id
          }
        }
        {
          lun: 1
          caching: 'None'
          createOption: 'Attach'
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

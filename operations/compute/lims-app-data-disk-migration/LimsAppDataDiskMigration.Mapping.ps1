<#
    Reviewed environment mapping for LIMS APP data-disk content migration.

    This is the single source of truth for every environment this capability
    may target. The pipeline and both scripts (control-plane and guest)
    load this file; they do not duplicate per-environment implementations.

    Only an environment with Enabled = $true may be selected. DEV is the
    only enabled environment. tst, acc, preprd, and prd are present with
    the same schema so they can be onboarded by filling the reviewed
    values and flipping Enabled -- not by copying the pipeline or scripts.

    DiskEncryptionSetResourceId is the full ARM ID pin. Leave it empty
    until the live ID is recorded from a plan run; plan and stage then
    fail closed until it is filled and matches both live disks. The DES
    *name* is still required so a live ID whose last segment differs from
    the reviewed name fails even before the full ID is pinned.
#>

Set-StrictMode -Version Latest

function New-DisabledLimsAppDataDiskMigrationEnvironment {
    param([Parameter(Mandatory = $true)] [string] $EnvironmentName)

    return [pscustomobject]@{
        EnvironmentName                 = $EnvironmentName
        Enabled                         = $false
        SubscriptionId                  = ''
        Location                        = ''
        ResourceGroupName               = ''
        SourceVmName                    = ''
        SourceDataDiskName              = ''
        SourceDataDiskLun               = -1
        DestinationVmName               = ''
        DestinationComputerName         = ''
        DestinationDataDiskName         = ''
        DestinationDataDiskLun          = -1
        DestinationDriveLetter          = ''
        DestinationVolumeLabel          = ''
        PreferredTemporaryLun           = -1
        PreferredTemporaryDriveLetter   = ''
        DiskEncryptionSetName           = ''
        DiskEncryptionSetResourceId     = ''
        SnapshotNamePrefix              = ''
        TemporaryDiskNamePrefix         = ''
        ExcludeRelativePaths            = @('lv89\sdmshome')
        ReservedDriveLetters            = @('A', 'C', 'D')
        RobocopyLogDirectory            = 'C:\LimsAppMigration\logs'
    }
}

function Get-LimsAppDataDiskMigrationEnvironmentMapping {
    <#
        Returns one pscustomobject per supported environment (exactly
        dev/tst/acc/preprd/prd). Callers look up a single environment with
        Get-LimsAppDataDiskMigrationEnvironment.
    #>
    return @(
        [pscustomobject]@{
            EnvironmentName                 = 'dev'
            Enabled                         = $true
            SubscriptionId                  = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            Location                        = 'westeurope'
            ResourceGroupName               = 'rg-compute-lims-dev-westeu'
            SourceVmName                    = 'vm-lims-dev-westeu-001'
            SourceDataDiskName              = 'vmlimsdevwesteu001-v2-datadisk'
            SourceDataDiskLun               = 1
            DestinationVmName               = 'vm-lims-dev-v2-westeu-001'
            DestinationComputerName         = 'lims-dev-v2-001'
            DestinationDataDiskName         = 'appdata-vm-lims-dev-v2-westeu-001'
            DestinationDataDiskLun          = 0
            DestinationDriveLetter          = 'A'
            DestinationVolumeLabel          = 'LIMS-App'
            PreferredTemporaryLun           = 1
            PreferredTemporaryDriveLetter   = 'S'
            DiskEncryptionSetName           = 'des-lims-dev-westeu'
            # Full ARM ID is not stored in this repository (the compute-
            # foundation parameter file still uses REPLACE_WITH_REAL_VALUE).
            # Plan reports the live IDs and fails closed until this pin
            # equals both the source disk and the destination data disk.
            DiskEncryptionSetResourceId     = ''
            SnapshotNamePrefix              = 'lims-app-mig-dev'
            TemporaryDiskNamePrefix         = 'lims-app-mig-dev'
            ExcludeRelativePaths            = @('lv89\sdmshome')
            ReservedDriveLetters            = @('A', 'C', 'D')
            RobocopyLogDirectory            = 'C:\LimsAppMigration\logs'
        }
        (New-DisabledLimsAppDataDiskMigrationEnvironment -EnvironmentName 'tst')
        (New-DisabledLimsAppDataDiskMigrationEnvironment -EnvironmentName 'acc')
        (New-DisabledLimsAppDataDiskMigrationEnvironment -EnvironmentName 'preprd')
        (New-DisabledLimsAppDataDiskMigrationEnvironment -EnvironmentName 'prd')
    )
}

function Get-LimsAppDataDiskMigrationEnvironment {
    param([Parameter(Mandatory = $true)] [string] $EnvironmentName)

    $normalized = $EnvironmentName.Trim().ToLowerInvariant()
    $match = @(Get-LimsAppDataDiskMigrationEnvironmentMapping | Where-Object { $_.EnvironmentName -eq $normalized })
    if ($match.Count -ne 1) {
        throw [System.InvalidOperationException]::new("Environment '$EnvironmentName' is not a supported LIMS APP data-disk migration target. Supported environments are exactly: dev, tst, acc, preprd, prd.")
    }
    return $match[0]
}

function Get-LimsAppDataDiskMigrationLockTagKeys {
    return [pscustomobject]@{
        RunId         = 'limsAppMigLockRunId'
        SnapshotId    = 'limsAppMigSnapshotId'
        TempDiskId    = 'limsAppMigTempDiskId'
        CaptureMode   = 'limsAppMigCaptureMode'
        CopyStatus    = 'limsAppMigCopyStatus'
        TemporaryLun  = 'limsAppMigTemporaryLun'
    }
}

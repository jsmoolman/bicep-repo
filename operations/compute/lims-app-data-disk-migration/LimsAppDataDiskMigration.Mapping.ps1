<#
    Reviewed environment mapping for LIMS APP data-disk content migration.

    This is the single source of truth for every environment this capability
    may target. The pipeline and both scripts (control-plane and guest)
    load this file; they do not duplicate per-environment implementations.

    Only an environment with Enabled = $true may be selected. DEV is the
    only enabled environment. tst, acc, preprd, and prd are present with
    the same schema so they can be onboarded by filling the reviewed
    values and flipping Enabled -- not by copying the pipeline or scripts.

    DiskEncryptionSetResourceId is the full ARM ID pin. DEV is pinned to
    the customer Disk Encryption Set reported by plan #20261105.2 under
    RG-CORE-LIMS-DEV-WESTEU. Plan, attach-and-inspect, and stage fail
    closed unless that pin matches both live disks. The DES *name* is
    still required so a live ID whose last segment differs from the
    reviewed name fails even before the full ID is compared.
#>

Set-StrictMode -Version Latest

function New-LimsAppV2Configuration {
    <#
        Post-copy APP v2 configuration. Service names are reviewed.
        Wrapper paths, UNC, and JDBC/Apache/Shibboleth reviews stay empty
        or blocked until the customer records them. configure-app reports
        every missing wrapper setting, invalid path, required secret, and
        UNC/link conflict together and stops before any guest change.
    #>
    param(
        [Parameter(Mandatory = $false)] [bool] $ForEnabledEnvironment = $false
    )

    $serviceNames = @{
        JbossRunnerUserName         = ''
        JbossServiceName            = ''
        JbossServiceDisplayName     = ''
        ApacheServiceName           = ''
        ShibbolethServiceName       = ''
        AzureFilesStartupTaskName   = ''
        ConfigureGuestCommandPrefix = ''
        ActivateGuestCommandPrefix  = ''
    }
    if ($ForEnabledEnvironment) {
        $serviceNames.JbossRunnerUserName = 'jboss-runner'
        $serviceNames.JbossServiceName = 'JBoss-8.0'
        $serviceNames.JbossServiceDisplayName = 'JBoss 8.0'
        $serviceNames.ApacheServiceName = 'Apache-2.4.57'
        $serviceNames.ShibbolethServiceName = 'shibd_Default'
        $serviceNames.AzureFilesStartupTaskName = 'LIMS-AzureFiles-Sdmshome'
        $serviceNames.ConfigureGuestCommandPrefix = 'configure-lims-app-v2'
        $serviceNames.ActivateGuestCommandPrefix = 'activate-lims-app-v2'
    }

    return [pscustomobject]@{
        JbossRunnerUserName          = $serviceNames.JbossRunnerUserName
        JbossServiceName             = $serviceNames.JbossServiceName
        JbossServiceDisplayName      = $serviceNames.JbossServiceDisplayName
        JbossProcrunExePath          = ''
        JbossProcrunJvm              = ''
        JbossProcrunStartClass       = ''
        JbossProcrunStartParams      = ''
        JbossProcrunStartMode        = 'jvm'
        JbossProcrunStopClass        = ''
        JbossProcrunStopParams       = ''
        JbossProcrunClasspath        = ''
        JbossProcrunWorkingPath      = ''
        JbossProcrunLogPath          = ''
        JbossProcrunStdOutput        = ''
        JbossProcrunStdError         = ''
        ApacheServiceName            = $serviceNames.ApacheServiceName
        ApacheBinaryPath             = ''
        ApacheArguments              = ''
        ShibbolethServiceName        = $serviceNames.ShibbolethServiceName
        ShibbolethBinaryPath         = ''
        ShibbolethArguments          = ''
        JbossRunnerDirectoryPaths    = @()
        AzureFilesUnc                = ''
        AzureFilesUncReviewStatus    = 'BlockedPendingValidation'
        AzureFilesStartupTaskName    = $serviceNames.AzureFilesStartupTaskName
        SdmshomeLinkRelativePath     = 'lv89\sdmshome'
        JdbcSettingsReviewStatus     = 'BlockedPendingValidation'
        ApacheSettingsReviewStatus   = 'BlockedPendingValidation'
        ShibbolethSettingsReviewStatus = 'BlockedPendingValidation'
        ConfigureGuestCommandPrefix  = $serviceNames.ConfigureGuestCommandPrefix
        ActivateGuestCommandPrefix   = $serviceNames.ActivateGuestCommandPrefix
    }
}

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
        DestinationAttestedGuestUniqueId = ''
        TemporaryAttestedGuestUniqueId  = ''
        GuestCommandNamePrefix          = ''
        WindowsReparseValidationStatus  = 'BlockedPendingValidation'
        WindowsSymlinkValidationStatus  = 'BlockedPendingValidation'
        AppV2                           = (New-LimsAppV2Configuration)
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
            # Customer DEV pin verified by plan #20261105.2 under
            # RG-CORE-LIMS-DEV-WESTEU. Do not replace with a different
            # Disk Encryption Set.
            DiskEncryptionSetResourceId     = '/subscriptions/8ebb26a1-674a-40d1-97f8-e0a237e288a6/resourceGroups/RG-CORE-LIMS-DEV-WESTEU/providers/Microsoft.Compute/diskEncryptionSets/des-lims-dev-westeu'
            SnapshotNamePrefix              = 'lims-app-mig-dev'
            TemporaryDiskNamePrefix         = 'lims-app-mig-dev'
            ExcludeRelativePaths            = @('lv89\sdmshome')
            ReservedDriveLetters            = @('A', 'C', 'D')
            RobocopyLogDirectory            = 'C:\LimsAppMigration\logs'
            DestinationAttestedGuestUniqueId = '60022480D1B07E6ACD98417F86591F4B'
            # Snapshot-derived guest UniqueId stays empty until inspect
            # evidence is reviewed. Azure managed-disk uniqueId is not
            # this value and is not a substitute.
            TemporaryAttestedGuestUniqueId  = ''
            GuestCommandNamePrefix          = 'migrate-lims-app-data'
            # Stage/cleanup stay blocked until both the junction and the
            # directory-symbolic-link Robocopy tests have been reviewed.
            # Plan remains enabled.
            WindowsReparseValidationStatus  = 'BlockedPendingValidation'
            WindowsSymlinkValidationStatus  = 'BlockedPendingValidation'
            AppV2                           = (New-LimsAppV2Configuration -ForEnabledEnvironment $true)
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
        RunId           = 'limsAppMigLockRunId'
        SnapshotId      = 'limsAppMigSnapshotId'
        TempDiskId      = 'limsAppMigTempDiskId'
        TempDiskUniqueId = 'limsAppMigTempDiskUid'
        DestDiskUniqueId = 'limsAppMigDestDiskUid'
        CaptureMode     = 'limsAppMigCaptureMode'
        CopyStatus      = 'limsAppMigCopyStatus'
        TemporaryLun    = 'limsAppMigTemporaryLun'
        GuestCommand    = 'limsAppMigGuestCommand'
        GuestSubmitted  = 'limsAppMigGuestSubmitted'
        AttemptState    = 'limsAppMigAttemptState'
        Phase           = 'limsAppMigPhase'
        CopyCompleted   = 'limsAppMigCopyCompleted'
    }
}

function Get-LimsAppV2GuestCommandName {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [ValidateSet('Register', 'Activate')] [string] $Phase
    )
    if ($Phase -eq 'Activate') {
        return "$($Environment.AppV2.ActivateGuestCommandPrefix)-$MigrationRunId"
    }
    return "$($Environment.AppV2.ConfigureGuestCommandPrefix)-$MigrationRunId"
}

function Get-LimsAppDataDiskMigrationRunCommandName {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId
    )
    return "$($Environment.GuestCommandNamePrefix)-$MigrationRunId"
}

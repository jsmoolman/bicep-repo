<#
    Reviewed APP target identity and configuration templates for LIMS APP
    release automation.

    This file records destination identity and the APP v2 account, service,
    and Azure Files template. It does not authorize capture, deployment,
    configuration, or activation. Those actions stay refused until release
    prerequisites and exact-target checks are implemented.

    Supported environments are exactly dev, tst, acc, preprd, and prd.
    Only DEV currently carries reviewed destination identity. The other
    rows keep the same shape so a later task can fill them without copying
    the scripts.
#>

Set-StrictMode -Version Latest

function New-LimsAppV2Configuration {
    <#
        Service names for an enabled environment are reviewed. Wrapper
        paths, UNC, and JDBC/Apache/Shibboleth reviews stay empty or
        blocked until recorded from operator evidence. Preflight reports
        every gap together and the configuration workflow makes no guest
        change until that list is empty. Calling the workflow is not
        authorized by this mapping.
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
        JbossRunnerUserName            = $serviceNames.JbossRunnerUserName
        JbossServiceName               = $serviceNames.JbossServiceName
        JbossServiceDisplayName        = $serviceNames.JbossServiceDisplayName
        JbossProcrunExePath            = ''
        JbossProcrunJvm                = ''
        JbossProcrunStartClass         = ''
        JbossProcrunStartParams        = ''
        JbossProcrunStartMode          = 'jvm'
        JbossProcrunStopClass          = ''
        JbossProcrunStopParams         = ''
        JbossProcrunClasspath          = ''
        JbossProcrunWorkingPath        = ''
        JbossProcrunLogPath            = ''
        JbossProcrunStdOutput          = ''
        JbossProcrunStdError           = ''
        ApacheServiceName              = $serviceNames.ApacheServiceName
        ApacheBinaryPath               = ''
        ApacheArguments                = ''
        ShibbolethServiceName          = $serviceNames.ShibbolethServiceName
        ShibbolethBinaryPath           = ''
        ShibbolethArguments            = ''
        JbossRunnerDirectoryPaths      = @()
        AzureFilesUnc                  = ''
        AzureFilesUncReviewStatus      = 'BlockedPendingValidation'
        AzureFilesStartupTaskName      = $serviceNames.AzureFilesStartupTaskName
        SdmshomeLinkRelativePath       = 'lv89\sdmshome'
        JdbcSettingsReviewStatus       = 'BlockedPendingValidation'
        ApacheSettingsReviewStatus     = 'BlockedPendingValidation'
        ShibbolethSettingsReviewStatus = 'BlockedPendingValidation'
        ConfigureGuestCommandPrefix    = $serviceNames.ConfigureGuestCommandPrefix
        ActivateGuestCommandPrefix     = $serviceNames.ActivateGuestCommandPrefix
    }
}

function New-DisabledLimsAppReleaseEnvironment {
    param([Parameter(Mandatory = $true)] [string] $EnvironmentName)

    return [pscustomobject]@{
        EnvironmentName                  = $EnvironmentName
        Enabled                          = $false
        SubscriptionId                   = ''
        Location                         = ''
        ResourceGroupName                = ''
        DestinationVmName                = ''
        DestinationComputerName          = ''
        DestinationDataDiskName          = ''
        DestinationDataDiskLun           = -1
        DestinationDriveLetter           = ''
        DestinationVolumeLabel           = ''
        DestinationAttestedGuestUniqueId = ''
        AppV2                            = (New-LimsAppV2Configuration)
    }
}

function Get-LimsAppReleaseEnvironmentMapping {
    return @(
        [pscustomobject]@{
            EnvironmentName                  = 'dev'
            Enabled                          = $true
            SubscriptionId                   = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            Location                         = 'westeurope'
            ResourceGroupName                = 'rg-compute-lims-dev-westeu'
            DestinationVmName                = 'vm-lims-dev-v2-westeu-001'
            DestinationComputerName          = 'lims-dev-v2-001'
            DestinationDataDiskName          = 'appdata-vm-lims-dev-v2-westeu-001'
            DestinationDataDiskLun           = 0
            DestinationDriveLetter           = 'A'
            DestinationVolumeLabel           = 'LIMS-App'
            DestinationAttestedGuestUniqueId = '60022480D1B07E6ACD98417F86591F4B'
            AppV2                            = (New-LimsAppV2Configuration -ForEnabledEnvironment $true)
        }
        (New-DisabledLimsAppReleaseEnvironment -EnvironmentName 'tst')
        (New-DisabledLimsAppReleaseEnvironment -EnvironmentName 'acc')
        (New-DisabledLimsAppReleaseEnvironment -EnvironmentName 'preprd')
        (New-DisabledLimsAppReleaseEnvironment -EnvironmentName 'prd')
    )
}

function Get-LimsAppReleaseEnvironment {
    param([Parameter(Mandatory = $true)] [string] $EnvironmentName)

    $normalized = $EnvironmentName.Trim().ToLowerInvariant()
    $match = @(Get-LimsAppReleaseEnvironmentMapping | Where-Object { $_.EnvironmentName -eq $normalized })
    if ($match.Count -ne 1) {
        throw [System.InvalidOperationException]::new("Environment '$EnvironmentName' is not a supported LIMS APP release target. Supported environments are exactly: dev, tst, acc, preprd, prd.")
    }
    return $match[0]
}

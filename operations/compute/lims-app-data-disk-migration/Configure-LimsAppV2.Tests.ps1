<#
    Pester tests for Configure-LimsAppV2.ps1.

    Mocked adapters only. Covers reruns, a wrong VM, a missing secret,
    and a conflicting sdmshome link. Secrets must not appear in failure
    messages.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_APP_MIG_CONFIG_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1')
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1')
    . (Join-Path $PSScriptRoot 'Configure-LimsAppV2.ps1')
    $script:Dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
}

Describe 'reviewed DEV AppV2 mapping' {
    It 'names the reviewed local account and services and keeps wrapper paths and reviews blocked' {
        $script:Dev.AppV2.JbossRunnerUserName | Should -Be 'jboss-runner'
        $script:Dev.AppV2.JbossServiceName | Should -Be 'JBoss-8.0'
        $script:Dev.AppV2.ApacheServiceName | Should -Be 'Apache-2.4.57'
        $script:Dev.AppV2.ShibbolethServiceName | Should -Be 'shibd_Default'
        $script:Dev.AppV2.JbossProcrunExePath | Should -Be ''
        $script:Dev.AppV2.AzureFilesUnc | Should -Be ''
        $script:Dev.AppV2.AzureFilesUncReviewStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.AppV2.JdbcSettingsReviewStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.WindowsSymlinkValidationStatus | Should -Be 'BlockedPendingValidation'
    }
}

Describe 'Invoke-LimsAppV2Configure (orchestration, mocked adapters)' {
    BeforeEach {
        $script:destDiskId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/disks/$($script:Dev.DestinationDataDiskName)"
        $script:destUid = $script:Dev.DestinationAttestedGuestUniqueId
        $script:imds = [pscustomobject]@{
            subscriptionId    = $script:Dev.SubscriptionId
            resourceGroupName = $script:Dev.ResourceGroupName
            name              = $script:Dev.DestinationVmName
            storageProfile    = [pscustomobject]@{
                dataDisks = @(
                    [pscustomobject]@{ lun = 0; managedDisk = [pscustomobject]@{ id = $script:destDiskId } }
                )
            }
        }
        $script:guestDisks = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = $script:destUid; IsBoot = $false; IsSystem = $false; SizeBytes = 128GB; ScsiLogicalUnit = 0 }
        )
        $script:partitions = @(
            [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; DriveLetter = 'A' }
        )
        $script:localUsers = @{}
        $script:services = @{}
        $script:tasks = @{}
        $script:createdLinks = @{}
        $script:aclGrants = @()
        $script:logonRights = @()
        Mock Get-ActualComputerNameAdapter { return $script:Dev.DestinationComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return $script:imds }
        Mock Get-GuestDiskInventoryAdapter { return $script:guestDisks }
        Mock Get-GuestPartitionInventoryAdapter { return $script:partitions }
        Mock Get-VolumeAdapter { return [pscustomobject]@{ FileSystemLabel = 'LIMS-App' } }
        Mock Get-LocalUserAdapter { param($Name) return $script:localUsers[$Name] }
        Mock New-LocalUserAdapter { param($Name) $script:localUsers[$Name] = [pscustomobject]@{ Name = $Name } }
        Mock Set-LocalUserPasswordAdapter { param($Name) $script:localUsers[$Name] = [pscustomobject]@{ Name = $Name; Reconciled = $true } }
        Mock Grant-ServiceLogonRightAdapter { param($AccountName) $script:logonRights += $AccountName }
        Mock Grant-DirectoryModifyAclAdapter { param($Path, $AccountName) $script:aclGrants += "$AccountName|$Path" }
        Mock Get-ServiceAdapter { param($Name) return $script:services[$Name] }
        Mock Invoke-ProcessAdapter { return [pscustomobject]@{ ExitCode = 0; Command = 'ok' } }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Stop-ServiceAdapter { }
        Mock Start-ServiceAdapter { }
        Mock Get-ScheduledTaskAdapter { param($TaskName) return $script:tasks[$TaskName] }
        Mock Register-ScheduledTaskAdapter { param($TaskName) $script:tasks[$TaskName] = [pscustomobject]@{ TaskName = $TaskName; Disabled = $true } }
        Mock Enable-ScheduledTaskAdapter { }
        Mock Start-ScheduledTaskAdapter { }
        Mock Add-AzureFilesCredentialAdapter { }
        Mock Test-PathExistsAdapter { param($Path) return $script:createdLinks.ContainsKey($Path) }
        Mock Get-ItemAdapter { param($Path) return $script:createdLinks[$Path] }
        Mock New-DirectorySymbolicLinkAdapter {
            param($LinkPath, $Target)
            $script:createdLinks[$LinkPath] = [pscustomobject]@{
                PSIsContainer = $true
                Attributes    = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
                Target        = $Target
            }
        }
        $script:Params = @{
            EnvironmentName                   = 'dev'
            MigrationRunId                    = '10'
            ConfigurePhase                    = 'Register'
            ExpectedDestinationDiskResourceId = $script:destDiskId
            ExpectedDestinationDiskUniqueId   = $script:destUid
            AzureFilesUnc                     = ''
            JbossRunnerPassword               = 'NotARealPassword'
            AzureFilesAccessKey               = 'NotARealKey'
        }
    }

    It 'fails on a wrong VM before creating the local account' {
        Mock Get-ImdsComputeMetadataAdapter {
            return [pscustomobject]@{
                subscriptionId    = $script:Dev.SubscriptionId
                resourceGroupName = $script:Dev.ResourceGroupName
                name              = $script:Dev.SourceVmName
            }
        }
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*IMDS VM name*'
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Invoke-ProcessAdapter -Times 0
    }

    It 'fails on a missing secret without writing the secret name-value pair into the error' {
        $script:Params.JbossRunnerPassword = ''
        $failure = $null
        try { Invoke-LimsAppV2Configure @script:Params } catch { $failure = $_.Exception.Message }
        $failure | Should -Match 'JbossRunnerPassword'
        $failure | Should -Match 'not logged'
        $failure | Should -Not -Match 'NotARealKey'
        Should -Invoke New-LocalUserAdapter -Times 0
    }

    It 'reconciles an existing jboss-runner account on rerun' {
        $script:localUsers['jboss-runner'] = [pscustomobject]@{ Name = 'jboss-runner' }
        $failure = $null
        try { Invoke-LimsAppV2Configure @script:Params } catch { $failure = $_.Exception.Message }
        $failure | Should -Match 'Procrun settings are incomplete'
        $script:localUsers['jboss-runner'].Reconciled | Should -Be $true
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Set-LocalUserPasswordAdapter -Times 1
        Should -Invoke Grant-ServiceLogonRightAdapter -Times 1
        Should -Invoke Register-ScheduledTaskAdapter -Times 1
    }

    It 'fails when a different item occupies A:\lv89\sdmshome' {
        $clone = $script:Dev.PSObject.Copy()
        $clone.AppV2 = $script:Dev.AppV2.PSObject.Copy()
        $clone.AppV2.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $clone.AppV2.AzureFilesUncReviewStatus = 'Passed'
        $clone.AppV2.JbossProcrunExePath = 'A:\jboss\bin\prunsrv.exe'
        $clone.AppV2.JbossProcrunJvm = 'A:\java\bin\server\jvm.dll'
        $clone.AppV2.JbossProcrunStartClass = 'org.jboss.modules.Main'
        $clone.AppV2.JbossProcrunWorkingPath = 'A:\jboss'
        $clone.AppV2.ApacheBinaryPath = 'A:\Apache24\bin\httpd.exe'
        $clone.AppV2.ApacheArguments = '-k runservice'
        $clone.AppV2.ShibbolethBinaryPath = 'A:\Shibboleth\sbin\shibd.exe'
        $clone.AppV2.ShibbolethArguments = '-f A:\Shibboleth\etc\shibboleth\shibboleth2.xml -t xml'
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter {
            param($Path)
            if ($Path -like '*prunsrv.exe' -or $Path -like '*httpd.exe' -or $Path -like '*shibd.exe' -or $Path -like '*\lv89') { return $true }
            return $false
        }
        $link = 'A:\lv89\sdmshome'
        $script:createdLinks[$link] = [pscustomobject]@{
            PSIsContainer = $true
            Attributes    = [System.IO.FileAttributes]::Directory
            Target        = $null
        }
        $script:Params.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*existing directory*'
        Should -Invoke New-DirectorySymbolicLinkAdapter -Times 0
    }
}

Describe 'committed pipeline and scripts keep secrets out of source' {
    It 'references the variable group only for configure-app and never hardcodes secret values' {
        $pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\.azuredevops\pipelines\migrate-lims-app-data-disk.yml') -Raw
        $pipeline | Should -Match 'lims-dev-app-v2-secrets'
        $pipeline | Should -Match 'eq\(parameters\.action, ''configure-app''\)'
        $pipeline | Should -Match '\$\(jbossRunnerPassword\)'
        $pipeline | Should -Match '\$\(azureFilesAccessKey\)'
        $pipeline | Should -Not -Match 'jbossRunnerPassword:\s*[''"][^$]'
        $pipeline | Should -Not -Match 'azureFilesAccessKey:\s*[''"][^$]'
        $guest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Configure-LimsAppV2.ps1') -Raw
        $guest | Should -Not -Match 'NotARealPassword'
        $guest | Should -Match 'protected parameters'
    }
}

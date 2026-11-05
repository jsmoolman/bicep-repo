<#
    Pester tests for Configure-LimsAppV2.ps1.

    Mocked adapters cover preflight-before-mutation, a wrong VM, a
    missing secret, a conflicting sdmshome link, a stale scheduled-task
    result, and task-can-read / JBoss-cannot. A separate Describe
    exercises the real Register-ScheduledTask User parameter set with
    disposable credentials when the host allows it.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_APP_MIG_CONFIG_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1')
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1')
    . (Join-Path $PSScriptRoot 'Configure-LimsAppV2.ps1')
    $script:Dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'

    function New-CompleteDevEnvironment {
        $clone = $script:Dev.PSObject.Copy()
        $clone.AppV2 = $script:Dev.AppV2.PSObject.Copy()
        $clone.AppV2.JbossProcrunExePath = 'A:\jboss\bin\prunsrv.exe'
        $clone.AppV2.JbossProcrunJvm = 'A:\java\bin\server\jvm.dll'
        $clone.AppV2.JbossProcrunStartClass = 'org.jboss.modules.Main'
        $clone.AppV2.JbossProcrunWorkingPath = 'A:\jboss'
        $clone.AppV2.ApacheBinaryPath = 'A:\Apache24\bin\httpd.exe'
        $clone.AppV2.ApacheArguments = '-k runservice'
        $clone.AppV2.ShibbolethBinaryPath = 'A:\Shibboleth\sbin\shibd.exe'
        $clone.AppV2.ShibbolethArguments = '-f A:\Shibboleth\etc\shibboleth\shibboleth2.xml -t xml'
        $clone.AppV2.JbossRunnerDirectoryPaths = @('A:\jboss')
        return $clone
    }
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

Describe 'Resolve-ScheduledTaskRunAsUser (mocked adapters)' {
    It 'returns the machine-qualified name when it resolves to the local account SID' {
        Mock Get-ActualComputerNameAdapter { return 'DEVHOST' }
        Mock Get-LocalAccountSidAdapter { return 'S-1-5-21-1-2-3-1001' }
        Mock Resolve-AccountSidAdapter { param($QualifiedName) if ($QualifiedName -eq 'DEVHOST\jboss-runner') { return 'S-1-5-21-1-2-3-1001' } return '' }
        Resolve-ScheduledTaskRunAsUser -UserName '.\jboss-runner' | Should -Be 'DEVHOST\jboss-runner'
    }

    It 'stops when the machine-qualified name resolves to a different SID' {
        Mock Get-ActualComputerNameAdapter { return 'DEVHOST' }
        Mock Get-LocalAccountSidAdapter { return 'S-1-5-21-1-2-3-1001' }
        Mock Resolve-AccountSidAdapter { return 'S-1-5-21-9-9-9-9' }
        { Resolve-ScheduledTaskRunAsUser -UserName '.\jboss-runner' } | Should -Throw -ExpectedMessage '*different SID*'
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
        Mock Register-ScheduledTaskAdapter { param($TaskName, $Disabled) $script:tasks[$TaskName] = [pscustomobject]@{ TaskName = $TaskName; Disabled = $Disabled } }
        Mock Enable-ScheduledTaskAdapter { }
        Mock Disable-ScheduledTaskAdapter { param($TaskName) if ($script:tasks.ContainsKey($TaskName)) { $script:tasks[$TaskName].Disabled = $true } }
        Mock Start-ScheduledTaskAdapter { }
        Mock Get-ScheduledTaskInfoAdapter { return [pscustomobject]@{ LastRunTime = [datetime]::MinValue; LastTaskResult = 0x41301 } }
        Mock Get-UtcNowAdapter { return [datetime]::Parse('2026-11-05T04:00:00Z').ToUniversalTime() }
        Mock Wait-FreshScheduledTaskResultAdapter { return [pscustomobject]@{ Fresh = $true; Succeeded = $true; Reason = $null } }
        Mock Get-ServiceProcessIdAdapter { return 4242 }
        Mock Test-PathReadAsProcessAdapter { return [pscustomobject]@{ Readable = $true; Reason = $null } }
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

    It 'rejects Azure managed-disk uniqueId as destination guest identity' {
        $script:Params.ExpectedDestinationDiskUniqueId = 'ARM-DEST-UID-NOT-GUEST'
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*Azure managed-disk uniqueId is not accepted*'
        Should -Invoke New-LocalUserAdapter -Times 0
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
        $failure | Should -Match 'Preflight failed before any guest change'
        $failure | Should -Match 'JbossRunnerPassword'
        $failure | Should -Match 'not logged'
        $failure | Should -Match 'Procrun'
        $failure | Should -Not -Match 'NotARealKey'
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Register-ScheduledTaskAdapter -Times 0
        Should -Invoke Invoke-ProcessAdapter -Times 0
    }

    It 'reports every missing wrapper setting and does not mutate on rerun when preflight fails' {
        $script:localUsers['jboss-runner'] = [pscustomobject]@{ Name = 'jboss-runner' }
        $failure = $null
        try { Invoke-LimsAppV2Configure @script:Params } catch { $failure = $_.Exception.Message }
        $failure | Should -Match 'Preflight failed before any guest change'
        $failure | Should -Match 'Procrun settings are incomplete'
        $failure | Should -Match 'Apache-2.4.57'
        $failure | Should -Match 'shibd_Default'
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Set-LocalUserPasswordAdapter -Times 0
        Should -Invoke Register-ScheduledTaskAdapter -Times 0
        Should -Invoke Invoke-ProcessAdapter -Times 0
    }

    It 'reconciles an existing jboss-runner account on rerun after preflight passes' {
        $clone = New-CompleteDevEnvironment
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter {
            param($Path)
            if ($Path -eq 'A:\lv89\sdmshome') { return $script:createdLinks.ContainsKey($Path) }
            return $true
        }
        $script:localUsers['jboss-runner'] = [pscustomobject]@{ Name = 'jboss-runner' }
        $null = Invoke-LimsAppV2Configure @script:Params
        $script:localUsers['jboss-runner'].Reconciled | Should -Be $true
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Set-LocalUserPasswordAdapter -Times 1
        Should -Invoke Grant-ServiceLogonRightAdapter -Times 1
        Should -Invoke Register-ScheduledTaskAdapter -Times 1 -ParameterFilter { $Disabled -eq $true }
    }

    It 'provisions the Azure Files credential as jboss-runner and registers the task disabled' {
        $clone = New-CompleteDevEnvironment
        $clone.AppV2.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $clone.AppV2.AzureFilesUncReviewStatus = 'Passed'
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter {
            param($Path)
            return $Path -ne 'A:\lv89\sdmshome'
        }
        $script:Params.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $null = Invoke-LimsAppV2Configure @script:Params
        Should -Invoke Add-AzureFilesCredentialAdapter -Times 1 -ParameterFilter { $RunAsUserName -eq '.\jboss-runner' -and $Target -eq 'limsdevfiles.file.core.windows.net' }
        Should -Invoke Register-ScheduledTaskAdapter -Times 1 -ParameterFilter { $Disabled -eq $true -and $UserName -eq '.\jboss-runner' }
        Should -Invoke New-DirectorySymbolicLinkAdapter -Times 1
        Should -Invoke Enable-ScheduledTaskAdapter -Times 0
    }

    It 'fails when a different item occupies A:\lv89\sdmshome and does not mutate' {
        $clone = New-CompleteDevEnvironment
        $clone.AppV2.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $clone.AppV2.AzureFilesUncReviewStatus = 'Passed'
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter {
            param($Path)
            if ($Path -eq 'A:\lv89\sdmshome') { return $true }
            return $true
        }
        $link = 'A:\lv89\sdmshome'
        $script:createdLinks[$link] = [pscustomobject]@{
            PSIsContainer = $true
            Attributes    = [System.IO.FileAttributes]::Directory
            Target        = $null
        }
        $script:Params.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*existing directory*'
        Should -Invoke New-LocalUserAdapter -Times 0
        Should -Invoke Register-ScheduledTaskAdapter -Times 0
        Should -Invoke New-DirectorySymbolicLinkAdapter -Times 0
        Should -Invoke Add-AzureFilesCredentialAdapter -Times 0
    }

    It 'refuses a stale scheduled-task result, leaves JBoss stopped, and restores the task to disabled' {
        $clone = New-CompleteDevEnvironment
        $clone.AppV2.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $clone.AppV2.AzureFilesUncReviewStatus = 'Passed'
        $clone.AppV2.JdbcSettingsReviewStatus = 'Passed'
        $clone.AppV2.ApacheSettingsReviewStatus = 'Passed'
        $clone.AppV2.ShibbolethSettingsReviewStatus = 'Passed'
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter { return $true }
        $link = 'A:\lv89\sdmshome'
        $script:createdLinks[$link] = [pscustomobject]@{
            PSIsContainer = $true
            Attributes    = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
            Target        = '\\limsdevfiles.file.core.windows.net\lv89'
        }
        $script:tasks['LIMS-AzureFiles-Sdmshome'] = [pscustomobject]@{ TaskName = 'LIMS-AzureFiles-Sdmshome'; Disabled = $true }
        $script:services['JBoss-8.0'] = [pscustomobject]@{ Name = 'JBoss-8.0'; Status = 'Stopped' }
        Mock Wait-FreshScheduledTaskResultAdapter {
            return [pscustomobject]@{ Fresh = $false; Succeeded = $false; Reason = 'Scheduled-task LastRunTime was not updated for this attempt. Refusing to accept a stale result.' }
        }
        $script:Params.ConfigurePhase = 'Activate'
        $script:Params.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*stale*'
        Should -Invoke Start-ServiceAdapter -Times 0
        Should -Invoke Enable-ScheduledTaskAdapter -Times 0
        Should -Invoke Disable-ScheduledTaskAdapter -Times 1
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 0
    }

    It 'leaves JBoss stopped and restores the task when the task can read the share but JBoss cannot' {
        $clone = New-CompleteDevEnvironment
        $clone.AppV2.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        $clone.AppV2.AzureFilesUncReviewStatus = 'Passed'
        $clone.AppV2.JdbcSettingsReviewStatus = 'Passed'
        $clone.AppV2.ApacheSettingsReviewStatus = 'Passed'
        $clone.AppV2.ShibbolethSettingsReviewStatus = 'Passed'
        Mock Get-LimsAppDataDiskMigrationEnvironment { return $clone }
        Mock Test-PathExistsAdapter { return $true }
        $link = 'A:\lv89\sdmshome'
        $script:createdLinks[$link] = [pscustomobject]@{
            PSIsContainer = $true
            Attributes    = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
            Target        = '\\limsdevfiles.file.core.windows.net\lv89'
        }
        $script:tasks['LIMS-AzureFiles-Sdmshome'] = [pscustomobject]@{ TaskName = 'LIMS-AzureFiles-Sdmshome'; Disabled = $true }
        $script:services['JBoss-8.0'] = [pscustomobject]@{ Name = 'JBoss-8.0'; Status = 'Stopped' }
        Mock Start-ServiceAdapter { $script:services['JBoss-8.0'].Status = 'Running' }
        Mock Stop-ServiceAdapter { $script:services['JBoss-8.0'].Status = 'Stopped' }
        Mock Get-ServiceAdapter { param($Name) return $script:services[$Name] }
        Mock Test-PathReadAsProcessAdapter { return [pscustomobject]@{ Readable = $false; Reason = "JBoss service context cannot read '$link'." } }
        $script:Params.ConfigurePhase = 'Activate'
        $script:Params.AzureFilesUnc = '\\limsdevfiles.file.core.windows.net\lv89'
        { Invoke-LimsAppV2Configure @script:Params } | Should -Throw -ExpectedMessage '*JBoss service context cannot read*'
        $script:services['JBoss-8.0'].Status | Should -Be 'Stopped'
        $script:tasks['LIMS-AzureFiles-Sdmshome'].Disabled | Should -Be $true
        Should -Invoke Enable-ScheduledTaskAdapter -Times 0
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 0
    }
}

Describe 'committed pipeline and scripts keep secrets out of source' {
    It 'references the variable group only for configure-app and never hardcodes secret values' {
        $pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\.azuredevops\pipelines\migrate-lims-app-data-disk.yml') -Raw
        $pipeline | Should -Match 'lims-dev-app-v2-secrets'
        $pipeline | Should -Match '(?m)^\s+default: ''auto'''
        $pipeline | Should -Match '(?m)^\s+default: ''not-used'''
        $pipeline | Should -Match 'eq\(parameters\.action, ''configure-app''\)'
        $pipeline | Should -Match '\$\(jbossRunnerPassword\)'
        $pipeline | Should -Match '\$\(azureFilesAccessKey\)'
        $pipeline | Should -Not -Match 'jbossRunnerPassword:\s*[''"][^$]'
        $pipeline | Should -Not -Match 'azureFilesAccessKey:\s*[''"][^$]'
        $guest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Configure-LimsAppV2.ps1') -Raw
        $guest | Should -Not -Match 'NotARealPassword'
        $guest | Should -Match 'protected parameters'
        $guest | Should -Match 'Register-ScheduledTask -TaskName \$TaskName -Action \$action -Trigger \$trigger -Settings \$settings -User \$resolvedUser -Password \$Password -RunLevel Highest -Force'
        $guest | Should -Not -Match 'Register-ScheduledTask[^\r\n]*-Principal'
        $guest | Should -Match 'LoadUserProfile'
        $guest | Should -Match 'RunAsUserName'
        $guest | Should -Not -Match '/pass:\$AccessKey[^\r\n]*Write-Host'
    }
}

Describe 'Real Windows Register-ScheduledTask (User parameter set)' {
    It 'registers a disabled startup task with disposable credentials' {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Set-ItResult -Skipped -Because 'Administrator is required to create a disposable local user and call Register-ScheduledTask. Mocked tests already cover the orchestration; this host did not exercise the real cmdlet.'
            return
        }
        $taskName = 'lims-app-v2-task-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $userName = 'limsT' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $plain = 'Tmp!' + [guid]::NewGuid().ToString('N')
        $createdUser = $false
        try {
            $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
            New-LocalUser -Name $userName -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
            $createdUser = $true
            $expectedSid = [string](Get-LocalUser -Name $userName).SID.Value
            Register-ScheduledTaskAdapter -TaskName $taskName -UserName ".\$userName" -Password $plain -Command 'powershell.exe' -Arguments '-NoProfile -NonInteractive -Command "exit 0"' -Disabled $true
            $task = Get-ScheduledTask -TaskName $taskName
            $task.Settings.Enabled | Should -Be $false
            $task.Principal.LogonType | Should -Be 'Password'
            $task.Principal.UserId | Should -Match ([regex]::Escape($userName))
            $taskSid = (New-Object System.Security.Principal.NTAccount($task.Principal.UserId)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $taskSid | Should -Be $expectedSid
        }
        finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            if ($createdUser) { Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue }
        }
    }
}

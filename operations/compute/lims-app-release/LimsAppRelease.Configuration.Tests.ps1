<#
    Plain-data tests for retained APP release decisions.

    Guest disk identity, preflight, link, and scheduled-task checks are
    exercised directly. No Azure call, Robocopy, or guest command runs.
#>

Set-StrictMode -Version Latest

BeforeAll {
    . (Join-Path $PSScriptRoot 'LimsAppRelease.Mapping.ps1')
    . (Join-Path $PSScriptRoot 'LimsAppRelease.Configuration.ps1')
}
Describe 'Resolve-GuestDiskIdentity and Test-DriveLetterOnResolvedDisk' {
    BeforeAll {
        $script:destId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/appdata'
        $script:tempId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/tmp'
        $script:attested = '60022480D1B07E6ACD98417F86591F4B'
        # DEV evidence: IMDS resourceDisk.size is 201728 kB; the Windows
        # temporary disk is 161059207680 bytes. They must not be required
        # to match in order to identify A: or the snapshot disk.
        $script:imdsResourceDiskSizeKb = 201728
        $script:windowsTempDiskBytes = [int64]161059207680
        $script:imds = [pscustomobject]@{
            storageProfile = [pscustomobject]@{
                resourceDisk = [pscustomobject]@{ size = $script:imdsResourceDiskSizeKb }
                dataDisks    = @(
                    [pscustomobject]@{ lun = 0; managedDisk = [pscustomobject]@{ id = $script:destId } }
                    [pscustomobject]@{ lun = 1; managedDisk = [pscustomobject]@{ id = $script:tempId } }
                )
            }
        }
        $script:guestDisks = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = $script:attested; IsBoot = $false; IsSystem = $false; SizeBytes = 128GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 2; UniqueId = 'TEMPDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = 128GB; ScsiLogicalUnit = 1 }
            [pscustomobject]@{ Number = 3; UniqueId = 'RESOURCEDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = $script:windowsTempDiskBytes; ScsiLogicalUnit = 1 }
        )
    }

    It 'does not treat the DEV IMDS resource-disk size as a match for the Windows temporary disk' {
        $imdsBytes = Get-ImdsResourceDiskSizeBytes -ImdsCompute $script:imds
        $imdsBytes | Should -Be ([int64]$script:imdsResourceDiskSizeKb * 1024)
        $imdsBytes | Should -Not -Be $script:windowsTempDiskBytes
        @($script:guestDisks | Where-Object { [int64]$_.SizeBytes -eq $imdsBytes }).Count | Should -Be 0
    }

    It 'resolves destination A: by attested UniqueId even when ARM uniqueId differs, and does not treat ARM uniqueId as guest identity' {
        $dest = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId $script:attested -Role 'Destination A:' -ArmUniqueId 'ARM-DEST-UID-NOT-GUEST'
        $dest.Resolved | Should -Be $true
        $dest.Disk.Number | Should -Be 1
        $dest.Disk.UniqueId | Should -Be $script:attested
        $sameAsArm = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId 'ARM-TEMP-UID' -Role 'Temporary snapshot disk' -ArmUniqueId 'ARM-TEMP-UID'
        $sameAsArm.Resolved | Should -Be $false
        $sameAsArm.Reason | Should -Match 'not be treated as Windows UniqueId'
        $unproven = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId '' -Role 'Temporary snapshot disk' -ArmUniqueId 'ARM-TEMP-UID'
        $unproven.Resolved | Should -Be $false
        $unproven.Reason | Should -Match 'no reviewed Windows UniqueId'
        $unproven.Reason | Should -Match 'Inventory:'
        $temp = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId 'TEMPDISK' -Role 'Temporary snapshot disk' -ArmUniqueId 'ARM-TEMP-UID'
        $temp.Resolved | Should -Be $true
        $temp.Disk.Number | Should -Be 2
        $temp.Disk.ScsiLogicalUnit | Should -Be 1
    }

    It 'fails when A: is on a different Windows disk even if the volume label matches' {
        $partitions = @(
            [pscustomobject]@{ DiskNumber = 9; PartitionNumber = 2; DriveLetter = 'A' }
        )
        $result = Test-DriveLetterOnResolvedDisk -DriveLetter 'A' -ExpectedDiskNumber 1 -Partitions $partitions -ExpectedLabel 'LIMS-App' -VolumeLabel 'LIMS-App' -Role 'Destination A:'
        $result.Matches | Should -Be $false
        $result.Reason | Should -Match 'not the resolved managed disk'
        $result.Reason | Should -Match 'matching volume label or letter is insufficient'
    }

    It 'still resolves the snapshot disk when another non-OS disk shares SCSI LUN 1, as long as UniqueId is unique' {
        $dupes = $script:guestDisks + [pscustomobject]@{ Number = 4; UniqueId = 'OTHERTEMP'; IsBoot = $false; IsSystem = $false; SizeBytes = 256GB; ScsiLogicalUnit = 1 }
        $result = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $dupes -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId 'TEMPDISK' -Role 'Temporary snapshot disk'
        $result.Resolved | Should -Be $true
        $result.Disk.Number | Should -Be 2
    }

    It 'dumps inventory and stops when no UniqueId was supplied' {
        $result = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId '' -Role 'Destination A:'
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Match 'no reviewed Windows UniqueId'
        $result.Reason | Should -Match 'Inventory:'
        $result.Reason | Should -Match $script:attested
    }

    It 'dumps inventory when the expected UniqueId is not present on any non-OS disk' {
        $empty = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = ''; IsBoot = $false; IsSystem = $false; SizeBytes = 128GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 3; UniqueId = 'RESOURCEDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = $script:windowsTempDiskBytes; ScsiLogicalUnit = 1 }
        )
        $result = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $empty -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId $script:attested -Role 'Destination A:'
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Match 'resolved to 0 guest disk'
        $result.Reason | Should -Match 'Inventory:'
    }
}

Describe 'APP v2 configuration safety decisions' {
    It 'reports a missing secret without echoing the value' {
        $missing = Test-LimsAppV2SecretPresent -Name 'JbossRunnerPassword' -Value ''
        $missing.Present | Should -Be $false
        $missing.Reason | Should -Match 'JbossRunnerPassword'
        $missing.Reason | Should -Not -Match 'hunter2'
        (Test-LimsAppV2SecretPresent -Name 'JbossRunnerPassword' -Value 'hunter2').Present | Should -Be $true
        (Test-TextContainsSecret -Text 'log hunter2 leaked' -Secret 'hunter2') | Should -Be $true
        (Test-TextContainsSecret -Text 'log redacted' -Secret 'hunter2') | Should -Be $false
    }

    It 'reports incomplete Apache or Shibboleth binary settings before a service change' {
        $incomplete = Test-LimsAppV2ServiceBinarySettingsComplete -ServiceName 'Apache-2.4.57' -BinaryPath '' -Arguments ''
        $incomplete.Complete | Should -Be $false
        $incomplete.Missing | Should -Contain 'BinaryPath'
        $incomplete.Missing | Should -Contain 'Arguments'
        $incomplete.Reason | Should -Match 'before changing the service'
        (Test-LimsAppV2ServiceBinarySettingsComplete -ServiceName 'Apache-2.4.57' -BinaryPath 'A:\Apache24\bin\httpd.exe' -Arguments '-k runservice').Complete | Should -Be $true
    }

    It 'reports incomplete Procrun settings before a service change' {
        $dev = Get-LimsAppReleaseEnvironment -EnvironmentName 'dev'
        $incomplete = Test-LimsAppV2ProcrunSettingsComplete -AppV2 $dev.AppV2
        $incomplete.Complete | Should -Be $false
        $incomplete.Missing | Should -Contain 'JbossProcrunExePath'
        $incomplete.Reason | Should -Match 'before changing service'
        $complete = $dev.AppV2.PSObject.Copy()
        $complete.JbossProcrunExePath = 'A:\jboss\bin\prunsrv.exe'
        $complete.JbossProcrunJvm = 'A:\java\bin\server\jvm.dll'
        $complete.JbossProcrunStartClass = 'org.jboss.modules.Main'
        $complete.JbossProcrunWorkingPath = 'A:\jboss'
        (Test-LimsAppV2ProcrunSettingsComplete -AppV2 $complete).Complete | Should -Be $true
    }

    It 'reuses an exact sdmshome link and fails on a file, directory, or different target' {
        $unc = '\\limsfiles.file.core.windows.net\lv89'
        (Test-SdmshomeLinkDecision -PathExists $false -IsReparsePoint $false -ExistingTarget '' -ExpectedTarget $unc).Action | Should -Be 'Create'
        (Test-SdmshomeLinkDecision -PathExists $true -IsReparsePoint $true -ExistingTarget $unc -ExpectedTarget $unc).Action | Should -Be 'Reuse'
        $wrong = Test-SdmshomeLinkDecision -PathExists $true -IsReparsePoint $true -ExistingTarget '\\other\share' -ExpectedTarget $unc
        $wrong.Action | Should -Be 'Fail'
        $file = Test-SdmshomeLinkDecision -PathExists $true -IsReparsePoint $false -ExistingTarget '' -ExpectedTarget $unc -IsFile $true
        $file.Action | Should -Be 'Fail'
        $dir = Test-SdmshomeLinkDecision -PathExists $true -IsReparsePoint $false -ExistingTarget '' -ExpectedTarget $unc -IsDirectory $true
        $dir.Action | Should -Be 'Fail'
    }

    It 'refuses release actions and does not define a snapshot-copy completion gate' {
        foreach ($action in @('configure', 'activate', 'capture', 'deploy')) {
            $decision = Get-LimsAppReleaseExecutionDecision -Action $action
            $decision.Allowed | Should -Be $false
            $decision.Reason | Should -Match 'snapshot-copy completion marker is not authorization'
        }
        Get-Command Test-CopyCompletedForConfigure -ErrorAction SilentlyContinue | Should -Be $null
    }

    It 'keeps automatic startup blocked while JDBC, Apache, Shibboleth, or UNC reviews are pending' {
        $dev = Get-LimsAppReleaseEnvironment -EnvironmentName 'dev'
        $pending = Test-LimsAppV2ActivationReviews -AppV2 $dev.AppV2
        $pending.Passed | Should -Be $false
        $ready = $dev.AppV2.PSObject.Copy()
        $ready.JdbcSettingsReviewStatus = 'Passed'
        $ready.ApacheSettingsReviewStatus = 'Passed'
        $ready.ShibbolethSettingsReviewStatus = 'Passed'
        $ready.AzureFilesUncReviewStatus = 'Passed'
        (Test-LimsAppV2ActivationReviews -AppV2 $ready).Passed | Should -Be $true
    }

    It 'collects missing secrets, wrapper settings, invalid paths, and a link conflict before any mutation' {
        $dev = Get-LimsAppReleaseEnvironment -EnvironmentName 'dev'
        $empty = Get-LimsAppV2RegisterPreflight -Environment $dev -JbossRunnerPassword '' -AzureFilesAccessKey 'NotARealKey' -AzureFilesUnc '' -PathExists @{}
        $empty.Allowed | Should -Be $false
        $empty.Reason | Should -Match 'JbossRunnerPassword'
        $empty.Reason | Should -Match 'Procrun'
        $empty.Reason | Should -Match 'Apache-2.4.57'
        $empty.Reason | Should -Match 'shibd_Default'
        $empty.Reason | Should -Match 'application-directory'
        $empty.Reason | Should -Not -Match 'NotARealKey'

        $ready = $dev.PSObject.Copy()
        $ready.AppV2 = $dev.AppV2.PSObject.Copy()
        $ready.AppV2.JbossProcrunExePath = 'A:\jboss\bin\prunsrv.exe'
        $ready.AppV2.JbossProcrunJvm = 'A:\java\bin\server\jvm.dll'
        $ready.AppV2.JbossProcrunStartClass = 'org.jboss.modules.Main'
        $ready.AppV2.JbossProcrunWorkingPath = 'A:\jboss'
        $ready.AppV2.ApacheBinaryPath = 'A:\Apache24\bin\httpd.exe'
        $ready.AppV2.ApacheArguments = '-k runservice'
        $ready.AppV2.ShibbolethBinaryPath = 'A:\Shibboleth\sbin\shibd.exe'
        $ready.AppV2.ShibbolethArguments = '-f A:\Shibboleth\etc\shibboleth\shibboleth2.xml'
        $ready.AppV2.JbossRunnerDirectoryPaths = @('A:\jboss')
        $ready.AppV2.AzureFilesUnc = '\\limsfiles.file.core.windows.net\lv89'
        $ready.AppV2.AzureFilesUncReviewStatus = 'Passed'
        $paths = @{
            'A:\jboss\bin\prunsrv.exe' = $true
            'A:\java\bin\server\jvm.dll' = $true
            'A:\jboss' = $true
            'A:\Apache24\bin\httpd.exe' = $true
            'A:\Shibboleth\sbin\shibd.exe' = $true
        }
        $conflict = [pscustomobject]@{
            ParentExists   = $true
            Exists         = $true
            IsReparsePoint = $false
            IsDirectory    = $true
            IsFile         = $false
            Target         = ''
        }
        $blocked = Get-LimsAppV2RegisterPreflight -Environment $ready -JbossRunnerPassword 'pw' -AzureFilesAccessKey 'key' -AzureFilesUnc '\\limsfiles.file.core.windows.net\lv89' -PathExists $paths -LinkObservation $conflict
        $blocked.Allowed | Should -Be $false
        $blocked.Reason | Should -Match 'existing directory'
        (Get-LimsAppV2RegisterPreflight -Environment $ready -JbossRunnerPassword 'pw' -AzureFilesAccessKey 'key' -AzureFilesUnc '\\limsfiles.file.core.windows.net\lv89' -PathExists $paths -LinkObservation ([pscustomobject]@{
                    ParentExists = $true; Exists = $false; IsReparsePoint = $false; IsDirectory = $false; IsFile = $false; Target = ''
                })).Allowed | Should -Be $true
    }

    It 'accepts a machine-qualified task user only when it resolves to the local account SID' {
        $sid = 'S-1-5-21-1-2-3-1001'
        (Test-ScheduledTaskUserResolution -SamAccountName 'jboss-runner' -Candidate 'HOST\jboss-runner' -ExpectedSid $sid -ResolvedSid $sid).Accepted | Should -Be $true
        $missing = Test-ScheduledTaskUserResolution -SamAccountName 'jboss-runner' -Candidate 'HOST\jboss-runner' -ExpectedSid '' -ResolvedSid $sid
        $missing.Accepted | Should -Be $false
        $missing.Reason | Should -Match 'SID was not found'
        $unresolved = Test-ScheduledTaskUserResolution -SamAccountName 'jboss-runner' -Candidate 'HOST\jboss-runner' -ExpectedSid $sid -ResolvedSid ''
        $unresolved.Accepted | Should -Be $false
        $unresolved.Reason | Should -Match 'did not resolve'
        $other = Test-ScheduledTaskUserResolution -SamAccountName 'jboss-runner' -Candidate 'HOST\jboss-runner' -ExpectedSid $sid -ResolvedSid 'S-1-5-21-9-9-9-9'
        $other.Accepted | Should -Be $false
        $other.Reason | Should -Match 'different SID'
        (Get-ScheduledTaskSamAccountName -UserName '.\jboss-runner') | Should -Be 'jboss-runner'
        (Get-ScheduledTaskSamAccountName -UserName 'HOST\jboss-runner') | Should -Be 'jboss-runner'
    }

    It 'rejects a stale scheduled-task LastRunTime even when LastTaskResult is 0' {
        $started = [datetime]::Parse('2026-11-05T03:00:00Z').ToUniversalTime()
        $stale = [datetime]::Parse('2026-11-05T02:00:00Z').ToUniversalTime()
        $same = Test-LimsAppV2ScheduledTaskResultIsFresh -AttemptStartedUtc $started -PreviousLastRunTime $stale -CurrentLastRunTime $stale -LastTaskResult 0
        $same.Fresh | Should -Be $false
        $same.Reason | Should -Match 'stale'
        $freshFail = Test-LimsAppV2ScheduledTaskResultIsFresh -AttemptStartedUtc $started -PreviousLastRunTime $stale -CurrentLastRunTime $started.AddSeconds(5) -LastTaskResult 2
        $freshFail.Fresh | Should -Be $true
        $freshFail.Succeeded | Should -Be $false
        $ok = Test-LimsAppV2ScheduledTaskResultIsFresh -AttemptStartedUtc $started -PreviousLastRunTime $stale -CurrentLastRunTime $started.AddSeconds(5) -LastTaskResult 0
        $ok.Fresh | Should -Be $true
        $ok.Succeeded | Should -Be $true
    }

    It 'creates the sdmshome link only when the supplied UNC is reviewed and matches the mapping' {
        $dev = Get-LimsAppReleaseEnvironment -EnvironmentName 'dev'
        $skip = Test-AzureFilesUncReadyForLink -SuppliedUnc '' -AppV2 $dev.AppV2
        $skip.Skip | Should -Be $true
        $placeholder = Test-AzureFilesUncReadyForLink -SuppliedUnc 'not-used' -AppV2 $dev.AppV2
        $placeholder.Ready | Should -Be $false
        $placeholder.Skip | Should -Be $false
        $placeholder.Reason | Should -Match 'not-used'
        $unreviewed = Test-AzureFilesUncReadyForLink -SuppliedUnc '\\limsfiles.file.core.windows.net\lv89' -AppV2 $dev.AppV2
        $unreviewed.Ready | Should -Be $false
        $unreviewed.Skip | Should -Be $false
        $reviewed = $dev.AppV2.PSObject.Copy()
        $reviewed.AzureFilesUnc = '\\limsfiles.file.core.windows.net\lv89'
        $reviewed.AzureFilesUncReviewStatus = 'Passed'
        (Test-AzureFilesUncReadyForLink -SuppliedUnc '\\limsfiles.file.core.windows.net\lv89' -AppV2 $reviewed).Ready | Should -Be $true
        $mismatch = Test-AzureFilesUncReadyForLink -SuppliedUnc '\\other.file.core.windows.net\lv89' -AppV2 $reviewed
        $mismatch.Ready | Should -Be $false
        $mismatch.Reason | Should -Not -Match 'other.file'
    }
}

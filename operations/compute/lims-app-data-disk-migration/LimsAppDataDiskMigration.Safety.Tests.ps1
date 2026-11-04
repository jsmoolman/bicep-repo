<#
    Pester tests for LimsAppDataDiskMigration.Safety.ps1.

    Pure functions only. Mocked/in-memory on Ubuntu CI. Distinguishes
    nothing Azure-live; no az, no IMDS, no Robocopy.
#>

Set-StrictMode -Version Latest

BeforeAll {
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1')
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1')
}

Describe 'Test-LimsAppMigNumericBuildId' {
    It 'accepts a numeric Azure DevOps Build.BuildId' {
        (Test-LimsAppMigNumericBuildId -Value '12345').Accepted | Should -Be $true
    }

    It 'rejects quotes, newlines, shell metacharacters, and Azure DevOps logging-command text' {
        foreach ($bad in @(
                '',
                '"123"',
                "'123'",
                "12`n3",
                "12`r3",
                '12;rm -rf /',
                '12$(whoami)',
                '12`whoami`',
                '12 && echo pwned',
                '12|tee',
                '##vso[task.setvariable variable=x]1',
                '12##vso[task.logissue]x',
                'abc',
                '-1',
                '12.0',
                ' 12'
            )) {
            $result = Test-LimsAppMigNumericBuildId -Value $bad
            $result.Accepted | Should -Be $false
        }
    }
}

Describe 'Resolve-LimsAppMigPipelineRunId' {
    It 'lets plan run with an empty run ID' {
        $result = Resolve-LimsAppMigPipelineRunId -Action 'plan' -SuppliedRunId '' -BuildId '99'
        $result.Accepted | Should -Be $true
        $result.RunId | Should -Be ''
    }

    It 'rejects a hostile plan run ID before it can be published' {
        $result = Resolve-LimsAppMigPipelineRunId -Action 'plan' -SuppliedRunId '1; echo ##vso[task.setvariable variable=x]1' -BuildId '99'
        $result.Accepted | Should -Be $false
        $result.Reason | Should -Match 'logging-command|numeric|non-printable|newline'
    }

    It 'requires cleanup to supply the original numeric Build.BuildId and never falls back to the current build' {
        $empty = Resolve-LimsAppMigPipelineRunId -Action 'cleanup' -SuppliedRunId '' -BuildId '99'
        $empty.Accepted | Should -Be $false
        $ok = Resolve-LimsAppMigPipelineRunId -Action 'cleanup' -SuppliedRunId '42' -BuildId '99'
        $ok.Accepted | Should -Be $true
        $ok.RunId | Should -Be '42'
    }

    It 'uses the current Build.BuildId for stage when none is supplied' {
        $result = Resolve-LimsAppMigPipelineRunId -Action 'stage' -SuppliedRunId '' -BuildId '77'
        $result.Accepted | Should -Be $true
        $result.RunId | Should -Be '77'
    }
}

Describe 'Get-AzureCliErrorClassification' {
    It 'classifies authorization before a 404-looking body' {
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'AuthorizationFailed (403) Resource not found') | Should -Be 'Authorization'
        (Get-AzureCliErrorClassification -ExitCode 1 -Text '(401) InvalidAuthenticationToken') | Should -Be 'Authorization'
    }

    It 'classifies confirmed not-found separately from network and other failures' {
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'ResourceNotFound (404) The Resource was not found') | Should -Be 'NotFound'
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'ERROR: HTTPSConnectionPool timed out') | Should -Be 'Network'
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'Temporary failure in name resolution') | Should -Be 'Network'
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'Something unexpected exploded') | Should -Be 'Other'
        (Get-AzureCliErrorClassification -ExitCode 0 -Text '{}') | Should -Be 'Found'
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'ConflictError (409) A disk with this name already exists') | Should -Be 'AlreadyExists'
    }
}

Describe 'Get-MigrationLockAcquireDecision' {
    It 'allows a first stage acquire, refuses overlapping stage even with the same run ID, and lets cleanup of the holding run proceed' {
        (Get-MigrationLockAcquireDecision -ExistingLockRunId '' -ThisRunId '10' -Purpose 'Stage').Allowed | Should -Be $true
        $sameIdStage = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '10' -Purpose 'Stage'
        $sameIdStage.Allowed | Should -Be $false
        $sameIdStage.Reason | Should -Match 'same run ID'
        $cleanup = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '10' -Purpose 'Cleanup'
        $cleanup.Allowed | Should -Be $true
        $cleanup.Resume | Should -Be $true
        $concurrent = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '11' -Purpose 'Stage'
        $concurrent.Allowed | Should -Be $false
        $concurrent.Reason | Should -Match 'concurrent'
        $concurrentCleanup = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '11' -Purpose 'Cleanup'
        $concurrentCleanup.Allowed | Should -Be $false
    }
}

Describe 'Get-GuestCommandCleanupDecision' {
    It 'allows cleanup only when the command is Found and terminal; NotFound is indeterminate' {
        $notFound = Get-GuestCommandCleanupDecision -LookupClassification 'NotFound' -ExecutionState ''
        $notFound.Allowed | Should -Be $false
        $notFound.State | Should -Be 'Indeterminate'
        $notFound.Reason | Should -Match 'does not prove the guest command was never submitted'
        (Get-GuestCommandCleanupDecision -LookupClassification 'Found' -ExecutionState 'Succeeded').Allowed | Should -Be $true
        (Get-GuestCommandCleanupDecision -LookupClassification 'Found' -ExecutionState 'Failed').Allowed | Should -Be $true
        (Get-GuestCommandCleanupDecision -LookupClassification 'Found' -ExecutionState 'Canceled').Allowed | Should -Be $true
    }

    It 'retains resources while guest execution is running or unknown' {
        $running = Get-GuestCommandCleanupDecision -LookupClassification 'Found' -ExecutionState 'Running'
        $running.Allowed | Should -Be $false
        $running.Reason | Should -Match 'not terminal'
        $unknown = Get-GuestCommandCleanupDecision -LookupClassification 'Found' -ExecutionState ''
        $unknown.Allowed | Should -Be $false
        $unknown.State | Should -Be 'Indeterminate'
        $auth = Get-GuestCommandCleanupDecision -LookupClassification 'Authorization' -ExecutionState ''
        $auth.Allowed | Should -Be $false
        $auth.Reason | Should -Match 'Authorization'
        $net = Get-GuestCommandCleanupDecision -LookupClassification 'Network' -ExecutionState ''
        $net.Allowed | Should -Be $false
        $other = Get-GuestCommandCleanupDecision -LookupClassification 'Other' -ExecutionState ''
        $other.Allowed | Should -Be $false
    }
}

Describe 'Get-TemporaryDiskLineageDecision' {
    It 'requires temp disk -> snapshot -> original source and recorded IDs' {
        $ok = Get-TemporaryDiskLineageDecision -TemporaryDiskId '/subscriptions/s/disks/tmp' -TemporaryDiskSourceId '/subscriptions/s/snapshots/snap' -SnapshotId '/subscriptions/s/snapshots/snap' -SnapshotSourceId '/subscriptions/s/disks/src' -OriginalSourceDiskId '/subscriptions/s/disks/src' -RecordedTemporaryDiskId '/subscriptions/s/disks/tmp' -RecordedSnapshotId '/subscriptions/s/snapshots/snap'
        $ok.Matches | Should -Be $true

        $wrongSnap = Get-TemporaryDiskLineageDecision -TemporaryDiskId '/subscriptions/s/disks/tmp' -TemporaryDiskSourceId '/subscriptions/s/snapshots/other' -SnapshotId '/subscriptions/s/snapshots/snap' -SnapshotSourceId '/subscriptions/s/disks/src' -OriginalSourceDiskId '/subscriptions/s/disks/src' -RecordedTemporaryDiskId '/subscriptions/s/disks/tmp' -RecordedSnapshotId '/subscriptions/s/snapshots/snap'
        $wrongSnap.Matches | Should -Be $false
        $wrongSnap.Reason | Should -Match 'not snapshot'

        $wrongSource = Get-TemporaryDiskLineageDecision -TemporaryDiskId '/subscriptions/s/disks/tmp' -TemporaryDiskSourceId '/subscriptions/s/snapshots/snap' -SnapshotId '/subscriptions/s/snapshots/snap' -SnapshotSourceId '/subscriptions/s/disks/other' -OriginalSourceDiskId '/subscriptions/s/disks/src' -RecordedTemporaryDiskId '/subscriptions/s/disks/tmp' -RecordedSnapshotId '/subscriptions/s/snapshots/snap'
        $wrongSource.Matches | Should -Be $false
        $wrongSource.Reason | Should -Match 'original source'

        $nameOnly = Get-TemporaryDiskLineageDecision -TemporaryDiskId '' -TemporaryDiskSourceId '' -SnapshotId '' -SnapshotSourceId '' -OriginalSourceDiskId '/subscriptions/s/disks/src'
        $nameOnly.Matches | Should -Be $false
        $nameOnly.Reason | Should -Match 'Name-only'
    }
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

    It 'resolves destination A: by attested UniqueId and the snapshot disk by ARM uniqueId despite the DEV size discrepancy and LUN 1 collision' {
        $dest = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId $script:attested -Role 'Destination A:'
        $dest.Resolved | Should -Be $true
        $dest.Disk.Number | Should -Be 1
        $dest.Disk.UniqueId | Should -Be $script:attested
        $temp = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId 'TEMPDISK' -Role 'Temporary snapshot disk'
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
        $result.Reason | Should -Match 'no attested or captured UniqueId'
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

Describe 'Test-CopyRootIsLocalVolume and Test-ReparsePointPolicy' {
    It 'rejects UNC roots and non-local drive types' {
        (Test-CopyRootIsLocalVolume -RootPath '\\lv89\sdmshome' -RootTarget '' -DriveType 4 -IsReparsePoint $false).Local | Should -Be $false
        (Test-CopyRootIsLocalVolume -RootPath 'A:\' -RootTarget '\\files.example\share' -DriveType 3 -IsReparsePoint $false).Local | Should -Be $false
        (Test-CopyRootIsLocalVolume -RootPath 'A:\' -RootTarget '' -DriveType 4 -IsReparsePoint $false).Local | Should -Be $false
        (Test-CopyRootIsLocalVolume -RootPath 'A:\' -RootTarget '' -DriveType 3 -IsReparsePoint $true).Local | Should -Be $false
        (Test-CopyRootIsLocalVolume -RootPath 'A:\' -RootTarget '' -DriveType 3 -IsReparsePoint $false).Local | Should -Be $true
    }

    It 'rejects unexpected source reparse points and any writable destination reparse point, while allowing the excluded sdmshome path' {
        $ok = Test-ReparsePointPolicy -SourceReparseRelativePaths @('lv89\sdmshome') -DestinationReparseRelativePaths @() -ExcludeRelativePaths @('lv89\sdmshome')
        $ok.Accepted | Should -Be $true
        $src = Test-ReparsePointPolicy -SourceReparseRelativePaths @('temp\link-to-files') -DestinationReparseRelativePaths @() -ExcludeRelativePaths @('lv89\sdmshome')
        $src.Accepted | Should -Be $false
        $src.Reason | Should -Match 'Unexpected source reparse'
        $dst = Test-ReparsePointPolicy -SourceReparseRelativePaths @() -DestinationReparseRelativePaths @('app\redirect') -ExcludeRelativePaths @('lv89\sdmshome')
        $dst.Accepted | Should -Be $false
        $dst.Reason | Should -Match 'Destination reparse'
    }
}

Describe 'Test-LimsAppMigStageCleanupAllowed' {
    It 'blocks stage and cleanup while junction or directory-symlink validation is pending' {
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
        $dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $dev.WindowsSymlinkValidationStatus | Should -Be 'BlockedPendingValidation'
        $blocked = Test-LimsAppMigStageCleanupAllowed -Environment $dev
        $blocked.Allowed | Should -Be $false
        $junctionOnly = $dev.PSObject.Copy()
        $junctionOnly.WindowsReparseValidationStatus = 'Passed'
        (Test-LimsAppMigStageCleanupAllowed -Environment $junctionOnly).Allowed | Should -Be $false
        $symlinkOnly = $dev.PSObject.Copy()
        $symlinkOnly.WindowsSymlinkValidationStatus = 'Passed'
        (Test-LimsAppMigStageCleanupAllowed -Environment $symlinkOnly).Allowed | Should -Be $false
        $both = $dev.PSObject.Copy()
        $both.WindowsReparseValidationStatus = 'Passed'
        $both.WindowsSymlinkValidationStatus = 'Passed'
        (Test-LimsAppMigStageCleanupAllowed -Environment $both).Allowed | Should -Be $true
    }
}

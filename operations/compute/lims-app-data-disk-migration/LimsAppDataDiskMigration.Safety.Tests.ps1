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
    It 'allows a first acquire and a same-ID retry, and refuses a concurrent different ID' {
        (Get-MigrationLockAcquireDecision -ExistingLockRunId '' -ThisRunId '10').Allowed | Should -Be $true
        $retry = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '10'
        $retry.Allowed | Should -Be $true
        $retry.Resume | Should -Be $true
        $concurrent = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '11'
        $concurrent.Allowed | Should -Be $false
        $concurrent.Reason | Should -Match 'concurrent'
    }
}

Describe 'Get-GuestCommandCleanupDecision' {
    It 'allows cleanup only when the command was never submitted or is terminal' {
        (Get-GuestCommandCleanupDecision -LookupClassification 'NotFound' -ExecutionState '').State | Should -Be 'NeverSubmitted'
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
        $script:imds = [pscustomobject]@{
            storageProfile = [pscustomobject]@{
                resourceDisk = [pscustomobject]@{ size = 102400 }
                dataDisks    = @(
                    [pscustomobject]@{ lun = 0; managedDisk = [pscustomobject]@{ id = $script:destId } }
                    [pscustomobject]@{ lun = 1; managedDisk = [pscustomobject]@{ id = $script:tempId } }
                )
            }
        }
        $script:guestDisks = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = $script:attested; IsBoot = $false; IsSystem = $false; SizeBytes = 512GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 2; UniqueId = 'TEMPDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = 512GB; ScsiLogicalUnit = 1 }
            [pscustomobject]@{ Number = 3; UniqueId = 'RESOURCEDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = 102400KB; ScsiLogicalUnit = 1 }
        )
    }

    It 'resolves destination A: by ARM id + UniqueId after excluding the LUN 1 resource disk' {
        $dest = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId $script:attested -Role 'Destination A:'
        $dest.Resolved | Should -Be $true
        $dest.Disk.Number | Should -Be 1
        $temp = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $script:guestDisks -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId 'TEMPDISK' -Role 'Temporary snapshot disk'
        $temp.Resolved | Should -Be $true
        $temp.Disk.Number | Should -Be 2
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

    It 'fails closed on duplicate guest SCSI LUNs after excluding OS and resource disks' {
        $dupes = $script:guestDisks + [pscustomobject]@{ Number = 4; UniqueId = 'OTHERTEMP'; IsBoot = $false; IsSystem = $false; SizeBytes = 256GB; ScsiLogicalUnit = 1 }
        $result = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $dupes -ExpectedManagedDiskId $script:tempId -ExpectedLun 1 -ExpectedUniqueId '' -Role 'Temporary snapshot disk'
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Match 'duplicate guest SCSI LUN 1'
    }

    It 'reports the evidence needed when UniqueId is empty' {
        $empty = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = ''; IsBoot = $false; IsSystem = $false; SizeBytes = 512GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 3; UniqueId = 'RESOURCEDISK'; IsBoot = $false; IsSystem = $false; SizeBytes = 102400KB; ScsiLogicalUnit = 1 }
        )
        $result = Resolve-GuestDiskIdentity -ImdsCompute $script:imds -GuestDisks $empty -ExpectedManagedDiskId $script:destId -ExpectedLun 0 -ExpectedUniqueId '' -Role 'Destination A:'
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Match 'empty UniqueId'
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
    It 'blocks stage and cleanup while Windows reparse validation is pending' {
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
        $dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $blocked = Test-LimsAppMigStageCleanupAllowed -Environment $dev
        $blocked.Allowed | Should -Be $false
        $clone = $dev.PSObject.Copy()
        $clone.WindowsReparseValidationStatus = 'Passed'
        (Test-LimsAppMigStageCleanupAllowed -Environment $clone).Allowed | Should -Be $true
    }
}

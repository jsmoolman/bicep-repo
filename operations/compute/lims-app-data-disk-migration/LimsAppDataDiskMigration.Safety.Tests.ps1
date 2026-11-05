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
                'auto',
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

    It 'lets plan ignore the literal auto token' {
        $result = Resolve-LimsAppMigPipelineRunId -Action 'plan' -SuppliedRunId 'auto' -BuildId '99'
        $result.Accepted | Should -Be $true
        $result.RunId | Should -Be ''
    }

    It 'requires cleanup to supply the original numeric Build.BuildId and never falls back to the current build' {
        $empty = Resolve-LimsAppMigPipelineRunId -Action 'cleanup' -SuppliedRunId '' -BuildId '99'
        $empty.Accepted | Should -Be $false
        $auto = Resolve-LimsAppMigPipelineRunId -Action 'cleanup' -SuppliedRunId 'auto' -BuildId '99'
        $auto.Accepted | Should -Be $false
        $auto.Reason | Should -Match 'auto'
        $auto.Reason | Should -Match 'original numeric'
        $ok = Resolve-LimsAppMigPipelineRunId -Action 'cleanup' -SuppliedRunId '42' -BuildId '99'
        $ok.Accepted | Should -Be $true
        $ok.RunId | Should -Be '42'
    }

    It 'resolves auto to the current Build.BuildId for stage before numeric validation' {
        $empty = Resolve-LimsAppMigPipelineRunId -Action 'stage' -SuppliedRunId '' -BuildId '77'
        $empty.Accepted | Should -Be $true
        $empty.RunId | Should -Be '77'
        $auto = Resolve-LimsAppMigPipelineRunId -Action 'stage' -SuppliedRunId 'auto' -BuildId '77'
        $auto.Accepted | Should -Be $true
        $auto.RunId | Should -Be '77'
        $explicit = Resolve-LimsAppMigPipelineRunId -Action 'stage' -SuppliedRunId '55' -BuildId '77'
        $explicit.Accepted | Should -Be $true
        $explicit.RunId | Should -Be '55'
        $wrongCase = Resolve-LimsAppMigPipelineRunId -Action 'stage' -SuppliedRunId 'AUTO' -BuildId '77'
        $wrongCase.Accepted | Should -Be $false
    }

    It 'resolves auto to the current Build.BuildId for attach-and-inspect before numeric validation' {
        $empty = Resolve-LimsAppMigPipelineRunId -Action 'attach-and-inspect' -SuppliedRunId '' -BuildId '81'
        $empty.Accepted | Should -Be $true
        $empty.RunId | Should -Be '81'
        $auto = Resolve-LimsAppMigPipelineRunId -Action 'attach-and-inspect' -SuppliedRunId 'auto' -BuildId '81'
        $auto.Accepted | Should -Be $true
        $auto.RunId | Should -Be '81'
    }

    It 'uses the current Build.BuildId for configure-app and activate-app when none is supplied or auto is supplied' {
        $configure = Resolve-LimsAppMigPipelineRunId -Action 'configure-app' -SuppliedRunId '' -BuildId '88'
        $configure.Accepted | Should -Be $true
        $configure.RunId | Should -Be '88'
        $configureAuto = Resolve-LimsAppMigPipelineRunId -Action 'configure-app' -SuppliedRunId 'auto' -BuildId '88'
        $configureAuto.Accepted | Should -Be $true
        $configureAuto.RunId | Should -Be '88'
        $activate = Resolve-LimsAppMigPipelineRunId -Action 'activate-app' -SuppliedRunId '91' -BuildId '88'
        $activate.Accepted | Should -Be $true
        $activate.RunId | Should -Be '91'
    }
}

Describe 'Resolve-LimsAppMigPipelineAzureFilesUnc' {
    It 'allows the not-used placeholder for actions that ignore UNC' {
        foreach ($action in @('plan', 'attach-and-inspect', 'stage', 'cleanup')) {
            $result = Resolve-LimsAppMigPipelineAzureFilesUnc -Action $action -SuppliedUnc 'not-used'
            $result.Accepted | Should -Be $true
            $result.Unc | Should -Be ''
        }
    }

    It 'rejects the not-used placeholder for configure-app and activate-app' {
        $configure = Resolve-LimsAppMigPipelineAzureFilesUnc -Action 'configure-app' -SuppliedUnc 'not-used'
        $configure.Accepted | Should -Be $false
        $configure.Reason | Should -Match 'not-used'
        $activate = Resolve-LimsAppMigPipelineAzureFilesUnc -Action 'activate-app' -SuppliedUnc 'not-used'
        $activate.Accepted | Should -Be $false
        $ok = Resolve-LimsAppMigPipelineAzureFilesUnc -Action 'configure-app' -SuppliedUnc '\\limsfiles.file.core.windows.net\lv89'
        $ok.Accepted | Should -Be $true
        $ok.Unc | Should -Be '\\limsfiles.file.core.windows.net\lv89'
        $empty = Resolve-LimsAppMigPipelineAzureFilesUnc -Action 'configure-app' -SuppliedUnc ''
        $empty.Accepted | Should -Be $true
        $empty.Unc | Should -Be ''
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
        (Get-AzureCliErrorClassification -ExitCode 1 -Text 'PreconditionFailed (412) The If-Match value is stale') | Should -Be 'PreconditionFailed'
    }
}

Describe 'Get-AtomicLockApplyDecision' {
    It 'allows a successful If-Match apply and refuses a simultaneous 412 race' {
        (Get-AtomicLockApplyDecision -Classification 'Found').Allowed | Should -Be $true
        $lost = Get-AtomicLockApplyDecision -Classification 'PreconditionFailed'
        $lost.Allowed | Should -Be $false
        $lost.Reason | Should -Match 'If-Match race'
        (Get-AtomicLockApplyDecision -Classification 'AlreadyExists').Allowed | Should -Be $false
    }
}

Describe 'Get-GuestSubmittedEvidenceDecision' {
    It 'accepts only the exact token false and treats every other value as unknown' {
        (Get-GuestSubmittedEvidenceDecision -Value 'false').Accepted | Should -Be $true
        foreach ($unknown in @($null, '', ' ', 'true', 'True', 'TRUE', 'false ', ' false', 'FALSE', 'False', '0', '1', 'yes', 'no')) {
            $result = Get-GuestSubmittedEvidenceDecision -Value $unknown
            $result.Accepted | Should -Be $false
            $result.Reason | Should -Match "explicit value 'false'"
        }
        $boolFalse = Get-GuestSubmittedEvidenceDecision -Value $false
        $boolFalse.Accepted | Should -Be $false
        $boolTrue = Get-GuestSubmittedEvidenceDecision -Value $true
        $boolTrue.Accepted | Should -Be $false
    }
}

Describe 'Get-InspectAttemptStateTransitionDecision' {
    It 'allows only Prepared to Submitting or Prepared to Recovering' {
        (Get-InspectAttemptStateTransitionDecision -FromState 'Prepared' -ToState 'Submitting').Allowed | Should -Be $true
        (Get-InspectAttemptStateTransitionDecision -FromState 'Prepared' -ToState 'Recovering').Allowed | Should -Be $true
        $fromSubmitting = Get-InspectAttemptStateTransitionDecision -FromState 'Submitting' -ToState 'Recovering'
        $fromSubmitting.Allowed | Should -Be $false
        $fromSubmitting.Reason | Should -Match 'Prepared'
        $fromRecovering = Get-InspectAttemptStateTransitionDecision -FromState 'Recovering' -ToState 'Submitting'
        $fromRecovering.Allowed | Should -Be $false
        $missing = Get-InspectAttemptStateTransitionDecision -FromState '' -ToState 'Recovering'
        $missing.Allowed | Should -Be $false
        $nullState = Get-InspectAttemptStateTransitionDecision -FromState $null -ToState 'Submitting'
        $nullState.Allowed | Should -Be $false
        $wrongCase = Get-InspectAttemptStateTransitionDecision -FromState 'prepared' -ToState 'Recovering'
        $wrongCase.Allowed | Should -Be $false
    }
}

Describe 'Get-InspectSubmitDecision' {
    It 'allows submit only from Prepared with explicit false, inspect-only status, and this run holding the lock' {
        $ok = Get-InspectSubmitDecision -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $ok.Allowed | Should -Be $true
        $missingEvidence = Get-InspectSubmitDecision -GuestSubmittedTag '' -AttemptStateTag 'Prepared' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $missingEvidence.Allowed | Should -Be $false
        $missingEvidence.Reason | Should -Match "explicit value 'false'"
        $alreadySubmitting = Get-InspectSubmitDecision -GuestSubmittedTag 'false' -AttemptStateTag 'Submitting' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $alreadySubmitting.Allowed | Should -Be $false
        $otherOwner = Get-InspectSubmitDecision -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LockOwnerRunId '9' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $otherOwner.Allowed | Should -Be $false
        $stage = Get-InspectSubmitDecision -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'Pending'
        $stage.Allowed | Should -Be $false
    }
}

Describe 'Get-PreSubmitRecoveryDecision' {
    It 'allows reviewed attach-and-inspect recovery only when Prepared, explicit false, and the command never existed' {
        $ok = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $ok.Allowed | Should -Be $true
        $notRequested = Get-PreSubmitRecoveryDecision -Requested $false -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $notRequested.Allowed | Should -Be $false
        $notRequested.Reason | Should -Match 'not requested'
        $submitted = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'true' -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $submitted.Allowed | Should -Be $false
        $submitted.Reason | Should -Match "explicit value 'false'"
        $stage = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'Pending'
        $stage.Allowed | Should -Be $false
        $otherOwner = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'false' -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '9' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $otherOwner.Allowed | Should -Be $false
        $alreadySubmitting = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'false' -AttemptStateTag 'Submitting' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $alreadySubmitting.Allowed | Should -Be $false
        $alreadySubmitting.Reason | Should -Match 'Prepared'
    }

    It 'blocks recovery when GuestSubmitted is missing, empty, or malformed' {
        foreach ($unknown in @($null, '', ' ', 'TRUE', '1', 'FALSE', 'False', 'false ')) {
            $result = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag $unknown -AttemptStateTag 'Prepared' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
            $result.Allowed | Should -Be $false
            $result.Reason | Should -Match "explicit value 'false'"
        }
        $missingState = Get-PreSubmitRecoveryDecision -Requested $true -GuestSubmittedTag 'false' -AttemptStateTag '' -LookupClassification 'NotFound' -LockOwnerRunId '10' -ThisRunId '10' -CopyStatusTag 'InspectOnly'
        $missingState.Allowed | Should -Be $false
        $missingState.Reason | Should -Match 'Prepared'
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
        $sameIdInspect = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '10' -Purpose 'AttachAndInspect'
        $sameIdInspect.Allowed | Should -Be $false
        $sameIdInspect.Reason | Should -Match 'same run ID'
        $inspectVsStage = Get-MigrationLockAcquireDecision -ExistingLockRunId '10' -ThisRunId '12' -Purpose 'AttachAndInspect'
        $inspectVsStage.Allowed | Should -Be $false
        $inspectVsStage.Reason | Should -Match 'concurrent'
    }
}

Describe 'Test-CollectInventoryOnlyFlag' {
    It 'accepts Run Command true/1 and rejects empty or false' {
        (Test-CollectInventoryOnlyFlag -Value 'true') | Should -Be $true
        (Test-CollectInventoryOnlyFlag -Value '1') | Should -Be $true
        (Test-CollectInventoryOnlyFlag -Value $true) | Should -Be $true
        (Test-CollectInventoryOnlyFlag -Value 'false') | Should -Be $false
        (Test-CollectInventoryOnlyFlag -Value '') | Should -Be $false
        (Test-CollectInventoryOnlyFlag -Value $null) | Should -Be $false
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
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
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

    It 'requires a completed copy tag for configure-app' {
        (Test-CopyCompletedForConfigure -CopyCompletedTag 'Succeeded' -CopyStatusTag 'Failed').Allowed | Should -Be $true
        (Test-CopyCompletedForConfigure -CopyCompletedTag '' -CopyStatusTag 'Succeeded').Allowed | Should -Be $true
        $blocked = Test-CopyCompletedForConfigure -CopyCompletedTag '' -CopyStatusTag 'Pending'
        $blocked.Allowed | Should -Be $false
    }

    It 'keeps automatic startup blocked while JDBC, Apache, Shibboleth, or UNC reviews are pending' {
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
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
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
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
        $dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
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

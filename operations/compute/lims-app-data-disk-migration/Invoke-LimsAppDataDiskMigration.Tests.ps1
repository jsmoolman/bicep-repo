<#
    Pester tests for Invoke-LimsAppDataDiskMigration.ps1.

    Runs on Ubuntu CI with every Azure CLI *Adapter mocked. Covers:
      - reviewed mapping shape (DEV enabled; the other four present and disabled)
      - mismatched source/destination identity and attachment
      - encryption mismatch versus the mapping
      - occupied temporary LUN
      - concurrent destination lock
      - cleanup of an interrupted run (temp disk attached; snapshot retained)
      - cleanup refusing the original source disk and destination A: disk
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_APP_MIG_CONTROL_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'Invoke-LimsAppDataDiskMigration.ps1')

    $script:Dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'

    function New-FakeManagedDiskId {
        param([string] $Name)
        return "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/disks/$Name"
    }

    function New-FakeVmId {
        param([string] $Name)
        return "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/virtualMachines/$Name"
    }

    function New-FakeDesId {
        return "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/rg-security-lims-dev-westeu/providers/Microsoft.Compute/diskEncryptionSets/$($script:Dev.DiskEncryptionSetName)"
    }

    function New-FakeDataDisk {
        param([int] $Lun, [string] $Name)
        return [pscustomobject]@{
            lun         = $Lun
            name        = $Name
            managedDisk = [pscustomobject]@{ id = (New-FakeManagedDiskId -Name $Name) }
        }
    }

    function New-FakeVm {
        param(
            [string] $Name,
            [object[]] $DataDisks,
            [object] $Tags = $null
        )
        return [pscustomobject]@{
            id             = (New-FakeVmId -Name $Name)
            name           = $Name
            location       = $script:Dev.Location
            zones          = @()
            tags           = $Tags
            storageProfile = [pscustomobject]@{ dataDisks = $DataDisks }
        }
    }

    function New-FakeDisk {
        param(
            [string] $Name,
            [string] $DesId,
            [string] $SourceId = $null,
            [string] $ManagedBy = $null
        )
        return [pscustomobject]@{
            id           = (New-FakeManagedDiskId -Name $Name)
            name         = $Name
            location     = $script:Dev.Location
            managedBy    = $ManagedBy
            encryption   = [pscustomobject]@{ diskEncryptionSetId = $DesId }
            creationData = [pscustomobject]@{ sourceResourceId = $SourceId }
        }
    }

    function New-MatchingEnvironment {
        $clone = $script:Dev.PSObject.Copy()
        $clone.DiskEncryptionSetResourceId = New-FakeDesId
        return $clone
    }
}

Describe 'Get-LimsAppDataDiskMigrationEnvironmentMapping' {
    It 'contains exactly the five supported environments and enables only DEV' {
        $mapping = @(Get-LimsAppDataDiskMigrationEnvironmentMapping)
        $mapping.EnvironmentName | Should -Be @('dev', 'tst', 'acc', 'preprd', 'prd')
        ($mapping | Where-Object { $_.Enabled }).EnvironmentName | Should -Be @('dev')
    }

    It 'pins the reviewed DEV source and destination identities' {
        $script:Dev.SourceVmName | Should -Be 'vm-lims-dev-westeu-001'
        $script:Dev.SourceDataDiskName | Should -Be 'vmlimsdevwesteu001-v2-datadisk'
        $script:Dev.SourceDataDiskLun | Should -Be 1
        $script:Dev.DestinationVmName | Should -Be 'vm-lims-dev-v2-westeu-001'
        $script:Dev.DestinationComputerName | Should -Be 'lims-dev-v2-001'
        $script:Dev.DestinationDataDiskName | Should -Be 'appdata-vm-lims-dev-v2-westeu-001'
        $script:Dev.DestinationDataDiskLun | Should -Be 0
        $script:Dev.DestinationDriveLetter | Should -Be 'A'
        $script:Dev.DestinationVolumeLabel | Should -Be 'LIMS-App'
        $script:Dev.PreferredTemporaryLun | Should -Be 1
        $script:Dev.ExcludeRelativePaths | Should -Contain 'lv89\sdmshome'
    }

    It 'refuses a disabled environment before any Azure call' {
        { Assert-EnvironmentEnabledAndComplete -Environment (Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'tst') } |
            Should -Throw -ExpectedMessage '*not enabled*'
    }
}

Describe 'Select-CandidateTemporaryLun (pure)' {
    It 'accepts the preferred LUN when it is free' {
        $result = Select-CandidateTemporaryLun -OccupiedLuns @(0) -PreferredLun 1
        $result.Accepted | Should -Be $true
        $result.Lun | Should -Be 1
    }

    It 'fails when the preferred LUN is occupied by another disk' {
        $result = Select-CandidateTemporaryLun -OccupiedLuns @(0, 1) -PreferredLun 1 -DiskNameAlreadyAtPreferredLun 'some-other-disk' -ThisRunTemporaryDiskName 'lims-app-mig-dev-1-tmp'
        $result.Accepted | Should -Be $false
        $result.Reason | Should -Match 'already occupied'
    }

    It 'accepts the preferred LUN when this run''s own temporary disk is already there' {
        $result = Select-CandidateTemporaryLun -OccupiedLuns @(0, 1) -PreferredLun 1 -DiskNameAlreadyAtPreferredLun 'lims-app-mig-dev-1-tmp' -ThisRunTemporaryDiskName 'lims-app-mig-dev-1-tmp'
        $result.Accepted | Should -Be $true
    }
}

Describe 'Test-EncryptionMatchesMapping (pure)' {
    It 'fails when the mapping pin is empty even if live source and destination DES IDs match' {
        $des = New-FakeDesId
        $result = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId $des -DestinationDiskEncryptionSetId $des -Environment $script:Dev
        $result.Matches | Should -Be $false
        $result.Reason | Should -Match 'DiskEncryptionSetResourceId is empty'
        $result.Reason | Should -BeLike "*$des*"
    }

    It 'fails when live source and destination DES IDs differ' {
        $env = New-MatchingEnvironment
        $result = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId (New-FakeDesId) -DestinationDiskEncryptionSetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/diskEncryptionSets/other-des' -Environment $env
        $result.Matches | Should -Be $false
        $result.Reason | Should -Match 'does not equal destination'
    }

    It 'succeeds when live source, live destination, name, and mapping pin all match' {
        $env = New-MatchingEnvironment
        $result = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId $env.DiskEncryptionSetResourceId -DestinationDiskEncryptionSetId $env.DiskEncryptionSetResourceId -Environment $env
        $result.Matches | Should -Be $true
    }
}

Describe 'Get-CleanupTargetDecision (pure)' {
    It 'allows deleting this run''s temporary disk and never the source or destination data disks' {
        $names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '77'
        $tempId = New-FakeManagedDiskId -Name $names.TemporaryDiskName
        $ok = Get-CleanupTargetDecision -CandidateDiskName $names.TemporaryDiskName -CandidateDiskId $tempId -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId $tempId -SourceDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -DestinationDataDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -AttachedToVmId (New-FakeVmId -Name $script:Dev.DestinationVmName) -DestinationVmId (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $ok.Allowed | Should -Be $true

        $source = Get-CleanupTargetDecision -CandidateDiskName $names.TemporaryDiskName -CandidateDiskId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId $tempId -SourceDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -DestinationDataDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -AttachedToVmId $null -DestinationVmId (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $source.Allowed | Should -Be $false
        $source.Reason | Should -Match 'original source'

        $dest = Get-CleanupTargetDecision -CandidateDiskName $names.TemporaryDiskName -CandidateDiskId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId $tempId -SourceDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -DestinationDataDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -AttachedToVmId $null -DestinationVmId (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $dest.Allowed | Should -Be $false
        $dest.Reason | Should -Match 'destination A:'
    }

    It 'treats a missing temporary disk as already-gone so an interrupted run can still release the lock' {
        $names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '77'
        $result = Get-CleanupTargetDecision -CandidateDiskName '' -CandidateDiskId '' -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId '' -SourceDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -DestinationDataDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -AttachedToVmId $null -DestinationVmId (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $result.Allowed | Should -Be $true
        $result.DiskAlreadyGone | Should -Be $true
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationPlanChecks (orchestration, mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks
        }
        Mock Get-AzDiskAdapter {
            param($DiskName)
            return New-FakeDisk -Name $DiskName -DesId $script:des
        }
    }

    It 'fails when the source VM resource ID does not match the mapping' {
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                $vm = New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
                $vm.id = '/subscriptions/00000000-0000-0000-0000-000000000099/resourceGroups/rg-wrong/providers/Microsoft.Compute/virtualMachines/vm-lims-dev-westeu-001'
                return $vm
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks
        }
        { Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment) } | Should -Throw -ExpectedMessage '*Source VM resource ID*'
        Should -Invoke Get-AzDiskAdapter -Times 0
    }

    It 'fails when the source data disk is attached at a different LUN' {
        $script:sourceDisks = @(New-FakeDataDisk -Lun 2 -Name $script:Dev.SourceDataDiskName)
        { Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment) } | Should -Throw -ExpectedMessage '*Source attachment check failed*'
    }

    It 'fails when the destination data disk name does not match the mapping' {
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name 'some-other-app-disk')
        { Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment) } | Should -Throw -ExpectedMessage '*Destination attachment check failed*'
    }

    It 'fails when the preferred temporary LUN is already occupied' {
        $script:destDisks = @(
            (New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName),
            (New-FakeDataDisk -Lun 1 -Name 'already-there-disk')
        )
        { Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment) } | Should -Throw -ExpectedMessage '*already occupied*'
    }

    It 'returns the mapped IDs, DES, and candidate LUN when every check matches' {
        $env = New-MatchingEnvironment
        $result = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $env
        $result.SourceVmId | Should -Be (New-FakeVmId -Name $script:Dev.SourceVmName)
        $result.DestinationVmId | Should -Be (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $result.SourceDiskId | Should -Be (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName)
        $result.DestinationDiskId | Should -Be (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName)
        $result.DiskEncryptionSetId | Should -Be $script:des
        $result.CandidateTemporaryLun | Should -Be 1
    }

    It 'lets plan report the live DES, then fails until the mapping pin is filled' {
        { Invoke-LimsAppDataDiskMigrationPlan -Environment $script:Dev } | Should -Throw -ExpectedMessage '*DiskEncryptionSetResourceId is empty*'
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationStage (orchestration, mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        $script:destTags = $null
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags $script:destTags
        }
        Mock Get-AzDiskAdapter { param($DiskName) return New-FakeDisk -Name $DiskName -DesId $script:des }
        Mock Test-AzSnapshotExistsAdapter { return $null }
        Mock Test-AzDiskExistsAdapter { return $null }
        Mock New-AzIncrementalSnapshotAdapter {
            return [pscustomobject]@{ id = '/subscriptions/x/snapshots/snap'; creationData = [pscustomobject]@{ sourceResourceId = (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) } }
        }
        Mock New-AzDiskFromSnapshotAdapter {
            return New-FakeDisk -Name 'tmp' -DesId $script:des -SourceId '/subscriptions/x/snapshots/snap'
        }
        Mock Add-AzVmDataDiskAdapter { }
        Mock Set-AzResourceTagsMergeAdapter { }
    }

    It 'refuses stage when CaptureMode is unspecified' {
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'unspecified' } |
            Should -Throw -ExpectedMessage '*CaptureMode must be recorded*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
    }

    It 'refuses a concurrent run against the same destination' {
        $script:destTags = [pscustomobject]@{
            limsAppMigLockRunId  = 'other-run'
            limsAppMigTempDiskId = (New-FakeManagedDiskId -Name 'lims-app-mig-dev-other-run-tmp')
        }
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*locked by migration run*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
    }

    It 'creates the snapshot and temp disk, attaches at LUN 1, and records resource IDs' {
        $null = Invoke-LimsAppDataDiskMigrationStage -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 1
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1 -ParameterFilter { $Lun -eq 1 -and $DiskName -eq 'lims-app-mig-dev-10-tmp' }
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 2
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationCleanup after an interrupted run (mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:runId = '42'
        $script:names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId $script:runId
        $script:tempId = New-FakeManagedDiskId -Name $script:names.TemporaryDiskName
        $script:snapId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/snapshots/$($script:names.SnapshotName)"
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(
            (New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName),
            (New-FakeDataDisk -Lun 1 -Name $script:names.TemporaryDiskName)
        )
        $script:destTags = [pscustomobject]@{
            limsAppMigLockRunId    = $script:runId
            limsAppMigTempDiskId   = $script:tempId
            limsAppMigSnapshotId   = $script:snapId
            limsAppMigCaptureMode  = 'online'
            limsAppMigCopyStatus   = 'Failed'
            limsAppMigTemporaryLun = '1'
        }
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags $script:destTags
        }
        Mock Get-AzDiskAdapter { param($DiskName) return New-FakeDisk -Name $DiskName -DesId $script:des }
        Mock Test-AzDiskExistsAdapter {
            return New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -ManagedBy (New-FakeVmId -Name $script:Dev.DestinationVmName)
        }
        Mock Test-AzSnapshotExistsAdapter {
            return [pscustomobject]@{ id = $script:snapId; name = $script:names.SnapshotName }
        }
        Mock Remove-AzVmDataDiskAdapter { }
        Mock Remove-AzDiskAdapter { }
        Mock Remove-AzSnapshotAdapter { }
        Mock Remove-AzResourceTagsAdapter { }
    }

    It 'detaches and deletes only the interrupted run''s temporary disk and retains the snapshot by default' {
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 1 -ParameterFilter { $DiskName -eq $script:names.TemporaryDiskName }
        Should -Invoke Remove-AzDiskAdapter -Times 1 -ParameterFilter { $DiskName -eq $script:names.TemporaryDiskName }
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }

    It 'deletes the snapshot only when DeleteSnapshot is explicitly true' {
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $true
        Should -Invoke Remove-AzSnapshotAdapter -Times 1 -ParameterFilter { $SnapshotName -eq $script:names.SnapshotName }
    }

    It 'still releases the lock when the temporary disk is already gone' {
        Mock Test-AzDiskExistsAdapter { return $null }
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }
}

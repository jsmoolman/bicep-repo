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
            [object] $Tags = $null,
            [Parameter(Mandatory = $false)]
            [AllowNull()]
            $Zones
        )
        $vm = [pscustomobject]@{
            id             = (New-FakeVmId -Name $Name)
            name           = $Name
            location       = $script:Dev.Location
            tags           = $Tags
            storageProfile = [pscustomobject]@{ dataDisks = $DataDisks }
        }
        if ($PSBoundParameters.ContainsKey('Zones')) {
            $vm | Add-Member -NotePropertyName 'zones' -NotePropertyValue $Zones
        }
        return $vm
    }

    function New-FakeDisk {
        param(
            [string] $Name,
            [string] $DesId,
            [string] $SourceId = $null,
            [string] $ManagedBy = $null,
            [string] $UniqueId = '60022480D1B07E6ACD98417F86591F4B',
            $Tags = $null
        )
        return [pscustomobject]@{
            id           = (New-FakeManagedDiskId -Name $Name)
            name         = $Name
            location     = $script:Dev.Location
            managedBy    = $ManagedBy
            uniqueId     = $UniqueId
            tags         = $Tags
            encryption   = [pscustomobject]@{ diskEncryptionSetId = $DesId }
            creationData = [pscustomobject]@{ sourceResourceId = $SourceId }
        }
    }

    function New-Lookup {
        param(
            [string] $Classification,
            $Resource = $null,
            [string] $Text = ''
        )
        return [pscustomobject]@{
            Classification = $Classification
            Resource       = $Resource
            Text           = $Text
            ExitCode       = $(if ($Classification -eq 'Found') { 0 } else { 1 })
        }
    }

    function New-MatchingEnvironment {
        $clone = $script:Dev.PSObject.Copy()
        $clone.DiskEncryptionSetResourceId = New-FakeDesId
        return $clone
    }

    function New-UnblockedMatchingEnvironment {
        $clone = New-MatchingEnvironment
        $clone.WindowsReparseValidationStatus = 'Passed'
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
        $script:Dev.DestinationAttestedGuestUniqueId | Should -Be '60022480D1B07E6ACD98417F86591F4B'
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        (Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '10').TemporaryDiskName | Should -Be 'lims-app-mig-dev-tmp'
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
        $result = Select-CandidateTemporaryLun -OccupiedLuns @(0, 1) -PreferredLun 1 -DiskNameAlreadyAtPreferredLun 'some-other-disk' -ThisRunTemporaryDiskName 'lims-app-mig-dev-tmp'
        $result.Accepted | Should -Be $false
        $result.Reason | Should -Match 'already occupied'
    }

    It 'accepts the preferred LUN when this run''s own temporary disk is already there' {
        $result = Select-CandidateTemporaryLun -OccupiedLuns @(0, 1) -PreferredLun 1 -DiskNameAlreadyAtPreferredLun 'lims-app-mig-dev-tmp' -ThisRunTemporaryDiskName 'lims-app-mig-dev-tmp'
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

    It 'refuses name-only deletion when the recorded temporary disk ID is missing' {
        $names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '77'
        $result = Get-CleanupTargetDecision -CandidateDiskName $names.TemporaryDiskName -CandidateDiskId (New-FakeManagedDiskId -Name $names.TemporaryDiskName) -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId '' -SourceDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName) -DestinationDataDiskResourceId (New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName) -AttachedToVmId $null -DestinationVmId (New-FakeVmId -Name $script:Dev.DestinationVmName)
        $result.Allowed | Should -Be $false
        $result.Reason | Should -Match 'Name-only deletion is refused'
    }
}

Describe 'Get-VmZoneDecision (pure)' {
    It 'treats an omitted zones property as regional' {
        $vm = New-FakeVm -Name 'vm' -DataDisks @()
        $vm.PSObject.Properties['zones'] | Should -BeNullOrEmpty
        $result = Get-VmZoneDecision -Vm $vm
        $result.Accepted | Should -Be $true
        $result.Regional | Should -Be $true
        $result.Zone | Should -Be ''
    }

    It 'treats a null zones value as regional' {
        $result = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones $null)
        $result.Accepted | Should -Be $true
        $result.Regional | Should -Be $true
        $result.Zone | Should -Be ''
    }

    It 'treats an empty zones array or empty string as regional' {
        $emptyArray = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones @())
        $emptyArray.Accepted | Should -Be $true
        $emptyArray.Regional | Should -Be $true
        $emptyArray.Zone | Should -Be ''

        $emptyString = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones '')
        $emptyString.Accepted | Should -Be $true
        $emptyString.Regional | Should -Be $true
        $emptyString.Zone | Should -Be ''
    }

    It 'preserves a single canonical Azure zone' {
        $result = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones @('1'))
        $result.Accepted | Should -Be $true
        $result.Regional | Should -Be $false
        $result.Zone | Should -Be '1'
    }

    It 'rejects multiple zones as ambiguous and rejects a malformed zone' {
        $ambiguous = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones @('1', '2'))
        $ambiguous.Accepted | Should -Be $false
        $ambiguous.Reason | Should -Match 'more than one availability zone'

        $invalid = Get-VmZoneDecision -Vm (New-FakeVm -Name 'vm' -DataDisks @() -Zones @('west-europe-1'))
        $invalid.Accepted | Should -Be $false
        $invalid.Reason | Should -Match 'not a canonical Azure availability zone'
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
        Mock New-AzIncrementalSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock New-AzDiskFromSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Add-AzVmDataDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzVmDataDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Set-AzResourceTagsMergeAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzResourceTagsAdapter { throw 'Azure write adapter should not run during plan.' }
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
        $result.Zone | Should -Be ''
    }

    It 'preserves a single destination VM zone from the ARM response' {
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Zones @('1')
        }
        $result = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment)
        $result.Zone | Should -Be '1'
    }

    It 'rejects an invalid destination VM zone before any Azure write' {
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Zones @('not-a-zone')
        }
        { Invoke-LimsAppDataDiskMigrationPlanChecks -Environment (New-MatchingEnvironment) } |
            Should -Throw -ExpectedMessage '*not a canonical Azure availability zone*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'DEV plan with zones omitted and an empty DES pin prints the live DES ID and stops at the pin guard' {
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        [string]::IsNullOrWhiteSpace($script:Dev.DiskEncryptionSetResourceId) | Should -Be $true

        $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $script:Dev -RequireEncryptionPin $false
        $checks.Zone | Should -Be ''
        $summary = @(Write-LimsAppDataDiskMigrationPlanSummary -Environment $script:Dev -Checks $checks) -join [Environment]::NewLine
        $summary | Should -BeLike "*$($script:des)*"

        $failure = $null
        try {
            Invoke-LimsAppDataDiskMigrationPlan -Environment $script:Dev
        }
        catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -Match 'DiskEncryptionSetResourceId is empty'
        $failure | Should -BeLike "*$($script:des)*"

        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 0
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationStage (orchestration, mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        $script:names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '10'
        $script:snapId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/snapshots/$($script:names.SnapshotName)"
        $script:sourceId = New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks
        }
        Mock Get-AzDiskAdapter { param($DiskName) return New-FakeDisk -Name $DiskName -DesId $script:des }
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Mock Get-AzSnapshotLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Mock New-AzIncrementalSnapshotAdapter {
            return [pscustomobject]@{ id = $script:snapId; creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId } }
        }
        Mock New-AzDiskFromSnapshotAdapter {
            $disk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
            return (New-Lookup -Classification 'Found' -Resource $disk)
        }
        Mock Add-AzVmDataDiskAdapter { }
        Mock Set-AzResourceTagsMergeAdapter { }
        Mock Write-PipelineVariable { }
    }

    It 'blocks stage while Windows reparse validation is pending' {
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*blocked pending Windows reparse-point validation*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
    }

    It 'refuses stage when CaptureMode is unspecified' {
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'unspecified' } |
            Should -Throw -ExpectedMessage '*CaptureMode must be recorded*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
    }

    It 'refuses a concurrent run that already holds the environment temp-disk lock' {
        $holder = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '99' })
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $holder) }
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*concurrent*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
    }

    It 'allows a same-ID retry against the environment lock after proving lineage' {
        $snap = [pscustomobject]@{ id = $script:snapId; creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId } }
        $held = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $held) }
        Mock Get-AzSnapshotLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $snap) }
        $null = Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1
    }

    It 'creates the snapshot and temp disk, attaches at LUN 1, and records resource IDs' {
        $null = Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 1
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1 -ParameterFilter { $Lun -eq 1 -and $DiskName -eq 'lims-app-mig-dev-tmp' }
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 1
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationCleanup after an interrupted run (mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:runId = '42'
        $script:names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId $script:runId
        $script:tempId = New-FakeManagedDiskId -Name $script:names.TemporaryDiskName
        $script:snapId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/snapshots/$($script:names.SnapshotName)"
        $script:sourceId = New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName
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
        $script:tempDisk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -ManagedBy (New-FakeVmId -Name $script:Dev.DestinationVmName) -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = $script:runId })
        $script:snapshot = [pscustomobject]@{
            id           = $script:snapId
            name         = $script:names.SnapshotName
            creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId }
        }
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags $script:destTags
        }
        Mock Get-AzDiskAdapter { param($DiskName) return New-FakeDisk -Name $DiskName -DesId $script:des }
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $script:tempDisk) }
        Mock Get-AzSnapshotLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $script:snapshot) }
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Mock Remove-AzVmDataDiskAdapter { }
        Mock Remove-AzDiskAdapter { }
        Mock Remove-AzSnapshotAdapter { }
        Mock Remove-AzResourceTagsAdapter { }
    }

    It 'blocks cleanup while Windows reparse validation is pending' {
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*blocked pending Windows reparse-point validation*'
        Should -Invoke Remove-AzDiskAdapter -Times 0
    }

    It 'detaches and deletes only the interrupted run''s temporary disk and retains the snapshot by default' {
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 1 -ParameterFilter { $DiskName -eq $script:names.TemporaryDiskName }
        Should -Invoke Remove-AzDiskAdapter -Times 1 -ParameterFilter { $DiskName -eq $script:names.TemporaryDiskName }
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }

    It 'deletes the snapshot only when DeleteSnapshot is explicitly true' {
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $true
        Should -Invoke Remove-AzSnapshotAdapter -Times 1 -ParameterFilter { $SnapshotName -eq $script:names.SnapshotName }
    }

    It 'still releases the lock when the temporary disk is confirmed NotFound' {
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }

    It 'retains resources while the guest command is still Running' {
        $running = [pscustomobject]@{ instanceView = [pscustomobject]@{ executionState = 'Running' } }
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $running) }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*not terminal*'
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
    }

    It 'retains resources when guest command lookup is Authorization or Network' {
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'Authorization' -Text 'AuthorizationFailed (403)') }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*Authorization*'
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'Network' -Text 'timed out') }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*Network*'
        Should -Invoke Remove-AzDiskAdapter -Times 0
    }

    It 'refuses cleanup when temporary-disk lineage does not match the original source' {
        $script:tempDisk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId '/subscriptions/s/snapshots/wrong' -ManagedBy (New-FakeVmId -Name $script:Dev.DestinationVmName) -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = $script:runId })
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $script:tempDisk) }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*not snapshot*'
        Should -Invoke Remove-AzDiskAdapter -Times 0
    }

    It 'does not treat an authorization disk lookup as already-gone' {
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Authorization' -Text 'AuthorizationFailed (403) Resource not found') }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*Authorization*'
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 0
    }
}

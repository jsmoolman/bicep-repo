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
        return "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/RG-CORE-LIMS-DEV-WESTEU/providers/Microsoft.Compute/diskEncryptionSets/$($script:Dev.DiskEncryptionSetName)"
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
            etag           = 'etag-1'
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
        $clone.WindowsSymlinkValidationStatus = 'Passed'
        return $clone
    }

    function New-EmptyPinEnvironment {
        $clone = $script:Dev.PSObject.Copy()
        $clone.DiskEncryptionSetResourceId = ''
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
        $script:Dev.DiskEncryptionSetResourceId | Should -Be (New-FakeDesId)
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.WindowsSymlinkValidationStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.AppV2.JbossServiceName | Should -Be 'JBoss-8.0'
        $script:Dev.AppV2.ApacheServiceName | Should -Be 'Apache-2.4.57'
        $script:Dev.AppV2.ShibbolethServiceName | Should -Be 'shibd_Default'
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
        $emptyPin = New-EmptyPinEnvironment
        $result = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId $des -DestinationDiskEncryptionSetId $des -Environment $emptyPin
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
        Mock Set-AzVmTagsIfMatchAdapter { throw 'Azure write adapter should not run during plan.' }
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

    It 'DEV plan with zones omitted and an empty DES pin stops at the pin guard with no success summary' {
        $emptyPin = New-EmptyPinEnvironment
        $emptyPin.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        [string]::IsNullOrWhiteSpace($emptyPin.DiskEncryptionSetResourceId) | Should -Be $true
        $script:operatorLog = New-Object System.Collections.Generic.List[string]
        Mock Write-OperatorLog { param($Message) $script:operatorLog.Add([string]$Message) }

        $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $emptyPin -RequireEncryptionPin $false
        $checks.Zone | Should -Be ''

        $failure = $null
        try {
            Invoke-LimsAppDataDiskMigrationPlan -Environment $emptyPin
        }
        catch {
            $failure = $_.Exception.Message
        }
        $failure | Should -Match 'DiskEncryptionSetResourceId is empty'
        $failure | Should -BeLike "*$($script:des)*"
        ($script:operatorLog -join "`n") | Should -Not -Match '===== LIMS APP data-disk migration: PLAN ====='

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

Describe 'Invoke-LimsAppDataDiskMigrationEntry (script entry point, mocked Azure)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        $script:operatorLog = New-Object System.Collections.Generic.List[string]
        $env:LIMS_APP_MIG_ACTION = $null
        $env:LIMS_APP_MIG_ENVIRONMENT = $null
        $env:LIMS_APP_MIG_RUN_ID = $null
        Mock Write-OperatorLog { param($Message) $script:operatorLog.Add([string]$Message) }
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
        Mock Set-AzVmTagsIfMatchAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock New-AzIncrementalSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock New-AzDiskFromSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Add-AzVmDataDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzVmDataDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzDiskAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzSnapshotAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Set-AzResourceTagsMergeAdapter { throw 'Azure write adapter should not run during plan.' }
        Mock Remove-AzResourceTagsAdapter { throw 'Azure write adapter should not run during plan.' }
    }

    It 'emits the success summary to the operator log after every plan check passes, even when the entry discards the success stream' {
        Mock Get-LimsAppDataDiskMigrationEnvironment { return (New-MatchingEnvironment) }
        $returned = Invoke-LimsAppDataDiskMigrationEntry -Action 'plan' -EnvironmentName 'dev'
        $returned | Should -BeNullOrEmpty

        $log = $script:operatorLog -join [Environment]::NewLine
        $log | Should -Match '===== LIMS APP data-disk migration: PLAN ====='
        $log | Should -BeLike "*$($script:Dev.SubscriptionId)*"
        $log | Should -BeLike "*$($script:Dev.Location)*"
        $log | Should -BeLike "*$(New-FakeVmId -Name $script:Dev.SourceVmName)*"
        $log | Should -BeLike "*$(New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName)*"
        $log | Should -Match 'LUN 1'
        $log | Should -BeLike "*$(New-FakeVmId -Name $script:Dev.DestinationVmName)*"
        $log | Should -BeLike "*$(New-FakeManagedDiskId -Name $script:Dev.DestinationDataDiskName)*"
        $log | Should -Match 'LUN 0'
        $log | Should -Match 'LIMS-App'
        $log | Should -Match 'expected guest values'
        $log | Should -BeLike "*$($script:des)*"
        $log | Should -Match 'available on APP v2'
        $log | Should -Match 'Candidate temporary LUN'

        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
    }

    It 'produces no success summary when a plan check fails, and does not call Azure write adapters' {
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name 'some-other-app-disk')
        { Invoke-LimsAppDataDiskMigrationEntry -Action 'plan' -EnvironmentName 'dev' } |
            Should -Throw -ExpectedMessage '*Destination attachment check failed*'

        ($script:operatorLog -join [Environment]::NewLine) | Should -Not -Match '===== LIMS APP data-disk migration: PLAN ====='
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
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
        Mock Set-AzVmTagsIfMatchAdapter { return (New-Lookup -Classification 'Found') }
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

    It 'refuses an overlapping stage attempt even when it uses the same run ID' {
        $held = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'Found' -Resource $held) }
        { Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*same run ID*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'creates the snapshot and temp disk, attaches at LUN 1, and records resource IDs' {
        $null = Invoke-LimsAppDataDiskMigrationStage -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 1
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1 -ParameterFilter { $Lun -eq 1 -and $DiskName -eq 'lims-app-mig-dev-tmp' }
        Should -Invoke Set-AzResourceTagsMergeAdapter -Times 1
    }
}

Describe 'Invoke-LimsAppDataDiskMigrationAttachAndInspect (orchestration, mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:sourceDisks = @(New-FakeDataDisk -Lun 1 -Name $script:Dev.SourceDataDiskName)
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        $script:names = Get-MigrationRunResourceNames -Environment $script:Dev -MigrationRunId '10'
        $script:snapId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/snapshots/$($script:names.SnapshotName)"
        $script:sourceId = New-FakeManagedDiskId -Name $script:Dev.SourceDataDiskName
        $script:recordedTags = $null
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
            param($SourceDiskId)
            if ($SourceDiskId -ne $script:sourceId) {
                throw "Snapshot source must be the mapped legacy APP disk, got '$SourceDiskId'."
            }
            return [pscustomobject]@{ id = $script:snapId; creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId } }
        }
        Mock New-AzDiskFromSnapshotAdapter {
            $disk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
            return (New-Lookup -Classification 'Found' -Resource $disk)
        }
        Mock Add-AzVmDataDiskAdapter {
            param($VmName)
            if ($VmName -ne $script:Dev.DestinationVmName) {
                throw "attach-and-inspect must not write the VM '$VmName'."
            }
        }
        Mock Set-AzVmTagsIfMatchAdapter { return (New-Lookup -Classification 'Found') }
        Mock Set-AzResourceTagsMergeAdapter {
            param($Tags)
            $script:recordedTags = $Tags
        }
        Mock Write-PipelineVariable { }
        Mock Remove-AzVmDataDiskAdapter { throw 'attach-and-inspect must leave the disk attached.' }
        Mock Remove-AzDiskAdapter { throw 'attach-and-inspect must leave the temporary disk.' }
        Mock Remove-AzSnapshotAdapter { throw 'attach-and-inspect must retain the snapshot.' }
    }

    It 'does not require the stage/cleanup reparse gates' {
        $env = New-MatchingEnvironment
        $env.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $null = Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment $env -MigrationRunId '10' -CaptureMode 'online'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1
    }

    It 'refuses attach-and-inspect when CaptureMode is unspecified' {
        { Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'unspecified' } |
            Should -Throw -ExpectedMessage '*CaptureMode must be recorded*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'fails on a wrong destination VM before any snapshot or attach' {
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            $vm = New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks
            $vm.id = '/subscriptions/00000000-0000-0000-0000-000000000099/resourceGroups/rg-wrong/providers/Microsoft.Compute/virtualMachines/vm-lims-dev-v2-westeu-001'
            return $vm
        }
        { Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced' } |
            Should -Throw -ExpectedMessage '*Destination VM resource ID*'
        Should -Invoke Set-AzVmTagsIfMatchAdapter -Times 0
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'fails when the preferred temporary LUN is already occupied' {
        $script:destDisks = @(
            (New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName),
            (New-FakeDataDisk -Lun 1 -Name 'some-other-disk')
        )
        { Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*already occupied*'
        Should -Invoke Set-AzVmTagsIfMatchAdapter -Times 0
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'refuses an overlapping attach-and-inspect attempt even when it uses the same run ID' {
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
        }
        { Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*same run ID*'
        Should -Invoke Set-AzVmTagsIfMatchAdapter -Times 0
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'refuses a simultaneous attach-and-inspect attempt that loses the If-Match race before any snapshot or attach' {
        $script:lockApplies = 0
        Mock Set-AzVmTagsIfMatchAdapter {
            $script:lockApplies++
            if ($script:lockApplies -eq 1) { return (New-Lookup -Classification 'Found') }
            return (New-Lookup -Classification 'PreconditionFailed' -Text 'PreconditionFailed (412)')
        }
        $null = Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online'
        { Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '11' -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*If-Match precondition failed*'
        Should -Invoke Set-AzVmTagsIfMatchAdapter -Times 2
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1
        Should -Invoke New-AzDiskFromSnapshotAdapter -Times 1
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1
    }

    It 'acquires the destination-VM lock with If-Match before creating or attaching anything' {
        $script:order = @()
        Mock Set-AzVmTagsIfMatchAdapter { $script:order += 'lock'; return (New-Lookup -Classification 'Found') }
        Mock New-AzIncrementalSnapshotAdapter {
            $script:order += 'snapshot'
            return [pscustomobject]@{ id = $script:snapId; creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId } }
        }
        Mock New-AzDiskFromSnapshotAdapter {
            $script:order += 'disk'
            $disk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
            return (New-Lookup -Classification 'Found' -Resource $disk)
        }
        Mock Add-AzVmDataDiskAdapter { $script:order += 'attach' }
        $null = Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced'
        $script:order[0] | Should -Be 'lock'
        ($script:order -join ',') | Should -Be 'lock,snapshot,disk,attach'
    }

    It 'snapshots only the mapped source disk, attaches only APP v2 at LUN 1, and records run IDs and lineage' {
        $result = Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'writes-quiesced'
        $result.TemporaryLun | Should -Be 1
        $result.Phase | Should -Be 'InspectAttached'
        $result.SnapshotId | Should -Be $script:snapId
        $script:recordedTags.limsAppMigLockRunId | Should -Be '10'
        $script:recordedTags.limsAppMigSnapshotId | Should -Be $script:snapId
        $script:recordedTags.limsAppMigCopyStatus | Should -Be 'InspectOnly'
        $script:recordedTags.limsAppMigPhase | Should -Be 'InspectAttached'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 1 -ParameterFilter { $SourceDiskId -eq $script:sourceId }
        Should -Invoke Add-AzVmDataDiskAdapter -Times 1 -ParameterFilter {
            $VmName -eq $script:Dev.DestinationVmName -and $Lun -eq 1 -and $DiskName -eq 'lims-app-mig-dev-tmp'
        }
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0 -ParameterFilter { $VmName -eq $script:Dev.SourceVmName }
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.WindowsSymlinkValidationStatus | Should -Be 'BlockedPendingValidation'
    }

    It 'treats attach-before-submit NotFound as indeterminate unless reviewed pre-submit recovery is requested' {
        $null = Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment (New-MatchingEnvironment) -MigrationRunId '10' -CaptureMode 'online'
        $tempId = New-FakeManagedDiskId -Name $script:names.TemporaryDiskName
        $inspectTags = [pscustomobject]@{
            limsAppMigLockRunId       = '10'
            limsAppMigCopyStatus      = 'InspectOnly'
            limsAppMigGuestSubmitted  = 'false'
            limsAppMigTempDiskId      = $tempId
            limsAppMigSnapshotId      = $script:snapId
        }
        $script:destDisks = @(
            (New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName),
            (New-FakeDataDisk -Lun 1 -Name $script:names.TemporaryDiskName)
        )
        Mock Get-AzVmAdapter {
            param($VmName)
            if ($VmName -eq $script:Dev.SourceVmName) {
                return New-FakeVm -Name $script:Dev.SourceVmName -DataDisks $script:sourceDisks
            }
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags $inspectTags
        }
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Mock Get-AzDiskLookupAdapter {
            $disk = New-FakeDisk -Name $script:names.TemporaryDiskName -DesId $script:des -SourceId $script:snapId -ManagedBy (New-FakeVmId -Name $script:Dev.DestinationVmName) -UniqueId 'TEMPDISKUID' -Tags ([pscustomobject]@{ limsAppMigLockRunId = '10' })
            return (New-Lookup -Classification 'Found' -Resource $disk)
        }
        Mock Get-AzSnapshotLookupAdapter {
            return (New-Lookup -Classification 'Found' -Resource ([pscustomobject]@{ id = $script:snapId; creationData = [pscustomobject]@{ sourceResourceId = $script:sourceId } }))
        }
        Mock Remove-AzVmDataDiskAdapter { }
        Mock Remove-AzDiskAdapter { }
        Mock Remove-AzRunCommandAdapter { }
        Mock Remove-AzResourceTagsAdapter { }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId '10' -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*does not prove the guest command was never submitted*'
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-MatchingEnvironment) -MigrationRunId '10' -DeleteSnapshot $false -PreSubmitRecovery $true
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 1
        Should -Invoke Remove-AzDiskAdapter -Times 1
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        Should -Invoke Remove-AzRunCommandAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
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
        Mock Get-AzRunCommandLookupAdapter {
            return (New-Lookup -Classification 'Found' -Resource ([pscustomobject]@{ instanceView = [pscustomobject]@{ executionState = 'Failed' } }))
        }
        Mock Remove-AzVmDataDiskAdapter { }
        Mock Remove-AzDiskAdapter { }
        Mock Remove-AzSnapshotAdapter { }
        Mock Remove-AzRunCommandAdapter { }
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
        Should -Invoke Remove-AzRunCommandAdapter -Times 1
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }

    It 'deletes the snapshot only when DeleteSnapshot is explicitly true' {
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $true
        Should -Invoke Remove-AzSnapshotAdapter -Times 1 -ParameterFilter { $SnapshotName -eq $script:names.SnapshotName }
    }

    It 'still releases the lock when the temporary disk is confirmed NotFound after the guest command is terminal' {
        Mock Get-AzDiskLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 1
    }

    It 'retains the attached temporary disk when cleanup arrives between attach and guest submission (Run Command NotFound)' {
        Mock Get-AzRunCommandLookupAdapter { return (New-Lookup -Classification 'NotFound') }
        { Invoke-LimsAppDataDiskMigrationCleanup -Environment (New-UnblockedMatchingEnvironment) -MigrationRunId $script:runId -DeleteSnapshot $false } |
            Should -Throw -ExpectedMessage '*does not prove the guest command was never submitted*'
        Should -Invoke Remove-AzVmDataDiskAdapter -Times 0
        Should -Invoke Remove-AzDiskAdapter -Times 0
        Should -Invoke Remove-AzSnapshotAdapter -Times 0
        Should -Invoke Remove-AzResourceTagsAdapter -Times 0
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

Describe 'Invoke-LimsAppDataDiskMigrationConfigure (orchestration, mocked adapters)' {
    BeforeEach {
        $script:des = New-FakeDesId
        $script:destDisks = @(New-FakeDataDisk -Lun 0 -Name $script:Dev.DestinationDataDiskName)
        $script:destTags = [pscustomobject]@{ limsAppMigCopyCompleted = 'Succeeded' }
        Mock Get-AzVmAdapter {
            return New-FakeVm -Name $script:Dev.DestinationVmName -DataDisks $script:destDisks -Tags $script:destTags
        }
        Mock Get-AzDiskAdapter { param($DiskName) return New-FakeDisk -Name $DiskName -DesId $script:des }
        Mock Write-PipelineVariable { }
        Mock New-AzIncrementalSnapshotAdapter { throw 'configure-app must not snapshot.' }
        Mock New-AzDiskFromSnapshotAdapter { throw 'configure-app must not create a temp disk.' }
        Mock Add-AzVmDataDiskAdapter { throw 'configure-app must not attach disks.' }
    }

    It 'refuses configure-app when the completed copy has not been recorded' {
        $script:destTags = [pscustomobject]@{}
        { Invoke-LimsAppDataDiskMigrationConfigure -Environment $script:Dev -MigrationRunId '10' -Phase 'Register' } |
            Should -Throw -ExpectedMessage '*completed copy*'
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
    }

    It 'publishes destination identity for configure-app after a completed copy and does not write Azure disks' {
        $null = Invoke-LimsAppDataDiskMigrationConfigure -Environment $script:Dev -MigrationRunId '10' -Phase 'Register'
        Should -Invoke Write-PipelineVariable -Times 1 -ParameterFilter { $Name -eq 'limsAppMigDestinationVmName' }
        Should -Invoke Write-PipelineVariable -Times 1 -ParameterFilter { $Name -eq 'limsAppMigConfigurePhase' -and $Value -eq 'Register' }
        Should -Invoke New-AzIncrementalSnapshotAdapter -Times 0
        Should -Invoke Add-AzVmDataDiskAdapter -Times 0
        $script:Dev.WindowsReparseValidationStatus | Should -Be 'BlockedPendingValidation'
        $script:Dev.WindowsSymlinkValidationStatus | Should -Be 'BlockedPendingValidation'
    }

    It 'does not require the stage/cleanup reparse gates for activate-app' {
        $null = Invoke-LimsAppDataDiskMigrationConfigure -Environment $script:Dev -MigrationRunId '11' -Phase 'Activate'
        Should -Invoke Write-PipelineVariable -Times 1 -ParameterFilter { $Name -eq 'limsAppMigConfigurePhase' -and $Value -eq 'Activate' }
    }
}

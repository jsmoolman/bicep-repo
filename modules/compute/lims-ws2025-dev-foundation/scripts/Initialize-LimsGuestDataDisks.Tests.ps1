<#
    Pester tests for Initialize-LimsGuestDataDisks.ps1.

    SCOPE / WHAT THESE TESTS ARE -- AND ARE NOT.

    These tests run on Ubuntu CI (Pester on Linux; no pwsh/Windows Storage
    module, Windows CIM schemas, Win32_DiskDrive/Win32_Volume, or
    administrator/SYSTEM APIs are required or available here) and exercise
    exactly two kinds of code in the real script, unmodified:

      1. The DECISION/PLANNING functions (Get-ApprovedDiskPreparationAllowlist,
         Test-TargetIdentityMatchesAllowlist, Select-NonOsNonTemporaryDiskCandidates,
         Resolve-ApprovedDiskTarget, Get-DiskPreparationPlan, Get-DvdPreparationPlan,
         Get-GuestDiskPreparationPlan) -- called directly, for real, with plain
         fake data objects. This is where the actual safety logic lives, and it
         is Linux-testable because these functions never call a real cmdlet.

      2. The ORCHESTRATION function (Invoke-GuestDiskPreparation, via
         Get-FreshGuestDiskPreparationPlan) -- called for real, but with every
         *Adapter function (the only functions that would call a real Windows
         cmdlet) replaced with a Pester Mock. The decision logic inside
         Invoke-GuestDiskPreparation is never mocked or bypassed -- only the
         adapters are, per the task's explicit instruction to "mock the
         adapters, not the entire safety decision process".

    These tests do NOT start, and cannot start, from dot-sourcing alone (see
    the LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY guard below) invoke any real
    guest mutation, and they are not a substitute for actual Windows storage
    integration testing. No disposable VM or Windows CI exists for this
    repository (see docs/operations.md); real Windows guest execution
    (Get-Disk, Initialize-Disk, New-Partition, Format-Volume, Get-CimInstance,
    actual IMDS reachability, actual Run Command delivery/exit-code
    reporting) has NOT been rehearsed anywhere, by this test suite or
    otherwise. PowerShell 5.1 guest-compatibility is checked separately by
    PSScriptAnalyzer (see PSScriptAnalyzerSettings.psd1 in this same
    directory and .azuredevops/pipelines/ci.yml) -- that is a distinct,
    complementary check, not duplicated here.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY = '1'
    # Dummy values satisfy this script's own top-level Mandatory parameter
    # binding on dot-source (PowerShell binds param() even when dot-sourcing,
    # before the DOT_SOURCE_ONLY guard at the bottom of the file is ever
    # reached) -- LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY=1 is what actually
    # prevents Invoke-GuestDiskPreparation from running with these dummy
    # values; every real test below calls Invoke-GuestDiskPreparation (or
    # the decision/planning functions) itself with its own real arguments.
    . (Join-Path $PSScriptRoot 'Initialize-LimsGuestDataDisks.ps1') -Target App -Mode Validate `
        -ExpectedSubscriptionId 'dot-source-only' -ExpectedResourceGroupName 'dot-source-only' `
        -ExpectedVmName 'dot-source-only' -ExpectedComputerName 'dot-source-only' -ExpectedDisksJson '[]'

    # Sourced from the real allowlist function so every fixture below always
    # matches whatever the script's own fixed allowlist currently says --
    # EXCEPT the "pin the contract" test later, which deliberately compares
    # against independently hand-written literal values instead of this.
    $script:AllowedApp = (Get-ApprovedDiskPreparationAllowlist).App
    $script:AllowedSql = (Get-ApprovedDiskPreparationAllowlist).Sql

    # ---- Fixture builders -----------------------------------------------

    function New-FakeImdsDataDisk {
        param(
            [Parameter(Mandatory = $true)] [int] $Lun,
            [Parameter(Mandatory = $true)] [string] $DiskName,
            [Parameter(Mandatory = $true)] [int64] $SizeBytes,
            [string] $SubscriptionId = $script:AllowedApp.SubscriptionId,
            [string] $ResourceGroupName = $script:AllowedApp.ResourceGroupName,
            [string] $ManagedDiskId
        )
        if (-not $ManagedDiskId) {
            $ManagedDiskId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/$DiskName"
        }
        return [pscustomobject]@{
            lun               = $Lun
            name              = $DiskName
            diskCapacityBytes = $SizeBytes
            managedDisk       = [pscustomobject]@{ id = $ManagedDiskId }
        }
    }

    function New-FakeImdsCompute {
        param(
            [string] $SubscriptionId = $script:AllowedApp.SubscriptionId,
            [string] $ResourceGroupName = $script:AllowedApp.ResourceGroupName,
            [string] $Name = $script:AllowedApp.VmName,
            [object[]] $DataDisks = @()
        )
        return [pscustomobject]@{
            subscriptionId    = $SubscriptionId
            resourceGroupName = $ResourceGroupName
            name              = $Name
            storageProfile    = [pscustomobject]@{ dataDisks = @($DataDisks) }
        }
    }

    function New-FakeGuestDisk {
        param(
            [Parameter(Mandatory = $true)] [int] $Number,
            [string] $UniqueId = ([guid]::NewGuid().ToString()),
            [bool] $IsBoot = $false,
            [bool] $IsSystem = $false,
            [string] $PartitionStyle = 'RAW',
            [int64] $SizeBytes = 0,
            [int] $ScsiBus = 0,
            [int] $ScsiPort = 1,
            [int] $ScsiTargetId = 0,
            [int] $ScsiLogicalUnit = 0,
            [string] $FriendlyName = 'Fake Managed Disk'
        )
        return [pscustomobject]@{
            Number          = $Number
            UniqueId        = $UniqueId
            IsBoot          = $IsBoot
            IsSystem        = $IsSystem
            PartitionStyle  = $PartitionStyle
            SizeBytes       = $SizeBytes
            ScsiBus         = $ScsiBus
            ScsiPort        = $ScsiPort
            ScsiTargetId    = $ScsiTargetId
            ScsiLogicalUnit = $ScsiLogicalUnit
            FriendlyName    = $FriendlyName
        }
    }

    function New-FakeOsDisk {
        param([int] $Number = 0, [string] $UniqueId = 'os-disk-uid')
        return New-FakeGuestDisk -Number $Number -UniqueId $UniqueId -IsBoot $true -IsSystem $true `
            -PartitionStyle 'GPT' -SizeBytes (127 * 1024 * 1024 * 1024) -ScsiBus 0 -ScsiPort 0 -ScsiTargetId 0 -ScsiLogicalUnit 0
    }

    function New-FakeTempDisk {
        param([int] $Number = 1, [string] $UniqueId = 'temp-disk-uid')
        # Shares the OS disk's own ScsiBus/ScsiPort pair (0/0) -- this is
        # exactly the "sibling on the boot controller" exclusion rule, never
        # a hardcoded port number.
        return New-FakeGuestDisk -Number $Number -UniqueId $UniqueId -IsBoot $false -IsSystem $false `
            -PartitionStyle 'RAW' -SizeBytes (150 * 1024 * 1024 * 1024) -ScsiBus 0 -ScsiPort 0 -ScsiTargetId 0 -ScsiLogicalUnit 1
    }

    function New-FakePartition {
        param(
            [Parameter(Mandatory = $true)] [int] $DiskNumber,
            [int] $PartitionNumber = 1,
            [string] $DriveLetter = '',
            [string] $GptType = '',
            [string] $Type = 'Basic',
            [int64] $SizeBytes = 0,
            [string[]] $AccessPaths = @()
        )
        if ($AccessPaths.Count -eq 0 -and $DriveLetter) { $AccessPaths = @("${DriveLetter}:\") }
        return [pscustomobject]@{
            DiskNumber      = $DiskNumber
            PartitionNumber = $PartitionNumber
            DriveLetter     = $DriveLetter
            GptType         = $GptType
            Type            = $Type
            SizeBytes       = $SizeBytes
            AccessPaths     = @($AccessPaths)
        }
    }

    function New-FakeMsrPartition {
        param([Parameter(Mandatory = $true)] [int] $DiskNumber, [int] $PartitionNumber = 1)
        return New-FakePartition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber `
            -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Type 'Reserved' -SizeBytes (16 * 1024 * 1024)
    }

    function New-FakeVolume {
        param(
            [string] $DriveLetter,
            [string] $FileSystem = 'NTFS',
            [string] $FileSystemLabel = '',
            [int64] $AllocationUnitSize = 4096,
            [int64] $SizeBytes = 0
        )
        return [pscustomobject]@{
            DriveLetter        = $DriveLetter
            FileSystem         = $FileSystem
            FileSystemLabel    = $FileSystemLabel
            AllocationUnitSize = $AllocationUnitSize
            SizeBytes          = $SizeBytes
        }
    }

    function New-FakeDvdVolume {
        param([string] $DriveLetter, [int] $DriveType = 5, [string] $Label = '')
        return [pscustomobject]@{ DriveLetter = "${DriveLetter}:"; DriveType = $DriveType; Label = $Label }
    }

    function ConvertTo-ExpectedDisksJson {
        param([Parameter(Mandatory = $true)] [object[]] $Disks)
        return (ConvertTo-Json -InputObject @($Disks) -Depth 5)
    }

    # Full, approved, RAW APP guest inventory: OS (LUN-irrelevant, excluded
    # by IsBoot/IsSystem), Temporary (shares OS's bus/port -- excluded), and
    # the one approved APP data disk at LUN 0, RAW, no partitions.
    function New-AppRawGuestFixture {
        $osDisk = New-FakeOsDisk
        $tempDisk = New-FakeTempDisk
        $dataDisk = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedApp.Disks[0].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 0
        return [pscustomobject]@{
            Disks      = @($osDisk, $tempDisk, $dataDisk)
            Partitions = @()
            Volumes    = @()
            DvdVolumes = @()
            Imds       = New-FakeImdsCompute -Name $script:AllowedApp.VmName -DataDisks @(
                New-FakeImdsDataDisk -Lun 0 -DiskName $script:AllowedApp.Disks[0].DiskName -SizeBytes $script:AllowedApp.Disks[0].SizeBytes
            )
        }
    }

    # Full, approved, RAW SQL guest inventory: OS, Temporary (shares OS's
    # bus/port), SQL DATA at LUN 0 and SQL LOG at LUN 1 (both RAW, no
    # partitions), plus an empty, unlabelled virtual DVD-ROM at E: and Z:
    # free.
    function New-SqlRawGuestFixture {
        $osDisk = New-FakeOsDisk
        $tempDisk = New-FakeTempDisk
        $dataDisk = New-FakeGuestDisk -Number 2 -UniqueId 'sql-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedSql.Disks[0].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 0
        $logDisk = New-FakeGuestDisk -Number 3 -UniqueId 'sql-log-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedSql.Disks[1].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 1
        return [pscustomobject]@{
            Disks      = @($osDisk, $tempDisk, $dataDisk, $logDisk)
            Partitions = @()
            Volumes    = @()
            DvdVolumes = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label '')
            Imds       = New-FakeImdsCompute -SubscriptionId $script:AllowedSql.SubscriptionId `
                -ResourceGroupName $script:AllowedSql.ResourceGroupName -Name $script:AllowedSql.VmName -DataDisks @(
                New-FakeImdsDataDisk -Lun 0 -DiskName $script:AllowedSql.Disks[0].DiskName -SizeBytes $script:AllowedSql.Disks[0].SizeBytes `
                    -SubscriptionId $script:AllowedSql.SubscriptionId -ResourceGroupName $script:AllowedSql.ResourceGroupName
                New-FakeImdsDataDisk -Lun 1 -DiskName $script:AllowedSql.Disks[1].DiskName -SizeBytes $script:AllowedSql.Disks[1].SizeBytes `
                    -SubscriptionId $script:AllowedSql.SubscriptionId -ResourceGroupName $script:AllowedSql.ResourceGroupName
            )
        }
    }

    function Invoke-PlanFromFixture {
        # $DvdLetterMoveTarget is deliberately untyped (not [string]) so an
        # omitted argument is genuinely $null -- a typed [string] parameter
        # with no explicit default is silently initialized to "" rather
        # than $null when unbound, which would be indistinguishable from
        # App's legitimately empty allowlist value and defeat the
        # "caller omitted it" detection below.
        param([Parameter(Mandatory = $true)] [string] $Target, [Parameter(Mandatory = $true)] $Fixture, $DvdLetterMoveTarget)
        $allowlistEntry = if ($Target -eq 'App') { $script:AllowedApp } else { $script:AllowedSql }
        if ($null -eq $DvdLetterMoveTarget) { $DvdLetterMoveTarget = $allowlistEntry.DvdLetterMoveTarget }
        return Get-GuestDiskPreparationPlan -Target $Target `
            -ExpectedSubscriptionId $allowlistEntry.SubscriptionId -ExpectedResourceGroupName $allowlistEntry.ResourceGroupName `
            -ExpectedVmName $allowlistEntry.VmName -ExpectedComputerName $allowlistEntry.ComputerName `
            -ExpectedDisks $allowlistEntry.Disks -DvdLetterMoveTarget $DvdLetterMoveTarget `
            -ImdsCompute $Fixture.Imds -ActualComputerName $allowlistEntry.ComputerName `
            -GuestDiskInventory $Fixture.Disks -GuestPartitionInventory $Fixture.Partitions `
            -GuestVolumeInventory $Fixture.Volumes -GuestDvdVolumeInventory $Fixture.DvdVolumes
    }

    # Used only by the 'Invoke-GuestDiskPreparation' Describe block below --
    # defined here (BeforeAll) rather than directly in that Describe body,
    # since Pester v5 does not guarantee plain function definitions written
    # directly in a Describe block are visible from It/BeforeEach at Run
    # time (they only run at Discovery time there).
    function Set-AppFixture {
        param($Fixture = (New-AppRawGuestFixture))
        $script:imdsToReturn = $Fixture.Imds
        $script:actualComputerNameToReturn = $script:AllowedApp.ComputerName
        $script:diskInventoryToReturn = $Fixture.Disks
        $script:partitionInventoryToReturn = $Fixture.Partitions
        $script:volumeInventoryToReturn = $Fixture.Volumes
        $script:dvdInventoryToReturn = $Fixture.DvdVolumes
    }

    function Set-SqlFixture {
        param($Fixture = (New-SqlRawGuestFixture))
        $script:imdsToReturn = $Fixture.Imds
        $script:actualComputerNameToReturn = $script:AllowedSql.ComputerName
        $script:diskInventoryToReturn = $Fixture.Disks
        $script:partitionInventoryToReturn = $Fixture.Partitions
        $script:volumeInventoryToReturn = $Fixture.Volumes
        $script:dvdInventoryToReturn = $Fixture.DvdVolumes
    }
}

AfterAll {
    Remove-Item Env:\LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
}

# =============================================================================
# 1) Fixed, independent allowlist
# =============================================================================

Describe 'Get-ApprovedDiskPreparationAllowlist' {
    It 'pins the exact approved APP target (independent of caller input)' {
        $allowlist = Get-ApprovedDiskPreparationAllowlist
        $allowlist.App.SubscriptionId | Should -Be '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
        $allowlist.App.ResourceGroupName | Should -Be 'rg-compute-lims-dev-westeu'
        $allowlist.App.VmName | Should -Be 'vm-lims-dev-v2-westeu-001'
        $allowlist.App.ComputerName | Should -Be 'lims-dev-v2-001'
        $allowlist.App.DvdLetterMoveTarget | Should -Be ''
        $allowlist.App.Disks.Count | Should -Be 1
        $allowlist.App.Disks[0].Lun | Should -Be 0
        $allowlist.App.Disks[0].DiskName | Should -Be 'appdata-vm-lims-dev-v2-westeu-001'
        $allowlist.App.Disks[0].SizeBytes | Should -Be ([int64]128 * 1024 * 1024 * 1024)
        $allowlist.App.Disks[0].DriveLetter | Should -Be 'A'
        $allowlist.App.Disks[0].FileSystemLabel | Should -Be 'LIMS-App'
        $allowlist.App.Disks[0].AllocationUnitBytes | Should -Be 4096
    }

    It 'pins the exact approved SQL target (independent of caller input)' {
        $allowlist = Get-ApprovedDiskPreparationAllowlist
        $allowlist.Sql.SubscriptionId | Should -Be '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
        $allowlist.Sql.ResourceGroupName | Should -Be 'rg-compute-lims-dev-westeu'
        $allowlist.Sql.VmName | Should -Be 'vm-lims-dev-v2-westeu-002'
        $allowlist.Sql.ComputerName | Should -Be 'lims-dev-v2-002'
        $allowlist.Sql.DvdLetterMoveTarget | Should -Be 'Z'
        $allowlist.Sql.Disks.Count | Should -Be 2
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 0).DiskName | Should -Be 'sqldata-vm-lims-dev-v2-westeu-002'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 0).SizeBytes | Should -Be ([int64]1024 * 1024 * 1024 * 1024)
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 0).DriveLetter | Should -Be 'E'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 0).FileSystemLabel | Should -Be 'SQL-Data'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 0).AllocationUnitBytes | Should -Be 65536
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 1).DiskName | Should -Be 'sqllog-vm-lims-dev-v2-westeu-002'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 1).SizeBytes | Should -Be ([int64]512 * 1024 * 1024 * 1024)
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 1).DriveLetter | Should -Be 'F'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 1).FileSystemLabel | Should -Be 'SQL-Logs'
        ($allowlist.Sql.Disks | Where-Object Lun -EQ 1).AllocationUnitBytes | Should -Be 65536
    }
}

# =============================================================================
# 2) Independent allowlist agreement (caller params AND IMDS, each checked
#    separately -- never checked against each other)
# =============================================================================

Describe 'Test-TargetIdentityMatchesAllowlist' {
    BeforeEach {
        $script:goodImds = New-FakeImdsCompute -SubscriptionId $script:AllowedApp.SubscriptionId `
            -ResourceGroupName $script:AllowedApp.ResourceGroupName -Name $script:AllowedApp.VmName
    }

    It 'returns null when caller params and IMDS each independently match the allowlist' {
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $script:goodImds
        $result | Should -BeNullOrEmpty
    }

    It 'rejects a caller-consistent v1 VM name even though caller and IMDS agree with EACH OTHER' {
        $v1Imds = New-FakeImdsCompute -SubscriptionId $script:AllowedApp.SubscriptionId `
            -ResourceGroupName $script:AllowedApp.ResourceGroupName -Name 'vm-lims-dev-westeu-001'
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName 'vm-lims-dev-westeu-001' -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $v1Imds
        $result | Should -Not -BeNullOrEmpty
    }

    It 'rejects a caller-consistent other-subscription/resource-group combination' {
        $otherImds = New-FakeImdsCompute -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ResourceGroupName 'rg-other' -Name $script:AllowedApp.VmName
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId '11111111-1111-1111-1111-111111111111' -ExpectedResourceGroupName 'rg-other' `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $otherImds
        $result | Should -Not -BeNullOrEmpty
    }

    It 'rejects when only IMDS disagrees with the allowlist, even though caller params match it' {
        $mismatchedImds = New-FakeImdsCompute -SubscriptionId $script:AllowedApp.SubscriptionId `
            -ResourceGroupName $script:AllowedApp.ResourceGroupName -Name 'vm-lims-dev-v2-westeu-999'
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $mismatchedImds
        $result | Should -Not -BeNullOrEmpty
    }

    It 'rejects when only the caller-supplied VM name disagrees with the allowlist, even though IMDS matches it' {
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName 'vm-lims-dev-v2-westeu-999' -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $script:goodImds
        $result | Should -Not -BeNullOrEmpty
    }

    It 'rejects a caller-supplied disk descriptor whose LUN is not part of the fixed allowlist' {
        $badDisks = @([pscustomobject]@{ Lun = 7; DiskName = 'x'; SizeBytes = 1; DriveLetter = 'X'; FileSystemLabel = 'x'; AllocationUnitBytes = 4096 })
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $badDisks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget -ImdsCompute $script:goodImds
        $result | Should -Not -BeNullOrEmpty
    }

    It 'rejects a caller-supplied DvdLetterMoveTarget for App that is not empty' {
        $result = Test-TargetIdentityMatchesAllowlist -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget 'Z' -ImdsCompute $script:goodImds
        $result | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# 3) OS / temporary disk exclusion before LUN correlation
# =============================================================================

Describe 'Select-NonOsNonTemporaryDiskCandidates' {
    It 'excludes OS (IsBoot/IsSystem) and Temporary (same ScsiBus/ScsiPort as OS) disks, leaving only the real data disk, for a full APP inventory with an OS/Temp LUN collision' {
        $fixture = New-AppRawGuestFixture
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $fixture.Disks
        $result.Error | Should -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 1
        $result.Candidates[0].Number | Should -Be 2
    }

    It 'excludes OS and Temporary disks for a full SQL inventory with an OS/Temp LUN collision, leaving exactly DATA and LOG' {
        $fixture = New-SqlRawGuestFixture
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $fixture.Disks
        $result.Error | Should -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 2
        ($result.Candidates | Select-Object -ExpandProperty Number | Sort-Object) | Should -Be @(2, 3)
    }

    It 'fails when zero disks are flagged boot/system' {
        $disks = @(New-FakeGuestDisk -Number 0 -IsBoot $false -IsSystem $false)
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $disks
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 0
    }

    It 'fails when more than one disk is flagged boot/system (ambiguous OS disk)' {
        $disks = @((New-FakeOsDisk -Number 0), (New-FakeOsDisk -Number 1 -UniqueId 'os2'))
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $disks
        $result.Error | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# 4) Per-disk resolution: wrong resource ID / LUN / size / boot-system
#    selection / ambiguous mapping / stable identity capture
# =============================================================================

Describe 'Resolve-ApprovedDiskTarget' {
    BeforeEach {
        $script:expectedDisk = $script:AllowedApp.Disks[0]
        $script:goodImdsDisks = @(New-FakeImdsDataDisk -Lun 0 -DiskName $script:expectedDisk.DiskName -SizeBytes $script:expectedDisk.SizeBytes)
        $script:goodCandidate = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiLogicalUnit 0
    }

    It 'resolves successfully and captures a stable UniqueId' {
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -BeNullOrEmpty
        $result.Target.DiskNumber | Should -Be 2
        $result.Target.DiskUniqueId | Should -Be 'app-data-uid'
        $result.Target.DriveLetter | Should -Be 'A'
    }

    It 'rejects a wrong managed-disk resource ID (subscription substituted)' {
        $wrongIdDisk = New-FakeImdsDataDisk -Lun 0 -DiskName $script:expectedDisk.DiskName -SizeBytes $script:expectedDisk.SizeBytes `
            -SubscriptionId '11111111-1111-1111-1111-111111111111'
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks @($wrongIdDisk) `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Target | Should -BeNullOrEmpty
    }

    It 'rejects when the LUN does not resolve to exactly one IMDS data disk (zero found)' {
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks @() `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects when the LUN resolves to more than one IMDS data disk (duplicate LUN)' {
        $dupe = New-FakeImdsDataDisk -Lun 0 -DiskName 'some-other-disk' -SizeBytes $script:expectedDisk.SizeBytes
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks @($script:goodImdsDisks[0], $dupe) `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects a size mismatch' {
        $wrongSizeDisk = New-FakeImdsDataDisk -Lun 0 -DiskName $script:expectedDisk.DiskName -SizeBytes ([int64]1 * 1024 * 1024 * 1024)
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks @($wrongSizeDisk) `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects an ambiguous mapping: two non-OS/non-temporary candidate disks share the same LUN' {
        $secondCandidate = New-FakeGuestDisk -Number 5 -UniqueId 'dup' -PartitionStyle 'RAW' -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($script:goodCandidate, $secondCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects selecting a boot/system-flagged disk even if it otherwise matches the LUN (defense in depth, independent of the earlier exclusion step)' {
        $bootCandidate = New-FakeGuestDisk -Number 0 -UniqueId 'boot' -IsBoot $true -IsSystem $true -PartitionStyle 'GPT' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($bootCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects when the resolved guest disk reports no stable UniqueId' {
        $noUidCandidate = New-FakeGuestDisk -Number 2 -UniqueId '' -PartitionStyle 'RAW' -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($noUidCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# 5) Per-disk layout decision: RAW -> Initialize; matching GPT -> NoOp;
#    unexpected partitions/types/sizes/mount paths/partial completion -> Fail
# =============================================================================

Describe 'Get-DiskPreparationPlan' {
    BeforeEach {
        $script:target = [pscustomobject]@{
            DiskNumber = 2; Lun = 0; DiskName = 'appdata'; SizeBytes = ([int64]128 * 1024 * 1024 * 1024)
            DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; AllocationUnitBytes = 4096
        }
    }

    It 'plans Initialize for a RAW disk with zero partitions' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @()
        $result.Action | Should -Be 'Initialize'
    }

    It 'fails a RAW disk that unexpectedly already has partitions (inconsistent state)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        $part = New-FakePartition -DiskNumber 2 -DriveLetter 'A'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($part)
        $result.Action | Should -Be 'Fail'
    }

    It 'plans NoOp for an already-correct GPT layout (tolerating the Windows-generated MSR partition), even when the volume already holds data' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $msr = New-FakeMsrPartition -DiskNumber 2 -PartitionNumber 1
        $data = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A' -Type 'Basic' -SizeBytes $script:target.SizeBytes
        $vol = New-FakeVolume -DriveLetter 'A' -FileSystem 'NTFS' -FileSystemLabel 'LIMS-App' -AllocationUnitSize 4096
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($msr, $data) -Volume $vol
        $result.Action | Should -Be 'NoOp'
    }

    It 'fails a GPT disk with no data partition yet (partial completion)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $msr = New-FakeMsrPartition -DiskNumber 2
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($msr)
        $result.Action | Should -Be 'Fail'
    }

    It 'fails a GPT disk with more than one non-reserved partition' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $p1 = New-FakePartition -DiskNumber 2 -PartitionNumber 1 -DriveLetter 'A' -SizeBytes 1000
        $p2 = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'B' -SizeBytes 1000
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($p1, $p2)
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an unexpected partition type on the data partition' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -Type 'Unknown' -SizeBytes $script:target.SizeBytes
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an undersized data partition layout' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes ([int64]1 * 1024 * 1024 * 1024)
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an unexpected mount path on the data partition' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes -AccessPaths @('A:\', 'C:\Mounts\extra\')
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails a data partition with no formatted volume yet (partial completion)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $null
        $result.Action | Should -Be 'Fail'
    }

    It 'fails (never auto-repairs) a volume with the wrong label, allocation unit size, or drive letter' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 65536 -FileSystemLabel 'Wrong-Label'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an unexpected PartitionStyle (neither RAW nor GPT)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'MBR'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @()
        $result.Action | Should -Be 'Fail'
    }
}

# =============================================================================
# 6) SQL-only DVD-ROM letter-move decision
# =============================================================================

Describe 'Get-DvdPreparationPlan' {
    It 'requires no action when DvdLetterMoveTarget is empty (APP never touches its DVD)' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget '' -EVolumeOrNull $null -ZVolumeOrNull $null -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'NoneRequired'
    }

    It 'treats an already-NoOp (correctly prepared) E: data disk as AlreadyCorrect and never inspects E: for DVD-ness' {
        $loadedDvd = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label 'has-media'
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $loadedDvd -ZVolumeOrNull $null -EDataDiskPlanAction 'NoOp'
        $result.Action | Should -Be 'AlreadyCorrect'
    }

    It 'requires no action when nothing currently occupies E: as a DVD volume' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $null -ZVolumeOrNull $null -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'NoneRequired'
    }

    It 'fails when E: is occupied by a non-DVD-ROM volume' {
        $nonDvd = [pscustomobject]@{ DriveLetter = 'E:'; DriveType = 3; Label = '' }
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $nonDvd -ZVolumeOrNull $null -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the DVD-ROM at E: has loaded media (non-empty label)' {
        $loadedDvd = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label 'Setup Disc'
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $loadedDvd -ZVolumeOrNull $null -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the target letter Z: is already occupied' {
        $emptyDvd = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label ''
        $occupiedZ = New-FakeVolume -DriveLetter 'Z'
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $emptyDvd -ZVolumeOrNull $occupiedZ -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'Fail'
    }

    It 'plans Move when E: is a confirmed empty DVD-ROM and Z: is free' {
        $emptyDvd = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label ''
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EVolumeOrNull $emptyDvd -ZVolumeOrNull $null -EDataDiskPlanAction 'Initialize'
        $result.Action | Should -Be 'Move'
    }
}

# =============================================================================
# 7) Master plan assembly: full APP/SQL inventories, VM-wide blocking
# =============================================================================

Describe 'Get-GuestDiskPreparationPlan' {
    It 'builds a correct, unblocked plan for a complete RAW APP inventory with an OS/Temp LUN collision' {
        $fixture = New-AppRawGuestFixture
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeFalse
        $plan.DiskPlans.Count | Should -Be 1
        $plan.DiskPlans[0].Plan.Action | Should -Be 'Initialize'
        $plan.DiskPlans[0].Target.DiskNumber | Should -Be 2
        $plan.DvdPlan.Action | Should -Be 'NoneRequired'
    }

    It 'builds a correct, unblocked plan for a complete RAW SQL inventory with an OS/Temp LUN collision and an empty DVD at E:, including a Move DVD plan' {
        $fixture = New-SqlRawGuestFixture
        $plan = Invoke-PlanFromFixture -Target 'Sql' -Fixture $fixture
        $plan.Blocked | Should -BeFalse
        $plan.DiskPlans.Count | Should -Be 2
        ($plan.DiskPlans | Where-Object { $_.Target.Lun -eq 0 }).Plan.Action | Should -Be 'Initialize'
        ($plan.DiskPlans | Where-Object { $_.Target.Lun -eq 1 }).Plan.Action | Should -Be 'Initialize'
        $plan.DvdPlan.Action | Should -Be 'Move'
    }

    It 'blocks the ENTIRE VM when SQL LOG validation fails, even though SQL DATA would independently resolve fine' {
        $fixture = New-SqlRawGuestFixture
        # Corrupt the LOG disk's guest-side size so it fails capacity validation.
        $fixture.Disks = @($fixture.Disks | ForEach-Object {
                if ($_.Number -eq 3) { $_.SizeBytes = 1 * 1024 * 1024 * 1024 }
                $_
            })
        $plan = Invoke-PlanFromFixture -Target 'Sql' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
        $plan.Errors.Count | Should -BeGreaterThan 0
    }

    It 'rejects a caller-consistent v1 VM/disk combination even when caller and IMDS fully agree with each other' {
        $fixture = New-AppRawGuestFixture
        $fixture.Imds.name = 'vm-lims-dev-westeu-001'
        $plan = Get-GuestDiskPreparationPlan -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName 'vm-lims-dev-westeu-001' -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget `
            -ImdsCompute $fixture.Imds -ActualComputerName $script:AllowedApp.ComputerName `
            -GuestDiskInventory $fixture.Disks -GuestPartitionInventory $fixture.Partitions `
            -GuestVolumeInventory $fixture.Volumes -GuestDvdVolumeInventory $fixture.DvdVolumes
        $plan.Blocked | Should -BeTrue
    }

    It 'blocks when an ambiguous IMDS LUN mapping exists (two IMDS data disks reporting the same LUN)' {
        $fixture = New-AppRawGuestFixture
        $fixture.Imds.storageProfile.dataDisks += (New-FakeImdsDataDisk -Lun 0 -DiskName 'unexpected-second-disk' -SizeBytes $script:AllowedApp.Disks[0].SizeBytes)
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
    }

    It 'blocks when the actual Windows computer name does not match the allowlist (even if everything else matches)' {
        $fixture = New-AppRawGuestFixture
        $plan = Get-GuestDiskPreparationPlan -Target 'App' `
            -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
            -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
            -ExpectedDisks $script:AllowedApp.Disks -DvdLetterMoveTarget $script:AllowedApp.DvdLetterMoveTarget `
            -ImdsCompute $fixture.Imds -ActualComputerName 'some-other-host' `
            -GuestDiskInventory $fixture.Disks -GuestPartitionInventory $fixture.Partitions `
            -GuestVolumeInventory $fixture.Volumes -GuestDvdVolumeInventory $fixture.DvdVolumes
        $plan.Blocked | Should -BeTrue
    }

    It 'blocks when a drive-letter conflict exists against an unrelated disk elsewhere in the guest' {
        $fixture = New-AppRawGuestFixture
        $fixture.Disks += (New-FakeGuestDisk -Number 9 -PartitionStyle 'GPT' -ScsiBus 0 -ScsiPort 2 -ScsiLogicalUnit 9)
        $fixture.Partitions = @(New-FakePartition -DiskNumber 9 -DriveLetter 'A')
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
    }
}

# =============================================================================
# 8) End-to-end orchestration (Invoke-GuestDiskPreparation), mocking ONLY the
#    *Adapter functions -- never the decision functions above.
# =============================================================================

Describe 'Invoke-GuestDiskPreparation' {
    BeforeEach {
        $script:mutationCalls = [System.Collections.Generic.List[string]]::new()
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { $true }
        Mock Get-CurrentIdentityNameAdapter { 'NT AUTHORITY\SYSTEM' }
        Mock Get-ActualComputerNameAdapter { $script:actualComputerNameToReturn }
        Mock Get-ImdsComputeMetadataAdapter { $script:imdsToReturn }
        Mock Get-GuestDiskInventoryAdapter { $script:diskInventoryToReturn }
        Mock Get-GuestPartitionInventoryAdapter { $script:partitionInventoryToReturn }
        Mock Get-GuestVolumeInventoryAdapter { $script:volumeInventoryToReturn }
        Mock Get-GuestDvdVolumeInventoryAdapter { $script:dvdInventoryToReturn }
        Mock Initialize-ApprovedDiskAdapter { $script:mutationCalls.Add("Initialize:$DiskNumber") }
        Mock New-ApprovedPartitionAdapter {
            $script:mutationCalls.Add("Partition:${DiskNumber}:${DriveLetter}")
            return [pscustomobject]@{ PartitionNumber = 2 }
        }
        Mock Format-ApprovedVolumeAdapter { $script:mutationCalls.Add("Format:${DiskNumber}:${PartitionNumber}") }
        Mock Move-DvdRomLetterAdapter { $script:mutationCalls.Add("Move:${FromLetter}:${ToLetter}") }
        Mock Confirm-DvdRomLetterMoveSucceededAdapter { $true }

        $script:partitionInventoryToReturn = @()
        $script:volumeInventoryToReturn = @()
        $script:dvdInventoryToReturn = @()
    }

    Context 'Apply mode, APP, RAW disk' {
        BeforeEach { Set-AppFixture }

        It 'initializes, partitions, and formats the resolved disk with the exact target identity' {
            Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget ''

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 }
            Should -Invoke New-ApprovedPartitionAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 -and $DriveLetter -eq 'A' }
            Should -Invoke Format-ApprovedVolumeAdapter -Times 1 -ParameterFilter { $AllocationUnitBytes -eq 4096 -and $FileSystemLabel -eq 'LIMS-App' }
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }

        It 'never touches APP''s DVD-ROM even if one exists at E: (DvdLetterMoveTarget is always empty for APP)' {
            $script:dvdInventoryToReturn = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label '')
            Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget ''
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }
    }

    Context 'Apply mode, SQL, RAW disks with DVD at E:' {
        BeforeEach { Set-SqlFixture }

        It 'moves the DVD-ROM before creating the SQL DATA partition at E:, then initializes both disks in LUN order' {
            Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z'

            Should -Invoke Move-DvdRomLetterAdapter -Times 1 -ParameterFilter { $FromLetter -eq 'E' -and $ToLetter -eq 'Z' }
            Should -Invoke Confirm-DvdRomLetterMoveSucceededAdapter -Times 1
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 }
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 3 }
            Should -Invoke New-ApprovedPartitionAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 -and $DriveLetter -eq 'E' }
            Should -Invoke New-ApprovedPartitionAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 3 -and $DriveLetter -eq 'F' }

            $moveIndex = $script:mutationCalls.IndexOf('Move:E:Z')
            $partitionIndex = $script:mutationCalls.IndexOf('Partition:2:E')
            $moveIndex | Should -BeGreaterOrEqual 0
            $partitionIndex | Should -BeGreaterThan $moveIndex
        }

        It 'produces zero mutations of any kind when SQL LOG fails validation -- SQL DATA remains completely untouched' {
            $fixture = New-SqlRawGuestFixture
            $fixture.Disks = @($fixture.Disks | ForEach-Object {
                    if ($_.Number -eq 3) { $_.SizeBytes = 1 * 1024 * 1024 * 1024 }
                    $_
                })
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
            Should -Invoke New-ApprovedPartitionAdapter -Times 0
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }

        It 'produces zero mutations when the DVD at E: has loaded media' {
            $fixture = New-SqlRawGuestFixture
            $fixture.DvdVolumes = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label 'Setup Disc')
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
        }

        It 'produces zero mutations when the target letter Z: is already occupied' {
            $fixture = New-SqlRawGuestFixture
            Set-SqlFixture -Fixture $fixture
            $script:volumeInventoryToReturn = @(New-FakeVolume -DriveLetter 'Z')

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
        }
    }

    Context 'Apply mode, SQL, second (idempotent) run with valid E:/F: already prepared and DVD already at Z:' {
        BeforeEach {
            $fixture = New-SqlRawGuestFixture
            $dataPartition = New-FakePartition -DiskNumber 2 -DriveLetter 'E' -SizeBytes $script:AllowedSql.Disks[0].SizeBytes
            $logPartition = New-FakePartition -DiskNumber 3 -DriveLetter 'F' -SizeBytes $script:AllowedSql.Disks[1].SizeBytes
            $fixture.Disks = @($fixture.Disks | ForEach-Object {
                    if ($_.Number -in @(2, 3)) { $_.PartitionStyle = 'GPT' }
                    $_
                })
            $fixture.Partitions = @($dataPartition, $logPartition)
            $fixture.Volumes = @(
                (New-FakeVolume -DriveLetter 'E' -FileSystem 'NTFS' -FileSystemLabel 'SQL-Data' -AllocationUnitSize 65536)
                (New-FakeVolume -DriveLetter 'F' -FileSystem 'NTFS' -FileSystemLabel 'SQL-Logs' -AllocationUnitSize 65536)
            )
            # DVD already successfully moved to Z: -- no DVD volume reports E: anymore.
            $fixture.DvdVolumes = @(New-FakeDvdVolume -DriveLetter 'Z' -DriveType 5 -Label '')
            Set-SqlFixture -Fixture $fixture
        }

        It 'performs zero mutations of any kind and completes successfully' {
            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Not -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
            Should -Invoke New-ApprovedPartitionAdapter -Times 0
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }
    }

    Context 'Stable identity re-validation immediately before Apply mutation' {
        It 'fails and performs zero mutations when a resolved disk''s UniqueId changes between the first plan and the immediate pre-mutation re-check' {
            $fixtureA = New-AppRawGuestFixture
            $fixtureB = New-AppRawGuestFixture
            ($fixtureB.Disks | Where-Object Number -EQ 2).UniqueId = 'a-different-uid'

            $script:imdsToReturn = $fixtureA.Imds
            $script:actualComputerNameToReturn = $script:AllowedApp.ComputerName
            $script:partitionInventoryToReturn = @()
            $script:volumeInventoryToReturn = @()
            $script:dvdInventoryToReturn = @()

            # $script:-scoped, not a plain local -- each Mock invocation runs
            # in its own child scope, so a plain `$callCount++` here would
            # silently rebind a NEW local variable on every call (always
            # incrementing 0 -> 1) rather than persisting across calls,
            # which would make every call return $fixtureA.Disks and defeat
            # this entire test.
            $script:callCount = 0
            Mock Get-GuestDiskInventoryAdapter {
                $script:callCount++
                if ($script:callCount -eq 1) { return $fixtureA.Disks }
                return $fixtureB.Disks
            }

            { Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                    -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget '' } | Should -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
            Should -Invoke New-ApprovedPartitionAdapter -Times 0
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
        }
    }

    Context 'Query failures must propagate as hard failures, never as benign empty results' {
        It 'throws (and performs zero mutations) when the guest partition inventory query fails' {
            Set-AppFixture
            Mock Get-GuestPartitionInventoryAdapter { throw 'Simulated WMI/CIM query failure.' }

            { Invoke-GuestDiskPreparation -Target 'App' -Mode 'Validate' `
                    -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                    -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget '' } | Should -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
        }
    }

    Context 'Non-administrator/non-SYSTEM execution context' {
        It 'refuses to build any plan at all when not running as Administrator or SYSTEM' {
            Set-AppFixture
            Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { $false }

            { Invoke-GuestDiskPreparation -Target 'App' -Mode 'Validate' `
                    -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                    -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget '' } | Should -Throw

            Should -Invoke Get-ImdsComputeMetadataAdapter -Times 0
        }
    }

    Context 'Validate mode issues zero mutation calls, for every scenario -- including failing ones' {
        BeforeEach {
            $script:failingSqlFixture = New-SqlRawGuestFixture
            $script:failingSqlFixture.Disks = @($script:failingSqlFixture.Disks | ForEach-Object {
                    if ($_.Number -eq 3) { $_.SizeBytes = 1 * 1024 * 1024 * 1024 }
                    $_
                })
            $script:loadedDvdSqlFixture = New-SqlRawGuestFixture
            $script:loadedDvdSqlFixture.DvdVolumes = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label 'Setup Disc')
        }

        It 'issues zero mutation calls for scenario "<Name>"' -TestCases @(
            @{ Name = 'APP RAW happy path'; Target = 'App'; Fixture = { New-AppRawGuestFixture } }
            @{ Name = 'SQL RAW happy path with DVD move pending'; Target = 'Sql'; Fixture = { New-SqlRawGuestFixture } }
            @{ Name = 'SQL LOG validation failure'; Target = 'Sql'; Fixture = { $script:failingSqlFixture } }
            @{ Name = 'SQL loaded DVD media'; Target = 'Sql'; Fixture = { $script:loadedDvdSqlFixture } }
        ) {
            param($Target, $Fixture)
            $fixtureValue = & $Fixture
            if ($Target -eq 'App') { Set-AppFixture -Fixture $fixtureValue } else { Set-SqlFixture -Fixture $fixtureValue }
            $allowlistEntry = if ($Target -eq 'App') { $script:AllowedApp } else { $script:AllowedSql }

            # Either throws (blocked) or completes -- either way, zero
            # mutation adapter calls is the only thing asserted here, since
            # Validate mode must never reach a mutating adapter regardless
            # of outcome.
            try {
                Invoke-GuestDiskPreparation -Target $Target -Mode 'Validate' `
                    -ExpectedSubscriptionId $allowlistEntry.SubscriptionId -ExpectedResourceGroupName $allowlistEntry.ResourceGroupName `
                    -ExpectedVmName $allowlistEntry.VmName -ExpectedComputerName $allowlistEntry.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $allowlistEntry.Disks) -DvdLetterMoveTarget $allowlistEntry.DvdLetterMoveTarget
            }
            catch { }

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
            Should -Invoke New-ApprovedPartitionAdapter -Times 0
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }
    }
}

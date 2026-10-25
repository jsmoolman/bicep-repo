<#
    Pester tests for Initialize-LimsGuestDataDisks.ps1.

    SCOPE / WHAT THESE TESTS ARE -- AND ARE NOT.

    These tests run on Ubuntu CI (Pester on Linux; no pwsh/Windows Storage
    module, Windows CIM schemas, Win32_DiskDrive/Win32_Volume/Win32_CDROMDrive,
    or administrator/SYSTEM APIs are required or available here) and
    exercise exactly two kinds of code in the real script, unmodified:

      1. The DECISION/PLANNING functions (Get-ApprovedDiskPreparationAllowlist,
         Test-TargetIdentityMatchesAllowlist, Select-NonOsNonTemporaryDiskCandidates,
         Resolve-ApprovedDiskTarget, Get-DiskPreparationPlan, Get-DvdPreparationPlan,
         Test-DestinationLetterOccupied, Get-GuestDiskPreparationPlan,
         Test-DiskReadyForInitializeStage, Test-DiskReadyForNewPartitionStage,
         Test-PartitionReadyForFormatStage) -- called directly, for real,
         with plain fake data objects. This is where the actual safety logic
         lives, and it is Linux-testable because these functions never call
         a real cmdlet.

      2. The ORCHESTRATION function (Invoke-GuestDiskPreparation, via
         Get-FreshGuestDiskPreparationPlan) -- called for real, but with
         every *Adapter function (the only functions that would call a real
         Windows cmdlet) replaced with a Pester Mock. The decision logic
         inside Invoke-GuestDiskPreparation is never mocked or bypassed --
         only the adapters are, per the task's explicit instruction to
         "mock the adapters, not the entire safety decision process". The
         mutation-adapter mocks used here deliberately simulate the
         resulting guest state change (e.g. Initialize-Disk's mock flips
         the simulated disk from RAW to GPT and adds the Windows-generated
         MSR partition) so that this script's own NEW immediate per-stage
         re-checks (Assert-DiskReadyForDestructiveStage) see a realistic,
         self-consistent state progression across a single Apply run --
         exactly the "expected, in-progress state change caused by this
         same invocation's own prior steps" the real script is designed to
         recognize as correct.

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

    # Independently hand-written literal, matching the real script's own
    # $script:BasicDataPartitionGptType -- used as the default, realistic
    # GptType for fixture partitions. https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
    $script:TestBasicDataGptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $script:TestDefaultTempDiskSizeBytes = [int64]150 * 1024 * 1024 * 1024

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
            [object[]] $DataDisks = @(),
            # Matches New-FakeTempDisk's own default SizeBytes, so fixtures
            # are realistic and self-consistent by default: IMDS's own
            # authoritative report of the temporary disk's size agrees with
            # the guest-reported size of the fixture's fake temporary disk,
            # exactly as real IMDS/Get-Disk would. Pass a different value
            # (or $null, or 0) explicitly to test a mismatch/absence/
            # no-temp-disk scenario.
            [int64] $ResourceDiskSizeBytes = $script:TestDefaultTempDiskSizeBytes
        )
        return [pscustomobject]@{
            subscriptionId    = $SubscriptionId
            resourceGroupName = $ResourceGroupName
            name              = $Name
            storageProfile    = [pscustomobject]@{
                dataDisks    = @($DataDisks)
                resourceDisk = [pscustomobject]@{ size = [int64]($ResourceDiskSizeBytes / 1024) }
            }
        }
    }

    function New-FakeGuestDisk {
        param(
            [Parameter(Mandatory = $true)] [int] $Number,
            [string] $UniqueId = ([guid]::NewGuid().ToString()),
            [bool] $IsBoot = $false,
            [bool] $IsSystem = $false,
            [bool] $IsOffline = $false,
            [bool] $IsReadOnly = $false,
            [string] $OperationalStatus = 'Online',
            [string] $PartitionStyle = 'RAW',
            [int64] $SizeBytes = 0,
            [int] $ScsiBus = 0,
            [int] $ScsiPort = 1,
            [int] $ScsiTargetId = 0,
            [int] $ScsiLogicalUnit = 0,
            [string] $FriendlyName = 'Fake Managed Disk'
        )
        return [pscustomobject]@{
            Number            = $Number
            UniqueId          = $UniqueId
            IsBoot            = $IsBoot
            IsSystem          = $IsSystem
            IsOffline         = $IsOffline
            IsReadOnly        = $IsReadOnly
            OperationalStatus = $OperationalStatus
            PartitionStyle    = $PartitionStyle
            SizeBytes         = $SizeBytes
            ScsiBus           = $ScsiBus
            ScsiPort          = $ScsiPort
            ScsiTargetId      = $ScsiTargetId
            ScsiLogicalUnit   = $ScsiLogicalUnit
            FriendlyName      = $FriendlyName
        }
    }

    function New-FakeOsDisk {
        param([int] $Number = 0, [string] $UniqueId = 'os-disk-uid')
        return New-FakeGuestDisk -Number $Number -UniqueId $UniqueId -IsBoot $true -IsSystem $true `
            -PartitionStyle 'GPT' -SizeBytes (127 * 1024 * 1024 * 1024) -ScsiBus 0 -ScsiPort 0 -ScsiTargetId 0 -ScsiLogicalUnit 0
    }

    function New-FakeTempDisk {
        param([int] $Number = 1, [string] $UniqueId = 'temp-disk-uid')
        # ScsiLogicalUnit=1 deliberately COLLIDES with SQL LOG's own
        # approved Azure LUN (1) -- this is this script's own guest-only
        # SCSI numbering, never the Azure LUN namespace, and is kept
        # specifically so the SQL fixture continues to prove that the
        # temporary disk is excluded via Select-NonOsNonTemporaryDiskCandidates
        # BEFORE LUN correlation ever runs, not merely by coincidence.
        # SizeBytes matches New-FakeImdsCompute's own default
        # ResourceDiskSizeBytes -- the positive, cross-referenced evidence
        # this script now actually uses to identify it.
        return New-FakeGuestDisk -Number $Number -UniqueId $UniqueId -IsBoot $false -IsSystem $false `
            -PartitionStyle 'RAW' -SizeBytes $script:TestDefaultTempDiskSizeBytes -ScsiBus 0 -ScsiPort 0 -ScsiTargetId 0 -ScsiLogicalUnit 1
    }

    function New-FakePartition {
        param(
            [Parameter(Mandatory = $true)] [int] $DiskNumber,
            [int] $PartitionNumber = 1,
            [string] $DriveLetter = '',
            [string] $GptType = $script:TestBasicDataGptType,
            [string] $Type = 'Basic',
            [int64] $SizeBytes = 0,
            [string] $VolumeGuid = ([guid]::NewGuid().ToString()),
            # When $DriveLetter is set and -AccessPaths is not explicitly
            # supplied, the default AccessPaths shape is the REALISTIC one
            # Windows actually reports for a formatted basic data partition
            # -- both the drive-letter root AND this partition's own volume
            # GUID path (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume)
            # -- not merely the drive-letter root alone. Set this to $false
            # to build a partition missing that access path on purpose.
            [bool] $IncludeVolumeGuidPath = $true,
            [string[]] $AccessPaths
        )
        if (-not $PSBoundParameters.ContainsKey('AccessPaths')) {
            $AccessPaths = @()
            if ($DriveLetter) { $AccessPaths += "${DriveLetter}:\" }
            if ($IncludeVolumeGuidPath -and $DriveLetter) { $AccessPaths += "\\?\Volume{$VolumeGuid}\" }
        }
        return [pscustomobject]@{
            DiskNumber      = $DiskNumber
            PartitionNumber = $PartitionNumber
            DriveLetter     = $DriveLetter
            GptType         = $GptType
            Type            = $Type
            SizeBytes       = $SizeBytes
            AccessPaths     = @($AccessPaths)
            VolumeGuid      = $VolumeGuid
        }
    }

    function New-FakeMsrPartition {
        param([Parameter(Mandatory = $true)] [int] $DiskNumber, [int] $PartitionNumber = 1)
        return New-FakePartition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber `
            -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Type 'Reserved' -SizeBytes (16 * 1024 * 1024) -IncludeVolumeGuidPath $false
    }

    function New-FakeVolume {
        param(
            [string] $DriveLetter,
            [string] $FileSystem = 'NTFS',
            [string] $FileSystemLabel = '',
            [int64] $AllocationUnitSize = 4096,
            [int64] $SizeBytes = 0,
            # Get-Volume's own Path property is exactly this GUID-path
            # string -- the documented identifier used to correlate a
            # partition's AccessPaths to this specific volume. Pass the
            # SAME VolumeGuid used when building the paired partition (see
            # New-FakeFormattedPartitionAndVolume) to build a realistic,
            # self-consistent pair; a deliberately DIFFERENT VolumeGuid
            # builds a "foreign volume" for negative tests.
            [string] $VolumeGuid = ([guid]::NewGuid().ToString())
        )
        return [pscustomobject]@{
            DriveLetter        = $DriveLetter
            FileSystem         = $FileSystem
            FileSystemLabel    = $FileSystemLabel
            AllocationUnitSize = $AllocationUnitSize
            SizeBytes          = $SizeBytes
            Path               = "\\?\Volume{$VolumeGuid}\"
        }
    }

    function New-FakeFormattedPartitionAndVolume {
        <#
            Builds a realistic, self-consistent (partition, volume) pair
            sharing the same volume GUID -- exactly the shape a correctly
            formatted basic data partition and its own volume report in
            real life. Used everywhere a NoOp / already-correct layout
            needs to be constructed, per the task's explicit instruction to
            test with fixtures containing both the drive root and the
            volume GUID path.
        #>
        param(
            [Parameter(Mandatory = $true)] [int] $DiskNumber,
            [Parameter(Mandatory = $true)] [string] $DriveLetter,
            [int] $PartitionNumber = 2,
            [int64] $SizeBytes = 0,
            [string] $FileSystemLabel = '',
            [int64] $AllocationUnitSize = 4096,
            [string] $FileSystem = 'NTFS'
        )
        $guid = [guid]::NewGuid().ToString()
        $partition = New-FakePartition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -DriveLetter $DriveLetter -SizeBytes $SizeBytes -VolumeGuid $guid
        $volume = New-FakeVolume -DriveLetter $DriveLetter -FileSystem $FileSystem -FileSystemLabel $FileSystemLabel -AllocationUnitSize $AllocationUnitSize -SizeBytes $SizeBytes -VolumeGuid $guid
        return [pscustomobject]@{ Partition = $partition; Volume = $volume }
    }

    function New-FakeDvdVolume {
        param([string] $DriveLetter, [int] $DriveType = 5, [string] $Label = '')
        return [pscustomobject]@{ DriveLetter = "${DriveLetter}:"; DriveType = $DriveType; Label = $Label }
    }

    function New-FakeOpticalDrive {
        <#
            Win32_CDROMDrive -- https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive.
            MediaLoaded defaults to $false (positively confirmed empty);
            pass $null to simulate "unknown" or $true to simulate loaded
            media.
        #>
        param(
            [string] $DeviceId = '\\.\CDROM0',
            [string] $Name = 'Microsoft Virtual DVD-ROM',
            [string] $Drive = '',
            $MediaLoaded = $false
        )
        return [pscustomobject]@{ DeviceId = $DeviceId; Name = $Name; Drive = $Drive; MediaLoaded = $MediaLoaded }
    }

    function ConvertTo-ExpectedDisksJson {
        param([Parameter(Mandatory = $true)] [object[]] $Disks)
        return (ConvertTo-Json -InputObject @($Disks) -Depth 5)
    }

    # Full, approved, RAW APP guest inventory: OS (excluded by IsBoot/
    # IsSystem), Temporary (excluded by its size matching IMDS's own
    # reported resourceDisk.size), and the one approved APP data disk at
    # LUN 0, RAW, no partitions.
    function New-AppRawGuestFixture {
        $osDisk = New-FakeOsDisk
        $tempDisk = New-FakeTempDisk
        $dataDisk = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedApp.Disks[0].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 0
        return [pscustomobject]@{
            Disks         = @($osDisk, $tempDisk, $dataDisk)
            Partitions    = @()
            Volumes       = @()
            DvdVolumes    = @()
            OpticalDrives = @()
            Imds          = New-FakeImdsCompute -Name $script:AllowedApp.VmName -DataDisks @(
                New-FakeImdsDataDisk -Lun 0 -DiskName $script:AllowedApp.Disks[0].DiskName -SizeBytes $script:AllowedApp.Disks[0].SizeBytes
            )
        }
    }

    # Full, approved, RAW SQL guest inventory: OS, Temporary (excluded by
    # size, even though its guest-only SCSI numbering collides with SQL
    # LOG's Azure LUN), SQL DATA at LUN 0 and SQL LOG at LUN 1 (both RAW, no
    # partitions), plus an empty, unlabelled virtual DVD-ROM device and
    # volume at E: (positively verified) and Z: free.
    function New-SqlRawGuestFixture {
        $osDisk = New-FakeOsDisk
        $tempDisk = New-FakeTempDisk
        $dataDisk = New-FakeGuestDisk -Number 2 -UniqueId 'sql-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedSql.Disks[0].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 0
        $logDisk = New-FakeGuestDisk -Number 3 -UniqueId 'sql-log-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:AllowedSql.Disks[1].SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiTargetId 0 -ScsiLogicalUnit 1
        return [pscustomobject]@{
            Disks         = @($osDisk, $tempDisk, $dataDisk, $logDisk)
            Partitions    = @()
            Volumes       = @()
            DvdVolumes    = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label '')
            OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name $script:AllowedSql.ExpectedOpticalDriveName -Drive 'E:' -MediaLoaded $false)
            Imds          = New-FakeImdsCompute -SubscriptionId $script:AllowedSql.SubscriptionId `
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
            -GuestVolumeInventory $Fixture.Volumes -GuestDvdVolumeInventory $Fixture.DvdVolumes `
            -GuestOpticalDriveInventory $Fixture.OpticalDrives
    }

    # Used only by the 'Invoke-GuestDiskPreparation' Describe block below --
    # defined here (BeforeAll) rather than directly in that Describe body,
    # since Pester v5 does not guarantee plain function definitions written
    # directly in a Describe block are visible from It/BeforeEach at Run
    # time (they only run at Discovery time there). These set the mutable,
    # $script:-scoped "simulated guest state" that every stateful mock in
    # that Describe block reads from and (for mutation-adapter mocks)
    # writes back to.
    function Set-AppFixture {
        param($Fixture = (New-AppRawGuestFixture))
        $script:simulatedImds = $Fixture.Imds
        $script:actualComputerNameToReturn = $script:AllowedApp.ComputerName
        $script:simulatedDisks = $Fixture.Disks
        $script:simulatedPartitions = $Fixture.Partitions
        $script:simulatedVolumes = $Fixture.Volumes
        $script:simulatedDvdVolumes = $Fixture.DvdVolumes
        $script:simulatedOpticalDrives = $Fixture.OpticalDrives
        $script:simulatedExpectedSizeByDisk = @{ 2 = $script:AllowedApp.Disks[0].SizeBytes }
    }

    function Set-SqlFixture {
        param($Fixture = (New-SqlRawGuestFixture))
        $script:simulatedImds = $Fixture.Imds
        $script:actualComputerNameToReturn = $script:AllowedSql.ComputerName
        $script:simulatedDisks = $Fixture.Disks
        $script:simulatedPartitions = $Fixture.Partitions
        $script:simulatedVolumes = $Fixture.Volumes
        $script:simulatedDvdVolumes = $Fixture.DvdVolumes
        $script:simulatedOpticalDrives = $Fixture.OpticalDrives
        $script:simulatedExpectedSizeByDisk = @{ 2 = $script:AllowedSql.Disks[0].SizeBytes; 3 = $script:AllowedSql.Disks[1].SizeBytes }
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
        $allowlist.App.ExpectedOpticalDriveName | Should -Be ''
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
        $allowlist.Sql.ExpectedOpticalDriveName | Should -Be 'Microsoft Virtual DVD-ROM'
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
# 3) OS / temporary disk exclusion before LUN correlation -- positive
#    evidence (IMDS resourceDisk.size cross-referenced against guest size),
#    never guest-only topology/port numbers.
# =============================================================================

Describe 'Select-NonOsNonTemporaryDiskCandidates' {
    It 'excludes OS and Temporary disks for APP via positive IMDS resourceDisk.size cross-reference, leaving only the real data disk' {
        $fixture = New-AppRawGuestFixture
        $sizeBytes = Get-ImdsResourceDiskSizeBytes -ImdsCompute $fixture.Imds
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $fixture.Disks -ImdsResourceDiskSizeBytes $sizeBytes
        $result.Error | Should -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 1
        $result.Candidates[0].Number | Should -Be 2
    }

    It 'excludes OS and Temporary disks for SQL, leaving exactly DATA and LOG, even though the temporary disk''s own guest-only SCSI numbering collides with LOG''s Azure LUN' {
        $fixture = New-SqlRawGuestFixture
        $sizeBytes = Get-ImdsResourceDiskSizeBytes -ImdsCompute $fixture.Imds
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $fixture.Disks -ImdsResourceDiskSizeBytes $sizeBytes
        $result.Error | Should -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 2
        ($result.Candidates | Select-Object -ExpandProperty Number | Sort-Object) | Should -Be @(2, 3)
    }

    It 'fails when zero disks are flagged boot/system' {
        $disks = @(New-FakeGuestDisk -Number 0 -IsBoot $false -IsSystem $false)
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $disks -ImdsResourceDiskSizeBytes $script:TestDefaultTempDiskSizeBytes
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 0
    }

    It 'fails when more than one disk is flagged boot/system (ambiguous OS disk)' {
        $disks = @((New-FakeOsDisk -Number 0), (New-FakeOsDisk -Number 1 -UniqueId 'os2'))
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $disks -ImdsResourceDiskSizeBytes $script:TestDefaultTempDiskSizeBytes
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'fails closed when IMDS does not report resourceDisk.size at all (as opposed to reporting it as zero)' {
        $fixture = New-AppRawGuestFixture
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $fixture.Disks -ImdsResourceDiskSizeBytes $null
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 0
    }

    It 'treats resourceDisk.size=0 (no temporary disk for this VM size) as excluding nothing beyond the OS disk' {
        $osDisk = New-FakeOsDisk
        $dataDisk = New-FakeGuestDisk -Number 2 -UniqueId 'data' -PartitionStyle 'RAW' -SizeBytes (150 * 1024 * 1024 * 1024) -ScsiLogicalUnit 0
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory @($osDisk, $dataDisk) -ImdsResourceDiskSizeBytes ([int64]0)
        $result.Error | Should -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 1
        $result.Candidates[0].Number | Should -Be 2
    }

    It 'fails when more than one non-OS disk''s size matches Azure''s own reported temporary disk size (ambiguous)' {
        $osDisk = New-FakeOsDisk
        $tempLike1 = New-FakeGuestDisk -Number 1 -UniqueId 't1' -SizeBytes $script:TestDefaultTempDiskSizeBytes -ScsiLogicalUnit 1
        $tempLike2 = New-FakeGuestDisk -Number 4 -UniqueId 't2' -SizeBytes $script:TestDefaultTempDiskSizeBytes -ScsiLogicalUnit 4
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory @($osDisk, $tempLike1, $tempLike2) -ImdsResourceDiskSizeBytes $script:TestDefaultTempDiskSizeBytes
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 0
    }

    It 'fails when a non-OS disk reports missing/invalid SCSI addressing' {
        $osDisk = New-FakeOsDisk
        $badDisk = New-FakeGuestDisk -Number 2 -UniqueId 'bad' -SizeBytes (128 * 1024 * 1024 * 1024) -ScsiBus -1 -ScsiPort -1 -ScsiTargetId -1 -ScsiLogicalUnit -1
        $result = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory @($osDisk, $badDisk) -ImdsResourceDiskSizeBytes $script:TestDefaultTempDiskSizeBytes
        $result.Error | Should -Not -BeNullOrEmpty
        $result.Candidates.Count | Should -Be 0
    }
}

# =============================================================================
# 4) Per-disk resolution: wrong resource ID / LUN / size / boot-system
#    selection / ambiguous mapping / unsuitable state / stable identity
#    capture
# =============================================================================

Describe 'Resolve-ApprovedDiskTarget' {
    BeforeEach {
        $script:expectedDisk = $script:AllowedApp.Disks[0]
        $script:goodImdsDisks = @(New-FakeImdsDataDisk -Lun 0 -DiskName $script:expectedDisk.DiskName -SizeBytes $script:expectedDisk.SizeBytes)
        $script:goodCandidate = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiBus 0 -ScsiPort 1 -ScsiLogicalUnit 0
    }

    It 'resolves successfully, captures a stable UniqueId, and carries disk state fields through for reporting' {
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($script:goodCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -BeNullOrEmpty
        $result.Target.DiskNumber | Should -Be 2
        $result.Target.DiskUniqueId | Should -Be 'app-data-uid'
        $result.Target.DriveLetter | Should -Be 'A'
        $result.Target.IsOffline | Should -BeFalse
        $result.Target.IsReadOnly | Should -BeFalse
        $result.Target.OperationalStatus | Should -Be 'Online'
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

    It 'rejects an offline candidate disk' {
        $offlineCandidate = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0 -IsOffline $true
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($offlineCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects a read-only candidate disk' {
        $readOnlyCandidate = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0 -IsReadOnly $true
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($readOnlyCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
            -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'rejects a candidate disk with a non-Online operational status' {
        $unhealthyCandidate = New-FakeGuestDisk -Number 2 -UniqueId 'app-data-uid' -PartitionStyle 'RAW' `
            -SizeBytes $script:expectedDisk.SizeBytes -ScsiLogicalUnit 0 -OperationalStatus 'Degraded'
        $result = Resolve-ApprovedDiskTarget -ExpectedDisk $script:expectedDisk -ImdsDataDisks $script:goodImdsDisks `
            -CandidateGuestDisks @($unhealthyCandidate) -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId `
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
#    unexpected partitions/types/sizes/mount paths/volume correlation/
#    partial completion -> Fail
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

    It 'plans NoOp for an already-correct GPT layout with a realistic drive-root + volume-GUID AccessPaths pair, even when the volume already holds data' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $msr = New-FakeMsrPartition -DiskNumber 2 -PartitionNumber 1
        $pair = New-FakeFormattedPartitionAndVolume -DiskNumber 2 -DriveLetter 'A' -PartitionNumber 2 -SizeBytes $script:target.SizeBytes -FileSystemLabel 'LIMS-App' -AllocationUnitSize 4096
        $pair.Partition.AccessPaths.Count | Should -Be 2
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($msr, $pair.Partition) -Volume $pair.Volume
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

    It 'rejects an unexpected GPT partition type via the exact GptType GUID, even when the friendly Type string says Basic' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        # EFI System Partition GUID, not Basic Data -- but Type string
        # still (unrealistically) says 'Basic', proving the exact GptType
        # check -- not the friendly Type string -- is what actually gates
        # this. https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -Type 'Basic'
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an undersized data partition layout' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes ([int64]1 * 1024 * 1024 * 1024)
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an additional directory mount beyond the approved drive root and the partition''s own volume GUID path' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $pair = New-FakeFormattedPartitionAndVolume -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes -FileSystemLabel 'LIMS-App' -AllocationUnitSize 4096
        $pair.Partition.AccessPaths += 'C:\Mounts\extra\'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($pair.Partition) -Volume $pair.Volume
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the data partition is missing its own volume GUID access path entirely' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes -IncludeVolumeGuidPath $false
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the partition reports more than one volume GUID access path (ambiguous)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        $data.AccessPaths += "\\?\Volume{$([guid]::NewGuid().ToString())}\"
        $vol = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $vol
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the partition''s volume GUID path belongs to a different (foreign) volume than the one correlated' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        # Deliberately NOT built with $data's own VolumeGuid.
        $foreignVolume = New-FakeVolume -DriveLetter 'A' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $foreignVolume
        $result.Action | Should -Be 'Fail'
    }

    It 'fails a data partition with no formatted volume yet (partial completion)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $null
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the correlated volume''s drive letter conflicts with the partition''s own drive letter' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes
        $conflictingVolume = New-FakeVolume -DriveLetter 'B' -AllocationUnitSize 4096 -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($data) -Volume $conflictingVolume
        $result.Action | Should -Be 'Fail'
    }

    It 'fails (never auto-repairs) a volume with the wrong label, allocation unit size, or drive letter' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $pair = New-FakeFormattedPartitionAndVolume -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:target.SizeBytes -FileSystemLabel 'Wrong-Label' -AllocationUnitSize 65536
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @($pair.Partition) -Volume $pair.Volume
        $result.Action | Should -Be 'Fail'
    }

    It 'fails an unexpected PartitionStyle (neither RAW nor GPT)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'MBR'
        $result = Get-DiskPreparationPlan -Target $script:target -GuestDisk $disk -Partitions @()
        $result.Action | Should -Be 'Fail'
    }
}

# =============================================================================
# 6) SQL-only DVD-ROM letter-move decision -- positive Win32_CDROMDrive
#    verification, never an empty Win32_Volume label alone.
# =============================================================================

Describe 'Get-DvdPreparationPlan' {
    BeforeEach {
        $script:goodDrive = New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $false
        $script:goodVolume = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label ''
    }

    It 'requires no action when DvdLetterMoveTarget is empty (APP never touches its DVD)' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget '' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName '' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'NoneRequired'
    }

    It 'treats an already-NoOp (correctly prepared) E: data disk as AlreadyCorrect and never inspects E: for DVD-ness' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'NoOp' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @() -EDvdVolumes @() -DestinationOccupied $false
        $result.Action | Should -Be 'AlreadyCorrect'
    }

    It 'requires no action when nothing currently occupies E: as an optical device or DVD volume' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @() -EDvdVolumes @() -DestinationOccupied $false
        $result.Action | Should -Be 'NoneRequired'
    }

    It 'fails when exactly one of the optical device / DVD volume at E: is present but not the other (ambiguous correlation)' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @() -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when more than one optical device reports E: (ambiguous)' {
        $dupe = New-FakeOpticalDrive -DeviceId '\\.\CDROM1' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $false
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive, $dupe) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the optical device reports an unexpected device name' {
        $wrongName = New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Some Other Virtual Drive' -Drive 'E:' -MediaLoaded $false
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($wrongName) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the media-loaded state is unknown ($null) rather than positively confirmed empty' {
        $unknown = New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $null
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($unknown) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when media is loaded, even if the Win32_Volume label is empty' {
        $loaded = New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $true
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($loaded) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when MediaLoaded is false but the volume has a non-empty label (inconsistent state)' {
        $loadedVolume = New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label 'Setup Disc'
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @($loadedVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the volume at E: is not CD-ROM-type (DriveType != 5)' {
        $nonDvd = [pscustomobject]@{ DriveLetter = 'E:'; DriveType = 3; Label = '' }
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @($nonDvd) -DestinationOccupied $false
        $result.Action | Should -Be 'Fail'
    }

    It 'fails when the target letter is already occupied' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $true
        $result.Action | Should -Be 'Fail'
    }

    It 'plans Move when the optical device at E: is positively verified and the destination is free, returning the device identity' {
        $result = Get-DvdPreparationPlan -DvdLetterMoveTarget 'Z' -EDataDiskPlanAction 'Initialize' -ExpectedOpticalDriveName 'Microsoft Virtual DVD-ROM' `
            -EOpticalDrives @($script:goodDrive) -EDvdVolumes @($script:goodVolume) -DestinationOccupied $false
        $result.Action | Should -Be 'Move'
        $result.DeviceId | Should -Be '\\.\CDROM0'
    }
}

# =============================================================================
# 7) Destination-letter occupancy, checked across every relevant inventory
# =============================================================================

Describe 'Test-DestinationLetterOccupied' {
    It 'returns $false when the letter is free across every inventory' {
        Test-DestinationLetterOccupied -Letter 'Z' -OpticalDrives @() -DvdVolumes @() -Volumes @() -Partitions @() | Should -BeFalse
    }

    It 'returns $true when an optical device reports the letter' {
        Test-DestinationLetterOccupied -Letter 'Z' -OpticalDrives @(New-FakeOpticalDrive -Drive 'Z:') -DvdVolumes @() -Volumes @() -Partitions @() | Should -BeTrue
    }

    It 'returns $true when a DVD volume reports the letter' {
        Test-DestinationLetterOccupied -Letter 'Z' -OpticalDrives @() -DvdVolumes @(New-FakeDvdVolume -DriveLetter 'Z') -Volumes @() -Partitions @() | Should -BeTrue
    }

    It 'returns $true when an ordinary volume reports the letter' {
        Test-DestinationLetterOccupied -Letter 'Z' -OpticalDrives @() -DvdVolumes @() -Volumes @(New-FakeVolume -DriveLetter 'Z') -Partitions @() | Should -BeTrue
    }

    It 'returns $true when a partition reports the letter' {
        Test-DestinationLetterOccupied -Letter 'Z' -OpticalDrives @() -DvdVolumes @() -Volumes @() -Partitions @(New-FakePartition -DiskNumber 9 -DriveLetter 'Z') | Should -BeTrue
    }
}

# =============================================================================
# 8) Finding 4's three pure, per-stage shape assertions
# =============================================================================

Describe 'Test-DiskReadyForInitializeStage' {
    BeforeEach { $script:stageTarget = [pscustomobject]@{ DiskNumber = 2; DriveLetter = 'A' } }

    It 'returns $null (ready) for a healthy RAW disk with zero partitions and a free drive letter' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        Test-DiskReadyForInitializeStage -GuestDisk $disk -Partitions @() -Target $script:stageTarget -AllGuestPartitions @() | Should -BeNullOrEmpty
    }

    It 'fails when the disk can no longer be found' {
        Test-DiskReadyForInitializeStage -GuestDisk $null -Partitions @() -Target $script:stageTarget -AllGuestPartitions @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the disk is offline' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW' -IsOffline $true
        Test-DiskReadyForInitializeStage -GuestDisk $disk -Partitions @() -Target $script:stageTarget -AllGuestPartitions @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the disk is no longer RAW' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        Test-DiskReadyForInitializeStage -GuestDisk $disk -Partitions @() -Target $script:stageTarget -AllGuestPartitions @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the disk already has partitions' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        $part = New-FakePartition -DiskNumber 2 -DriveLetter 'A'
        Test-DiskReadyForInitializeStage -GuestDisk $disk -Partitions @($part) -Target $script:stageTarget -AllGuestPartitions @($part) | Should -Not -BeNullOrEmpty
    }

    It 'fails when the approved drive letter is now in use by a different disk' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        $conflict = New-FakePartition -DiskNumber 9 -DriveLetter 'A'
        Test-DiskReadyForInitializeStage -GuestDisk $disk -Partitions @() -Target $script:stageTarget -AllGuestPartitions @($conflict) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-DiskReadyForNewPartitionStage' {
    It 'returns $null (ready) for a healthy GPT disk with only the Windows-generated MSR partition' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $msr = New-FakeMsrPartition -DiskNumber 2
        Test-DiskReadyForNewPartitionStage -GuestDisk $disk -Partitions @($msr) | Should -BeNullOrEmpty
    }

    It 'fails when the disk can no longer be found' {
        Test-DiskReadyForNewPartitionStage -GuestDisk $null -Partitions @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the disk is not GPT' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'RAW'
        Test-DiskReadyForNewPartitionStage -GuestDisk $disk -Partitions @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when a non-reserved partition already exists (unexpectedly, before New-Partition was even called)' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        $msr = New-FakeMsrPartition -DiskNumber 2
        $data = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A'
        Test-DiskReadyForNewPartitionStage -GuestDisk $disk -Partitions @($msr, $data) | Should -Not -BeNullOrEmpty
    }

    It 'fails when zero Microsoft Reserved partitions are present' {
        $disk = New-FakeGuestDisk -Number 2 -PartitionStyle 'GPT'
        Test-DiskReadyForNewPartitionStage -GuestDisk $disk -Partitions @() | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PartitionReadyForFormatStage' {
    BeforeEach { $script:stageTarget = [pscustomobject]@{ DriveLetter = 'A'; SizeBytes = ([int64]128 * 1024 * 1024 * 1024) } }

    It 'returns $null (ready) for the exact newly created data partition with no existing filesystem' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A' -SizeBytes $script:stageTarget.SizeBytes
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -BeNullOrEmpty
    }

    It 'fails when there is not exactly one data partition' {
        Test-PartitionReadyForFormatStage -Partitions @() -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the partition number no longer matches the one just created' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 3 -DriveLetter 'A' -SizeBytes $script:stageTarget.SizeBytes
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the GPT type is no longer the exact Basic Data type' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A' -SizeBytes $script:stageTarget.SizeBytes -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the size no longer matches the expected disk capacity' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A' -SizeBytes ([int64]1 * 1024 * 1024 * 1024)
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when the drive letter no longer matches the approved target' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'B' -SizeBytes $script:stageTarget.SizeBytes
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @() | Should -Not -BeNullOrEmpty
    }

    It 'fails when a filesystem unexpectedly already appears on the target drive letter' {
        $part = New-FakePartition -DiskNumber 2 -PartitionNumber 2 -DriveLetter 'A' -SizeBytes $script:stageTarget.SizeBytes
        $existingVolume = New-FakeVolume -DriveLetter 'A' -FileSystem 'NTFS'
        Test-PartitionReadyForFormatStage -Partitions @($part) -Target $script:stageTarget -NewPartitionNumber 2 -Volumes @($existingVolume) | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# 9) Master plan assembly: full APP/SQL inventories, VM-wide blocking
# =============================================================================

Describe 'Get-GuestDiskPreparationPlan' {
    It 'builds a correct, unblocked plan for a complete RAW APP inventory' {
        $fixture = New-AppRawGuestFixture
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeFalse
        $plan.DiskPlans.Count | Should -Be 1
        $plan.DiskPlans[0].Plan.Action | Should -Be 'Initialize'
        $plan.DiskPlans[0].Target.DiskNumber | Should -Be 2
        $plan.DvdPlan.Action | Should -Be 'NoneRequired'
    }

    It 'builds a correct, unblocked plan for a complete RAW SQL inventory with a positively verified empty DVD at E:, including a Move DVD plan with the correct device identity' {
        $fixture = New-SqlRawGuestFixture
        $plan = Invoke-PlanFromFixture -Target 'Sql' -Fixture $fixture
        $plan.Blocked | Should -BeFalse
        $plan.DiskPlans.Count | Should -Be 2
        ($plan.DiskPlans | Where-Object { $_.Target.Lun -eq 0 }).Plan.Action | Should -Be 'Initialize'
        ($plan.DiskPlans | Where-Object { $_.Target.Lun -eq 1 }).Plan.Action | Should -Be 'Initialize'
        $plan.DvdPlan.Action | Should -Be 'Move'
        $plan.DvdPlan.DeviceId | Should -Be '\\.\CDROM0'
    }

    It 'blocks the ENTIRE VM when SQL LOG validation fails, even though SQL DATA would independently resolve fine' {
        $fixture = New-SqlRawGuestFixture
        $fixture.Disks = @($fixture.Disks | ForEach-Object {
                if ($_.Number -eq 3) { $_.SizeBytes = 1 * 1024 * 1024 * 1024 }
                $_
            })
        $plan = Invoke-PlanFromFixture -Target 'Sql' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
        $plan.Errors.Count | Should -BeGreaterThan 0
    }

    It 'blocks the ENTIRE VM when SQL LOG is offline' {
        $fixture = New-SqlRawGuestFixture
        $fixture.Disks = @($fixture.Disks | ForEach-Object {
                if ($_.Number -eq 3) { $_.IsOffline = $true }
                $_
            })
        $plan = Invoke-PlanFromFixture -Target 'Sql' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
        $plan.DiskPlans.Count | Should -Be 0
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
            -GuestVolumeInventory $fixture.Volumes -GuestDvdVolumeInventory $fixture.DvdVolumes -GuestOpticalDriveInventory $fixture.OpticalDrives
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
            -GuestVolumeInventory $fixture.Volumes -GuestDvdVolumeInventory $fixture.DvdVolumes -GuestOpticalDriveInventory $fixture.OpticalDrives
        $plan.Blocked | Should -BeTrue
    }

    It 'blocks when a drive-letter conflict exists against an unrelated disk elsewhere in the guest' {
        $fixture = New-AppRawGuestFixture
        $fixture.Disks += (New-FakeGuestDisk -Number 9 -PartitionStyle 'GPT' -ScsiBus 0 -ScsiPort 2 -ScsiLogicalUnit 9)
        $fixture.Partitions = @(New-FakePartition -DiskNumber 9 -DriveLetter 'A')
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
    }

    It 'blocks when the data partition''s volume GUID path matches more than one guest volume (ambiguous volume correlation)' {
        $fixture = New-AppRawGuestFixture
        $data = New-FakePartition -DiskNumber 2 -DriveLetter 'A' -SizeBytes $script:AllowedApp.Disks[0].SizeBytes
        $fixture.Partitions = @($data)
        $fixture.Disks = @($fixture.Disks | ForEach-Object { if ($_.Number -eq 2) { $_.PartitionStyle = 'GPT' }; $_ })
        $fixture.Volumes = @(
            (New-FakeVolume -DriveLetter 'A' -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid)
            (New-FakeVolume -DriveLetter '' -FileSystemLabel 'LIMS-App' -VolumeGuid $data.VolumeGuid)
        )
        $plan = Invoke-PlanFromFixture -Target 'App' -Fixture $fixture
        $plan.Blocked | Should -BeTrue
    }
}

# =============================================================================
# 10) End-to-end orchestration (Invoke-GuestDiskPreparation), mocking ONLY
#     the *Adapter functions -- never the decision functions above. Mutation
#     adapter mocks simulate the resulting guest state so this script's new
#     per-stage re-checks see a realistic, self-consistent progression.
# =============================================================================

Describe 'Invoke-GuestDiskPreparation' {
    BeforeEach {
        $script:mutationCalls = [System.Collections.Generic.List[string]]::new()
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { $true }
        Mock Get-CurrentIdentityNameAdapter { 'NT AUTHORITY\SYSTEM' }
        Mock Get-ActualComputerNameAdapter { $script:actualComputerNameToReturn }
        Mock Get-ImdsComputeMetadataAdapter { $script:simulatedImds }
        Mock Get-GuestDiskInventoryAdapter { $script:simulatedDisks }
        Mock Get-GuestPartitionInventoryAdapter { $script:simulatedPartitions }
        Mock Get-GuestVolumeInventoryAdapter { $script:simulatedVolumes }
        Mock Get-GuestDvdVolumeInventoryAdapter { $script:simulatedDvdVolumes }
        Mock Get-GuestOpticalDriveInventoryAdapter { $script:simulatedOpticalDrives }

        Mock Initialize-ApprovedDiskAdapter {
            $script:mutationCalls.Add("Initialize:$DiskNumber")
            # Simulate the real, expected transition: RAW -> GPT, plus the
            # one Windows-generated MSR partition -- exactly the "expected,
            # in-progress state change caused by this invocation's own
            # prior step" the new per-stage rechecks must recognize as
            # correct.
            $script:simulatedDisks = @($script:simulatedDisks | ForEach-Object {
                    if ($_.Number -eq $DiskNumber) { $_.PartitionStyle = 'GPT' }
                    $_
                })
            $script:simulatedPartitions = @($script:simulatedPartitions) + @(New-FakeMsrPartition -DiskNumber $DiskNumber -PartitionNumber 1)
        }
        Mock New-ApprovedPartitionAdapter {
            $script:mutationCalls.Add("Partition:${DiskNumber}:${DriveLetter}")
            $newPartitionNumber = 2
            $expectedSize = $script:simulatedExpectedSizeByDisk[[int]$DiskNumber]
            $script:simulatedPartitions = @($script:simulatedPartitions | Where-Object { -not ($_.DiskNumber -eq $DiskNumber -and -not (Test-IsMsrPartition $_)) }) +
            @(New-FakePartition -DiskNumber $DiskNumber -PartitionNumber $newPartitionNumber -DriveLetter $DriveLetter -SizeBytes $expectedSize)
            return [pscustomobject]@{ PartitionNumber = $newPartitionNumber }
        }
        Mock Format-ApprovedVolumeAdapter {
            $script:mutationCalls.Add("Format:${DiskNumber}:${PartitionNumber}")
            $expectedSize = $script:simulatedExpectedSizeByDisk[[int]$DiskNumber]
            $driveLetter = (@($script:simulatedPartitions) | Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber } | Select-Object -First 1).DriveLetter
            $script:simulatedVolumes = @($script:simulatedVolumes) + @(New-FakeVolume -DriveLetter $driveLetter -FileSystem 'NTFS' -FileSystemLabel $FileSystemLabel -AllocationUnitSize $AllocationUnitBytes -SizeBytes $expectedSize)
        }
        Mock Move-DvdRomLetterAdapter {
            $script:mutationCalls.Add("Move:${DeviceId}:${ToLetter}")
            $script:simulatedOpticalDrives = @($script:simulatedOpticalDrives | ForEach-Object {
                    if ($_.DeviceId -eq $DeviceId) { $_.Drive = "${ToLetter}:" }
                    $_
                })
            $script:simulatedDvdVolumes = @($script:simulatedDvdVolumes | ForEach-Object {
                    if ($_.DriveLetter -eq 'E:') { $_.DriveLetter = "${ToLetter}:" }
                    $_
                })
        }
        Mock Confirm-DvdRomLetterMoveSucceededAdapter { $true }

        $script:simulatedPartitions = @()
        $script:simulatedVolumes = @()
        $script:simulatedDvdVolumes = @()
        $script:simulatedOpticalDrives = @()
        $script:simulatedExpectedSizeByDisk = @{}
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
            $script:simulatedOpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $false)
            $script:simulatedDvdVolumes = @(New-FakeDvdVolume -DriveLetter 'E' -DriveType 5 -Label '')
            Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget ''
            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }
    }

    Context 'Apply mode, SQL, RAW disks with a positively verified DVD at E:' {
        BeforeEach { Set-SqlFixture }

        It 'moves the DVD-ROM before creating the SQL DATA partition at E:, then initializes both disks in LUN order' {
            Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z'

            Should -Invoke Move-DvdRomLetterAdapter -Times 1 -ParameterFilter { $DeviceId -eq '\\.\CDROM0' -and $ToLetter -eq 'Z' }
            Should -Invoke Confirm-DvdRomLetterMoveSucceededAdapter -Times 1
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 }
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 3 }
            Should -Invoke New-ApprovedPartitionAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 -and $DriveLetter -eq 'E' }
            Should -Invoke New-ApprovedPartitionAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 3 -and $DriveLetter -eq 'F' }

            $moveIndex = $script:mutationCalls.IndexOf('Move:\\.\CDROM0:Z')
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

        It 'produces zero mutations (DVD move AND every SQL DATA mutation) when SQL LOG is offline' {
            $fixture = New-SqlRawGuestFixture
            $fixture.Disks = @($fixture.Disks | ForEach-Object {
                    if ($_.Number -eq 3) { $_.IsOffline = $true }
                    $_
                })
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
        }

        It 'produces zero mutations when the DVD at E: has loaded media' {
            $fixture = New-SqlRawGuestFixture
            $fixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $true)
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
        }

        It 'produces zero mutations when the optical device media state is unknown' {
            $fixture = New-SqlRawGuestFixture
            $fixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $null)
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }

        It 'produces zero mutations when the optical device reports an unexpected device name' {
            $fixture = New-SqlRawGuestFixture
            $fixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Unexpected Device' -Drive 'E:' -MediaLoaded $false)
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }

        It 'produces zero mutations when more than one optical device ambiguously reports E:' {
            $fixture = New-SqlRawGuestFixture
            $fixture.OpticalDrives = @(
                (New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $false)
                (New-FakeOpticalDrive -DeviceId '\\.\CDROM1' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $false)
            )
            Set-SqlFixture -Fixture $fixture

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 0
        }

        It 'produces zero mutations when the target letter Z: is already occupied' {
            Set-SqlFixture
            $script:simulatedVolumes = @(New-FakeVolume -DriveLetter 'Z')

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
            $dataPair = New-FakeFormattedPartitionAndVolume -DiskNumber 2 -DriveLetter 'E' -SizeBytes $script:AllowedSql.Disks[0].SizeBytes -FileSystemLabel 'SQL-Data' -AllocationUnitSize 65536
            $logPair = New-FakeFormattedPartitionAndVolume -DiskNumber 3 -DriveLetter 'F' -SizeBytes $script:AllowedSql.Disks[1].SizeBytes -FileSystemLabel 'SQL-Logs' -AllocationUnitSize 65536
            $fixture.Disks = @($fixture.Disks | ForEach-Object {
                    if ($_.Number -in @(2, 3)) { $_.PartitionStyle = 'GPT' }
                    $_
                })
            $fixture.Partitions = @($dataPair.Partition, $logPair.Partition)
            $fixture.Volumes = @($dataPair.Volume, $logPair.Volume)
            # DVD already successfully moved to Z: -- no optical device or
            # DVD volume reports E: anymore.
            $fixture.DvdVolumes = @(New-FakeDvdVolume -DriveLetter 'Z' -DriveType 5 -Label '')
            $fixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name $script:AllowedSql.ExpectedOpticalDriveName -Drive 'Z:' -MediaLoaded $false)
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

    Context 'Stable identity re-validation immediately before the whole-VM Apply preflight' {
        It 'fails and performs zero mutations when a resolved disk''s UniqueId changes between the first plan and the immediate pre-mutation re-check' {
            $fixtureA = New-AppRawGuestFixture
            $fixtureB = New-AppRawGuestFixture
            ($fixtureB.Disks | Where-Object Number -EQ 2).UniqueId = 'a-different-uid'

            Set-AppFixture -Fixture $fixtureA

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

    Context 'Immediate per-stage re-validation (Finding 4): identity/state changes DURING Apply, between individual mutating calls' {
        It 'fails, and never calls New-Partition, when the target disk''s UniqueId changes immediately after Initialize-Disk but before the New-Partition recheck' {
            Set-AppFixture
            Mock Initialize-ApprovedDiskAdapter {
                $script:mutationCalls.Add("Initialize:$DiskNumber")
                $script:simulatedDisks = @($script:simulatedDisks | ForEach-Object {
                        if ($_.Number -eq $DiskNumber) { $_.PartitionStyle = 'GPT'; $_.UniqueId = 'changed-after-initialize' }
                        $_
                    })
                $script:simulatedPartitions = @($script:simulatedPartitions) + @(New-FakeMsrPartition -DiskNumber $DiskNumber -PartitionNumber 1)
            }

            { Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                    -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget '' } | Should -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1
            Should -Invoke New-ApprovedPartitionAdapter -Times 0
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
        }

        It 'fails, and never calls Format-Volume, when a filesystem unexpectedly already appears on the new partition immediately after New-Partition but before the Format recheck' {
            Set-AppFixture
            Mock New-ApprovedPartitionAdapter {
                $script:mutationCalls.Add("Partition:${DiskNumber}:${DriveLetter}")
                $expectedSize = $script:simulatedExpectedSizeByDisk[[int]$DiskNumber]
                $script:simulatedPartitions = @($script:simulatedPartitions | Where-Object { -not ($_.DiskNumber -eq $DiskNumber -and -not (Test-IsMsrPartition $_)) }) +
                @(New-FakePartition -DiskNumber $DiskNumber -PartitionNumber 2 -DriveLetter $DriveLetter -SizeBytes $expectedSize)
                # Simulate an unexpected concurrent mutation: a filesystem
                # already appears before this invocation's own Format-Volume
                # call runs.
                $script:simulatedVolumes = @($script:simulatedVolumes) + @(New-FakeVolume -DriveLetter $DriveLetter -FileSystem 'NTFS' -FileSystemLabel 'unexpected')
                return [pscustomobject]@{ PartitionNumber = 2 }
            }

            { Invoke-GuestDiskPreparation -Target 'App' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedApp.SubscriptionId -ExpectedResourceGroupName $script:AllowedApp.ResourceGroupName `
                    -ExpectedVmName $script:AllowedApp.VmName -ExpectedComputerName $script:AllowedApp.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedApp.Disks) -DvdLetterMoveTarget '' } | Should -Throw

            Should -Invoke New-ApprovedPartitionAdapter -Times 1
            Should -Invoke Format-ApprovedVolumeAdapter -Times 0
        }

        It 'completes SQL DATA successfully but fails before touching SQL LOG when LOG''s identity silently changes while DATA was being finished -- DATA''s own completed mutations are never rolled back' {
            Set-SqlFixture
            Mock Format-ApprovedVolumeAdapter {
                $script:mutationCalls.Add("Format:${DiskNumber}:${PartitionNumber}")
                $expectedSize = $script:simulatedExpectedSizeByDisk[[int]$DiskNumber]
                $driveLetter = (@($script:simulatedPartitions) | Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber } | Select-Object -First 1).DriveLetter
                $script:simulatedVolumes = @($script:simulatedVolumes) + @(New-FakeVolume -DriveLetter $driveLetter -FileSystem 'NTFS' -FileSystemLabel $FileSystemLabel -AllocationUnitSize $AllocationUnitBytes -SizeBytes $expectedSize)
                if ($DiskNumber -eq 2) {
                    # Simulate SQL LOG's identity silently changing while
                    # DATA was being finished -- independent of anything
                    # this invocation did.
                    $script:simulatedDisks = @($script:simulatedDisks | ForEach-Object {
                            if ($_.Number -eq 3) { $_.UniqueId = 'concurrently-changed-log-uid' }
                            $_
                        })
                }
            }

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Initialize-ApprovedDiskAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 }
            Should -Invoke Format-ApprovedVolumeAdapter -Times 1 -ParameterFilter { $DiskNumber -eq 2 }
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0 -ParameterFilter { $DiskNumber -eq 3 }
        }

        It 'moves the DVD-ROM successfully but never initializes any disk when SQL DATA''s identity silently changes immediately after the DVD move' {
            Set-SqlFixture
            Mock Move-DvdRomLetterAdapter {
                $script:mutationCalls.Add("Move:${DeviceId}:${ToLetter}")
                $script:simulatedOpticalDrives = @($script:simulatedOpticalDrives | ForEach-Object {
                        if ($_.DeviceId -eq $DeviceId) { $_.Drive = "${ToLetter}:" }
                        $_
                    })
                $script:simulatedDvdVolumes = @($script:simulatedDvdVolumes | ForEach-Object {
                        if ($_.DriveLetter -eq 'E:') { $_.DriveLetter = "${ToLetter}:" }
                        $_
                    })
                # Simulate SQL DATA's identity silently changing immediately
                # after the DVD move completes -- independent of anything
                # this invocation did.
                $script:simulatedDisks = @($script:simulatedDisks | ForEach-Object {
                        if ($_.Number -eq 2) { $_.UniqueId = 'concurrently-changed-data-uid' }
                        $_
                    })
            }

            { Invoke-GuestDiskPreparation -Target 'Sql' -Mode 'Apply' `
                    -ExpectedSubscriptionId $script:AllowedSql.SubscriptionId -ExpectedResourceGroupName $script:AllowedSql.ResourceGroupName `
                    -ExpectedVmName $script:AllowedSql.VmName -ExpectedComputerName $script:AllowedSql.ComputerName `
                    -ExpectedDisksJson (ConvertTo-ExpectedDisksJson -Disks $script:AllowedSql.Disks) -DvdLetterMoveTarget 'Z' } | Should -Throw

            Should -Invoke Move-DvdRomLetterAdapter -Times 1
            Should -Invoke Initialize-ApprovedDiskAdapter -Times 0
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
            $script:offlineLogSqlFixture = New-SqlRawGuestFixture
            $script:offlineLogSqlFixture.Disks = @($script:offlineLogSqlFixture.Disks | ForEach-Object {
                    if ($_.Number -eq 3) { $_.IsOffline = $true }
                    $_
                })
            $script:loadedDvdSqlFixture = New-SqlRawGuestFixture
            $script:loadedDvdSqlFixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $true)
            $script:unknownMediaSqlFixture = New-SqlRawGuestFixture
            $script:unknownMediaSqlFixture.OpticalDrives = @(New-FakeOpticalDrive -DeviceId '\\.\CDROM0' -Name 'Microsoft Virtual DVD-ROM' -Drive 'E:' -MediaLoaded $null)
        }

        It 'issues zero mutation calls for scenario "<Name>"' -TestCases @(
            @{ Name = 'APP RAW happy path'; Target = 'App'; Fixture = { New-AppRawGuestFixture } }
            @{ Name = 'SQL RAW happy path with DVD move pending'; Target = 'Sql'; Fixture = { New-SqlRawGuestFixture } }
            @{ Name = 'SQL LOG validation failure'; Target = 'Sql'; Fixture = { $script:failingSqlFixture } }
            @{ Name = 'SQL LOG offline'; Target = 'Sql'; Fixture = { $script:offlineLogSqlFixture } }
            @{ Name = 'SQL loaded DVD media'; Target = 'Sql'; Fixture = { $script:loadedDvdSqlFixture } }
            @{ Name = 'SQL unknown DVD media state'; Target = 'Sql'; Fixture = { $script:unknownMediaSqlFixture } }
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

<#
.SYNOPSIS
    Pester tests for Initialize-LimsGuestDataDisks.ps1.

.DESCRIPTION
    Dot-sources the script under LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY=1 (so
    none of its top-level logic executes automatically), then calls
    Invoke-GuestDiskPreparation directly with every disk-facing cmdlet
    (Get-CimInstance, Get-Disk, Get-Partition, Get-Volume, Initialize-Disk,
    New-Partition, Format-Volume, Set-CimInstance) and Invoke-RestMethod
    mocked. No test in this file ever invokes a real storage-changing
    command against a real local disk -- every mutating cmdlet is mocked in
    every test, including the success-path tests.

    Run with: Invoke-Pester -Path .\Initialize-LimsGuestDataDisks.Tests.ps1
#>

BeforeAll {
    $script:OriginalComputerName = $env:COMPUTERNAME
    $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Initialize-LimsGuestDataDisks.ps1'
    $env:LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY = '1'
    . $script:ScriptUnderTest -ExpectedSubscriptionId 'unused' -ExpectedResourceGroupName 'unused' `
        -ExpectedVmName 'unused' -ExpectedComputerName 'unused' -ExpectedDisksJson '[]'
    Remove-Item Env:\LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue

    # ---- Fixed "approved target" values, matching the real LIMS DEV v2 shape ----
    $script:Sub = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
    $script:Rg = 'rg-compute-lims-dev-westeu'
    $script:AppVmName = 'vm-lims-dev-v2-westeu-001'
    $script:AppComputerName = 'lims-dev-v2-001'
    $script:AppDiskName = 'appdata-vm-lims-dev-v2-westeu-001'
    $script:AppDiskSizeBytes = 128 * 1024 * 1024 * 1024

    function New-ImdsDataDisk {
        param([int]$Lun, [string]$Name, [int64]$SizeBytes, [string]$Sub = $script:Sub, [string]$Rg = $script:Rg)
        [pscustomobject]@{
            lun             = $Lun
            name            = $Name
            diskSizeGB      = [int]($SizeBytes / 1GB)
            diskCapacityBytes = [string]$SizeBytes
            managedDisk     = [pscustomobject]@{
                id = "/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.Compute/disks/$Name"
            }
        }
    }

    function New-ImdsCompute {
        param(
            [string]$SubscriptionId = $script:Sub,
            [string]$ResourceGroupName = $script:Rg,
            [string]$Name = $script:AppVmName,
            [array]$DataDisks
        )
        [pscustomobject]@{
            subscriptionId    = $SubscriptionId
            resourceGroupName = $ResourceGroupName
            name              = $Name
            storageProfile    = [pscustomobject]@{ dataDisks = $DataDisks }
        }
    }

    function New-DiskDrive {
        param([int]$Index, [int]$Lun)
        [pscustomobject]@{ Index = $Index; SCSILogicalUnit = $Lun }
    }

    function New-WindowsDisk {
        param([int]$Number, [int64]$Size, [bool]$IsBoot = $false, [bool]$IsSystem = $false, [string]$PartitionStyle = 'RAW')
        [pscustomobject]@{ Number = $Number; Size = $Size; IsBoot = $IsBoot; IsSystem = $IsSystem; PartitionStyle = $PartitionStyle }
    }

    # Get-Volume's -Partition parameter and Format-Volume's -Partition
    # parameter are both strictly typed to the real Storage module's
    # MSFT_Partition CIM class. A real cmdlet still enforces that parameter
    # type when it has been Mocked (Pester's generated proxy mirrors the
    # original signature), so a plain [pscustomobject] fails type binding
    # before the mock body even runs. New-CimInstance -ClientOnly creates a
    # genuine, schema-valid MSFT_Partition instance with no backing hardware
    # — safe to use in a test, never touching a real disk.
    function New-FakePartition {
        param([int]$DiskNumber, [AllowNull()][string]$DriveLetter, [AllowNull()][string]$GptType)
        # Real MSFT_Partition instances always expose DriveLetter/GptType
        # (as the null char / empty string when not applicable) rather than
        # omitting the property entirely -- a client-only instance must set
        # both explicitly too, or accessing an unset property throws
        # "property cannot be found" instead of returning a falsy value.
        $driveLetterChar = if ($DriveLetter) { [char]$DriveLetter } else { [char]0 }
        New-CimInstance -ClassName MSFT_Partition -Namespace ROOT/Microsoft/Windows/Storage -ClientOnly -Property @{
            DiskNumber  = $DiskNumber
            DriveLetter = $driveLetterChar
            GptType     = if ($GptType) { $GptType } else { '' }
        }
    }

    # Set-CimInstance's -InputObject parameter is likewise typed to
    # CimInstance; Win32_Volume is a real, registered WMI class, so a
    # client-only instance of it satisfies that binding without touching any
    # real volume.
    function New-FakeWin32Volume {
        param([string]$DriveLetter, [int]$DriveType)
        New-CimInstance -ClassName Win32_Volume -Namespace ROOT/cimv2 -ClientOnly -Property @{
            DriveLetter = $DriveLetter
            DriveType   = [uint32]$DriveType
        }
    }

    function Set-BaselineAppSingleDiskMocks {
        <#
            A single RAW, unambiguous, correctly sized/named/identified APP
            data disk at LUN 0 / Windows disk number 2. Identity (IMDS +
            computer name) matches exactly. Represents the first-run,
            everything-approved scenario; individual tests override specific
            mocks to inject the one condition under test.
        #>
        Mock Test-CurrentIdentityIsAdministratorOrSystem { $true }
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        Mock Get-CimInstance {
            @(New-DiskDrive -Index 2 -Lun 0)
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'RAW' }
        Mock Get-Partition { @() }
        Mock Initialize-Disk { }
        Mock New-Partition { New-FakePartition -DiskNumber 2 -DriveLetter 'A' }
        Mock Format-Volume { }
        Mock Set-CimInstance { }
        Mock Get-Volume { $null }

        $env:COMPUTERNAME = $script:AppComputerName
    }

    function Invoke-TestTarget {
        param(
            [string]$ExpectedVmName = $script:AppVmName,
            [string]$ExpectedComputerName = $script:AppComputerName,
            [string]$ExpectedSubscriptionId = $script:Sub,
            [string]$ExpectedResourceGroupName = $script:Rg,
            [array]$ExpectedDisks,
            [string]$DvdLetterMoveTarget = ''
        )
        if (-not $ExpectedDisks) {
            $ExpectedDisks = @(
                @{
                    Lun = 0; DiskName = $script:AppDiskName; SizeBytes = $script:AppDiskSizeBytes
                    DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; AllocationUnitBytes = 4096
                }
            )
        }
        Invoke-GuestDiskPreparation -ExpectedSubscriptionId $ExpectedSubscriptionId `
            -ExpectedResourceGroupName $ExpectedResourceGroupName `
            -ExpectedVmName $ExpectedVmName `
            -ExpectedComputerName $ExpectedComputerName `
            -ExpectedDisksJson (ConvertTo-Json -InputObject $ExpectedDisks -Depth 5) `
            -DvdLetterMoveTarget $DvdLetterMoveTarget
    }

    function Assert-NoMutationsOccurred {
        Should -Invoke Initialize-Disk -Times 0
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
        Should -Invoke Set-CimInstance -Times 0
    }
}

Describe 'Invoke-GuestDiskPreparation - identity verification' {

    BeforeEach {
        Set-BaselineAppSingleDiskMocks
    }

    It 'fails closed when not running as Administrator/SYSTEM, without ever querying IMDS or mutating' {
        Mock Test-CurrentIdentityIsAdministratorOrSystem { $false }

        { Invoke-TestTarget } | Should -Throw '*SYSTEM or an Administrator*'

        Should -Invoke Get-ImdsComputeMetadata -Times 0
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a subscription ID mismatch' {
        { Invoke-TestTarget -ExpectedSubscriptionId '00000000-0000-0000-0000-000000000099' } | Should -Throw '*Subscription mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a resource group mismatch' {
        { Invoke-TestTarget -ExpectedResourceGroupName 'rg-some-other-group' } | Should -Throw '*Resource group mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a VM name mismatch (including a v1-looking name)' {
        { Invoke-TestTarget -ExpectedVmName 'vm-lims-dev-westeu-001' } | Should -Throw '*VM name mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a Windows computer-name mismatch even when the Azure VM name matches' {
        { Invoke-TestTarget -ExpectedComputerName 'lims-dev-v1-001' } | Should -Throw '*computer name mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when IMDS reports incomplete compute metadata' {
        Mock Get-ImdsComputeMetadata { New-ImdsCompute -ResourceGroupName '' -DataDisks @() }
        { Invoke-TestTarget } | Should -Throw '*incomplete compute identity metadata*'
        Assert-NoMutationsOccurred
    }
}

Describe 'Invoke-GuestDiskPreparation - disk correlation and mapping safety' {

    BeforeEach {
        Set-BaselineAppSingleDiskMocks
    }

    It 'fails closed when the expected LUN is not present in the IMDS data-disk inventory (wrong LUN)' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 7 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        { Invoke-TestTarget } | Should -Throw '*not present in this VM*IMDS data-disk inventory*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a managed-disk name mismatch (wrong resource identity)' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name 'some-other-disk-name' -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        { Invoke-TestTarget } | Should -Throw '*managed-disk name mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a managed-disk resource ID outside the approved subscription/resource group (wrong resource ID)' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes -Rg 'rg-some-other-group')
            )
        }
        { Invoke-TestTarget } | Should -Throw '*does not match the expected subscription/resource group/disk name*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on a capacity mismatch (wrong size)' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes (64 * 1024 * 1024 * 1024))
            )
        }
        { Invoke-TestTarget } | Should -Throw '*capacity mismatch*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when more than one IMDS data disk reports the same LUN (ambiguous mapping)' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes),
                (New-ImdsDataDisk -Lun 0 -Name 'duplicate-lun-disk' -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        { Invoke-TestTarget } | Should -Throw '*more than one data disk at LUN*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when more than one Windows disk device reports the same LUN (ambiguous WMI mapping)' {
        Mock Get-CimInstance {
            @((New-DiskDrive -Index 2 -Lun 0), (New-DiskDrive -Index 3 -Lun 0))
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        { Invoke-TestTarget } | Should -Throw '*maps to 2 Windows disk device*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when the LUN resolves to no Windows disk device at all' {
        Mock Get-CimInstance { @() } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        { Invoke-TestTarget } | Should -Throw '*does not correspond to any Windows disk device*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when the resolved Windows disk is flagged as boot/system (refuses to touch the OS disk)' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -IsBoot $true -PartitionStyle 'GPT' }
        { Invoke-TestTarget } | Should -Throw '*flagged boot and/or system*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when the resolved Windows disk size does not match the expected size' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size (999 * 1024 * 1024 * 1024) -PartitionStyle 'RAW' }
        { Invoke-TestTarget } | Should -Throw '*does not match the expected*bytes*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when two approved descriptors would resolve to the same Windows disk number' {
        $disks = @(
            @{ Lun = 0; DiskName = $script:AppDiskName; SizeBytes = $script:AppDiskSizeBytes; DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; AllocationUnitBytes = 4096 },
            @{ Lun = 1; DiskName = 'second-disk'; SizeBytes = $script:AppDiskSizeBytes; DriveLetter = 'B'; FileSystemLabel = 'Second'; AllocationUnitBytes = 4096 }
        )
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes),
                (New-ImdsDataDisk -Lun 1 -Name 'second-disk' -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        Mock Get-CimInstance {
            @((New-DiskDrive -Index 2 -Lun 0), (New-DiskDrive -Index 2 -Lun 1))
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        { Invoke-TestTarget -ExpectedDisks $disks } | Should -Throw '*same Windows disk number*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when two approved descriptors request the same drive letter' {
        $disks = @(
            @{ Lun = 0; DiskName = $script:AppDiskName; SizeBytes = $script:AppDiskSizeBytes; DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; AllocationUnitBytes = 4096 },
            @{ Lun = 1; DiskName = 'second-disk'; SizeBytes = $script:AppDiskSizeBytes; DriveLetter = 'A'; FileSystemLabel = 'Second'; AllocationUnitBytes = 4096 }
        )
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:AppDiskName -SizeBytes $script:AppDiskSizeBytes),
                (New-ImdsDataDisk -Lun 1 -Name 'second-disk' -SizeBytes $script:AppDiskSizeBytes)
            )
        }
        Mock Get-CimInstance {
            @((New-DiskDrive -Index 2 -Lun 0), (New-DiskDrive -Index 3 -Lun 1))
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Mock Get-Disk {
            param($Number)
            # The real Get-Disk -Number parameter is typed as an array, so
            # even a single-value call binds $Number as a one-element array.
            New-WindowsDisk -Number ([int]@($Number)[0]) -Size $script:AppDiskSizeBytes -PartitionStyle 'RAW'
        }
        { Invoke-TestTarget -ExpectedDisks $disks } | Should -Throw '*same drive letter*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when the requested drive letter is already used by a different, unapproved disk' {
        Mock Get-Partition {
            @(New-FakePartition -DiskNumber 9 -DriveLetter 'A' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')
        }
        { Invoke-TestTarget } | Should -Throw '*already in use by a disk other than the approved target*'
        Assert-NoMutationsOccurred
    }
}

Describe 'Invoke-GuestDiskPreparation - idempotent prepare/validate behavior' {

    BeforeEach {
        Set-BaselineAppSingleDiskMocks
    }

    It 'initializes, partitions, and formats a RAW disk with no partitions on first run' {
        Invoke-TestTarget

        Should -Invoke Initialize-Disk -Times 1 -ParameterFilter { $Number -eq 2 -and $PartitionStyle -eq 'GPT' }
        Should -Invoke New-Partition -Times 1 -ParameterFilter { $DiskNumber -eq 2 -and $DriveLetter -eq 'A' }
        Should -Invoke Format-Volume -Times 1 -ParameterFilter {
            $FileSystem -eq 'NTFS' -and $AllocationUnitSize -eq 4096 -and $NewFileSystemLabel -eq 'LIMS-App'
        }
    }

    It 'fails closed when a RAW disk unexpectedly already has partitions (inconsistent state)' {
        Mock Get-Partition {
            @(New-FakePartition -DiskNumber 2)
        }
        { Invoke-TestTarget } | Should -Throw '*already has*partition*'
        Assert-NoMutationsOccurred
    }

    It 'takes no action and reports success when the disk already matches the intended layout exactly (idempotent re-run)' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'GPT' }
        Mock Get-Partition {
            @(New-FakePartition -DiskNumber 2 -DriveLetter 'A' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')
        }
        Mock Get-Volume {
            [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'LIMS-App'; AllocationUnitSize = 4096 }
        }

        { Invoke-TestTarget } | Should -Not -Throw
        Assert-NoMutationsOccurred
    }

    It 'fails closed (never reformats) when an already-formatted disk does not match the intended layout' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'GPT' }
        Mock Get-Partition {
            @(New-FakePartition -DiskNumber 2 -DriveLetter 'A' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')
        }
        Mock Get-Volume {
            # Wrong allocation unit size -- e.g. someone formatted it manually with defaults.
            [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'LIMS-App'; AllocationUnitSize = 65536 }
        }

        { Invoke-TestTarget } | Should -Throw '*does not match the intended layout*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed on partial completion: GPT-initialized but no data partition yet (stops for review, never auto-resumes)' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'GPT' }
        Mock Get-Partition {
            @(New-FakePartition -DiskNumber 2 -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
        }

        { Invoke-TestTarget } | Should -Throw '*ambiguous partial-completion state*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when a GPT disk has more than one non-reserved partition (unexpected existing partition)' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'GPT' }
        Mock Get-Partition {
            @(
                (New-FakePartition -DiskNumber 2 -DriveLetter 'A' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'),
                (New-FakePartition -DiskNumber 2 -DriveLetter 'Z' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')
            )
        }
        { Invoke-TestTarget } | Should -Throw '*non-reserved partitions*'
        Assert-NoMutationsOccurred
    }

    It 'tolerates a single documented MSR partition alongside the data partition without treating it as unexpected' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'GPT' }
        Mock Get-Partition {
            @(
                (New-FakePartition -DiskNumber 2 -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'),
                (New-FakePartition -DiskNumber 2 -DriveLetter 'A' -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')
            )
        }
        Mock Get-Volume {
            [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'LIMS-App'; AllocationUnitSize = 4096 }
        }

        { Invoke-TestTarget } | Should -Not -Throw
        Assert-NoMutationsOccurred
    }

    It 'fails closed on an unexpected PartitionStyle (neither RAW nor GPT)' {
        Mock Get-Disk { New-WindowsDisk -Number 2 -Size $script:AppDiskSizeBytes -PartitionStyle 'MBR' }
        { Invoke-TestTarget } | Should -Throw "*unexpected PartitionStyle 'MBR'*"
        Assert-NoMutationsOccurred
    }

    It 'fails closed on immediate pre-mutation identity re-validation failure (disk renumbered between preflight and mutation)' {
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_DiskDrive' -and $Filter) {
                # Simulate the disk no longer reporting the expected LUN at
                # the immediate pre-mutation re-check.
                return [pscustomobject]@{ Index = 2; SCSILogicalUnit = 9 }
            }
            return @(New-DiskDrive -Index 2 -Lun 0)
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        { Invoke-TestTarget } | Should -Throw '*pre-mutation identity re-validation*'
        Assert-NoMutationsOccurred
    }

    It 'fails closed when unexpected partitions appear immediately after GPT initialization' {
        # Three Get-Partition calls occur before this condition is reached:
        # (1) the whole-guest drive-letter-conflict preflight, (2) this
        # target's own before-initialize check, (3) the immediate
        # after-initialize check -- only the third should see a partition.
        $script:PartitionCallCount = 0
        Mock Get-Partition {
            $script:PartitionCallCount++
            if ($script:PartitionCallCount -le 2) {
                return @()
            }
            # After Initialize-Disk, something unexpected shows up (an LDM
            # data partition type -- never a tolerated MSR partition).
            return @(New-FakePartition -DiskNumber 2 -GptType '{af9b60a0-1431-4f62-bc68-3311714a69ad}')
        }
        { Invoke-TestTarget } | Should -Throw '*unexpected partition(s) immediately after GPT initialization*'
        Should -Invoke Initialize-Disk -Times 1
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
    }
}

Describe 'Invoke-GuestDiskPreparation - SQL-only DVD-ROM letter move' {

    BeforeEach {
        Set-BaselineAppSingleDiskMocks
    }

    It 'never touches any DVD-ROM letter when DvdLetterMoveTarget is empty (APP VM case)' {
        Invoke-TestTarget -DvdLetterMoveTarget ''
        Should -Invoke Set-CimInstance -Times 0
        Should -Invoke Get-CimInstance -Times 0 -ParameterFilter { $ClassName -eq 'Win32_Volume' }
    }

    It 'moves an empty virtual DVD-ROM from E: to the target letter when confirmed and the target is free' {
        Mock Get-CimInstance {
            New-FakeWin32Volume -DriveLetter 'E:' -DriveType 5
        } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
        Mock Get-Volume { $null } -ParameterFilter { $DriveLetter -eq 'Z' }

        Invoke-TestTarget -DvdLetterMoveTarget 'Z'

        Should -Invoke Set-CimInstance -Times 1 -ParameterFilter { $Property['DriveLetter'] -eq 'Z:' }
    }

    It 'fails closed and never moves anything when E: is not a CD-ROM volume' {
        Mock Get-CimInstance {
            New-FakeWin32Volume -DriveLetter 'E:' -DriveType 3
        } -ParameterFilter { $ClassName -eq 'Win32_Volume' }

        { Invoke-TestTarget -DvdLetterMoveTarget 'Z' } | Should -Throw '*is not a CD-ROM volume*'
        Should -Invoke Set-CimInstance -Times 0
    }

    It 'fails closed and never moves anything when the target letter is already occupied' {
        Mock Get-CimInstance {
            New-FakeWin32Volume -DriveLetter 'E:' -DriveType 5
        } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
        Mock Get-Volume {
            [pscustomobject]@{ DriveLetter = 'Z' }
        } -ParameterFilter { $DriveLetter -eq 'Z' }

        { Invoke-TestTarget -DvdLetterMoveTarget 'Z' } | Should -Throw '*already in use*'
        Should -Invoke Set-CimInstance -Times 0
    }

    It 'takes no action when no volume is currently mounted at E:' {
        Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_Volume' }

        { Invoke-TestTarget -DvdLetterMoveTarget 'Z' } | Should -Not -Throw
        Should -Invoke Set-CimInstance -Times 0
    }
}

Describe 'Invoke-GuestDiskPreparation - SQL two-disk scenario (DATA + LOG)' {

    BeforeEach {
        $script:SqlVmName = 'vm-lims-dev-v2-westeu-002'
        $script:SqlComputerName = 'lims-dev-v2-002'
        $script:SqlDataDiskName = 'sqldata-vm-lims-dev-v2-westeu-002'
        $script:SqlLogDiskName = 'sqllog-vm-lims-dev-v2-westeu-002'
        $script:SqlDataSizeBytes = 1024 * 1024 * 1024 * 1024
        $script:SqlLogSizeBytes = 512 * 1024 * 1024 * 1024

        Mock Test-CurrentIdentityIsAdministratorOrSystem { $true }
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -Name $script:SqlVmName -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:SqlDataDiskName -SizeBytes $script:SqlDataSizeBytes),
                (New-ImdsDataDisk -Lun 1 -Name $script:SqlLogDiskName -SizeBytes $script:SqlLogSizeBytes)
            )
        }
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            $allDiskDrives = @((New-DiskDrive -Index 2 -Lun 0), (New-DiskDrive -Index 3 -Lun 1))
            if ($Filter -and $Filter -match 'Index=(\d+)') {
                # The immediate pre-mutation re-check queries by a specific
                # Index via -Filter; the bulk preflight call has no -Filter
                # and expects every disk drive back.
                return @($allDiskDrives | Where-Object { $_.Index -eq [int]$Matches[1] })
            }
            return $allDiskDrives
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        Mock Get-Disk {
            param($Number)
            $diskNumber = [int]@($Number)[0]
            if ($diskNumber -eq 2) { New-WindowsDisk -Number 2 -Size $script:SqlDataSizeBytes -PartitionStyle 'RAW' }
            else { New-WindowsDisk -Number 3 -Size $script:SqlLogSizeBytes -PartitionStyle 'RAW' }
        }
        Mock Get-Partition { @() }
        Mock Initialize-Disk { }
        Mock New-Partition {
            param($DiskNumber, $DriveLetter)
            New-FakePartition -DiskNumber ([int]@($DiskNumber)[0]) -DriveLetter $DriveLetter
        }
        Mock Format-Volume { }
        Mock Set-CimInstance { }
        Mock Get-Volume { $null }

        $env:COMPUTERNAME = $script:SqlComputerName
    }

    It 'prepares both the DATA and LOG disks independently with their own exact layouts' {
        $disks = @(
            @{ Lun = 0; DiskName = $script:SqlDataDiskName; SizeBytes = $script:SqlDataSizeBytes; DriveLetter = 'E'; FileSystemLabel = 'SQL-Data'; AllocationUnitBytes = 65536 },
            @{ Lun = 1; DiskName = $script:SqlLogDiskName; SizeBytes = $script:SqlLogSizeBytes; DriveLetter = 'F'; FileSystemLabel = 'SQL-Logs'; AllocationUnitBytes = 65536 }
        )

        Invoke-TestTarget -ExpectedVmName $script:SqlVmName -ExpectedComputerName $script:SqlComputerName -ExpectedDisks $disks

        Should -Invoke Initialize-Disk -Times 2
        Should -Invoke New-Partition -Times 1 -ParameterFilter { $DiskNumber -eq 2 -and $DriveLetter -eq 'E' }
        Should -Invoke New-Partition -Times 1 -ParameterFilter { $DiskNumber -eq 3 -and $DriveLetter -eq 'F' }
        Should -Invoke Format-Volume -Times 1 -ParameterFilter { $NewFileSystemLabel -eq 'SQL-Data' -and $AllocationUnitSize -eq 65536 }
        Should -Invoke Format-Volume -Times 1 -ParameterFilter { $NewFileSystemLabel -eq 'SQL-Logs' -and $AllocationUnitSize -eq 65536 }
    }

    It 'fails the whole run (and performs zero mutations) if only the LOG disk fails identity verification' {
        Mock Get-ImdsComputeMetadata {
            New-ImdsCompute -Name $script:SqlVmName -DataDisks @(
                (New-ImdsDataDisk -Lun 0 -Name $script:SqlDataDiskName -SizeBytes $script:SqlDataSizeBytes),
                (New-ImdsDataDisk -Lun 1 -Name 'unexpected-disk-name' -SizeBytes $script:SqlLogSizeBytes)
            )
        }
        $disks = @(
            @{ Lun = 0; DiskName = $script:SqlDataDiskName; SizeBytes = $script:SqlDataSizeBytes; DriveLetter = 'E'; FileSystemLabel = 'SQL-Data'; AllocationUnitBytes = 65536 },
            @{ Lun = 1; DiskName = $script:SqlLogDiskName; SizeBytes = $script:SqlLogSizeBytes; DriveLetter = 'F'; FileSystemLabel = 'SQL-Logs'; AllocationUnitBytes = 65536 }
        )

        { Invoke-TestTarget -ExpectedVmName $script:SqlVmName -ExpectedComputerName $script:SqlComputerName -ExpectedDisks $disks } |
            Should -Throw '*managed-disk name mismatch*'

        Should -Invoke Initialize-Disk -Times 0
        Should -Invoke New-Partition -Times 0
        Should -Invoke Format-Volume -Times 0
    }
}

AfterAll {
    $env:COMPUTERNAME = $script:OriginalComputerName
}

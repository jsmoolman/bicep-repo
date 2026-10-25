<#
.SYNOPSIS
    Safely initializes, partitions, formats, labels, and assigns a drive
    letter to a small, explicit, pre-approved set of RAW Azure managed data
    disks inside a single Windows guest -- and nothing else.

.DESCRIPTION
    Delivered inline via a Microsoft.Compute/virtualMachines/runCommands
    resource (see modules/compute/lims-ws2025-dev-foundation/main.bicep) --
    never from a storage account, never containing a secret. Every disk this
    script is allowed to touch is supplied explicitly, by the caller, as a
    JSON array of { Lun, DiskName, SizeBytes, DriveLetter, FileSystemLabel,
    AllocationUnitBytes } objects (see -ExpectedDisksJson below). This script
    never discovers disks by enumerating "all RAW disks", by size alone, or
    by Windows disk ordinal number -- every mutation target is first
    correlated to an exact Azure managed-disk resource ID and Logical Unit
    Number (LUN) using the Azure Instance Metadata Service (IMDS) and the
    documented Win32_DiskDrive.SCSILogicalUnit WMI property
    (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive),
    which Microsoft's own "How to map Azure Disks to Windows VM guest disks"
    guidance
    (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/azure-to-guest-disk-mapping)
    identifies as the correct way to disambiguate same-size data disks via
    LUN rather than ordinal disk number or SCSI port.

    Safety model (see docs/operations.md for the full behavioral contract):
      - Before any mutation, this script independently verifies -- via IMDS,
        a credential-free, in-guest-only endpoint
        (https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
        -- that the running VM's own subscription ID, resource group name,
        and Azure VM resource name match the caller-supplied expected
        values, and separately verifies the local Windows computer name
        (IMDS does not report this) against the caller-supplied expected
        computer name. Any missing or mismatched value is a hard failure
        with no mutation attempted.
      - Every approved disk is correlated by LUN to exactly one Windows disk
        device; ambiguous (zero or multiple) WMI matches are a hard failure.
      - A resolved disk is additionally required to report the expected
        managed-disk resource name (and the expected subscription/resource
        group in its managedDisk.id), and the expected capacity, before it
        is considered a valid mutation target.
      - A resolved disk's Windows boot/system flags are checked and must
        both be false.
      - Only a disk that is RAW (PartitionStyle), carries zero partitions,
        and passed every check above is initialized/partitioned/formatted.
        RAW alone is never sufficient -- see the identity/LUN/size checks
        above. RAW does not prove the disk has never held data; it is
        treated here only as one of several required preconditions, backed
        by this disk having been freshly created and attached by the
        compute-foundation module that owns this capability.
      - A disk already carrying the exact intended GPT layout (single data
        partition, NTFS, matching allocation unit size, label, and drive
        letter) is left completely untouched -- this makes the script safe
        to run on every redeployment once enabled.
      - A disk in any other state (already GPT but missing a data partition
        or volume, or formatted but not matching the intended layout) is a
        hard failure -- never auto-repaired, auto-reformatted, or retried.
        This is the explicit "stop for review" behavior for partial
        completion.
      - Windows may create a Microsoft Reserved (MSR) partition
        automatically as part of GPT initialization (every GPT disk must
        carry one -- see
        https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-and-gpt-faq)
        -- this one documented partition type is tolerated; any other
        unexpected partition is a hard failure.
      - Clear-Disk, diskpart clean, partition deletion, forced reformatting,
        storage pools, and any blanket/wildcard disk-state change are never
        used anywhere in this script. Every mutating cmdlet targets an
        explicit disk number or partition object -- never a drive letter
        alone.
      - Disk identity (LUN -> Windows disk number, boot/system flags, size)
        is re-verified immediately before the one mutating call
        (Initialize-Disk) for that disk, not only during the earlier
        preflight pass.
      - SQL only: if -DvdLetterMoveTarget is supplied and E: currently hosts
        a CD-ROM-type volume, it is moved there -- but only if the target
        letter is free; otherwise this is a hard failure. If E: hosts
        anything other than a CD-ROM volume, this is a hard failure. If
        -DvdLetterMoveTarget is empty (the APP VM case), no DVD letter is
        ever touched.
      - This script never touches pagefile configuration, the Azure
        temporary disk, SQL TempDB/configuration/folders/permissions/shares,
        or application content, and never retries a failed format
        automatically.

    Requires administrator or SYSTEM execution. Run Command on Windows
    executes scripts as the SYSTEM account by default when no RunAsUser is
    supplied (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command,
    "Scripts run as System on Windows"); this script independently verifies
    that execution context rather than relying solely on that default.

.PARAMETER ExpectedSubscriptionId
    The exact Azure subscription ID this VM is expected to belong to.

.PARAMETER ExpectedResourceGroupName
    The exact resource group name this VM is expected to belong to.

.PARAMETER ExpectedVmName
    The exact Azure VM resource name (as reported by IMDS) this script is
    expected to be running on.

.PARAMETER ExpectedComputerName
    The exact Windows (NetBIOS) computer name this script is expected to be
    running on. Checked separately from ExpectedVmName -- IMDS does not
    report the guest OS computer name, and the two are not guaranteed (and
    are not, for these VMs) identical strings.

.PARAMETER ExpectedDisksJson
    A JSON array of objects, each describing exactly one approved mutation
    target:
      Lun                 - int:    the Azure LUN of the data disk.
      DiskName             - string: the exact managed-disk resource name.
      SizeBytes            - int64:  the exact expected disk capacity, bytes.
      DriveLetter          - string: single character, no colon (e.g. "A").
      FileSystemLabel      - string: exact NTFS volume label.
      AllocationUnitBytes  - int:    exact NTFS allocation unit size, bytes.
    No disk outside this list is ever touched, regardless of its state.

.PARAMETER DvdLetterMoveTarget
    Single drive letter (no colon) to move an empty virtual DVD-ROM
    currently at E: to, or an empty string to never touch any DVD-ROM
    drive letter (the APP VM case).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExpectedSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedVmName,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedComputerName,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedDisksJson,

    [Parameter(Mandatory = $false)]
    [string] $DvdLetterMoveTarget = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# GPT partition-type GUID for a Microsoft Reserved (MSR) partition. Source:
# https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-and-gpt-faq
# ("Microsoft Reserved Partition (MSR)") and
# https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-partition_information_gpt
# (PARTITION_MSFT_RESERVED_GUID). This is the one, documented, Windows-
# generated partition type tolerated alongside the single intended data
# partition -- never treated as license to accept any other unexpected
# partition.
$script:MsrPartitionGptType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

function Assert-GuestDiskPreparationFailure {
    <#
        Raises a terminating error for this script's own control flow.
        Never calls exit/Environment.Exit directly, so this function remains
        safe to invoke from a dot-sourced, mocked Pester test -- only the
        top-level invocation guard at the bottom of this file translates a
        thrown failure into a process exit code.
    #>
    param([Parameter(Mandatory = $true)] [string] $Message)
    throw [System.InvalidOperationException]::new($Message)
}

function Test-CurrentIdentityIsAdministratorOrSystem {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.User -and $identity.User.Value -eq 'S-1-5-18'
    $isAdministrator = ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
    return [bool]($isSystem -or $isAdministrator)
}

function Get-ImdsComputeMetadata {
    # https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
    # Credential-free, in-guest-only endpoint; never leaves the host.
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json'
    try {
        return Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -NoProxy -TimeoutSec 15
    }
    catch {
        Assert-GuestDiskPreparationFailure "Unable to query the Azure Instance Metadata Service (IMDS): $($_.Exception.Message)"
    }
}

function Get-WindowsDiskDriveLunMap {
    <#
        Maps Azure LUN -> the Win32_DiskDrive object(s) reporting that LUN
        via the documented SCSILogicalUnit property
        (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive).
        Returns a hashtable of LUN -> array of matching disk-drive objects so
        callers can detect and reject an ambiguous (non-singular) mapping
        rather than guessing.
    #>
    $map = @{}
    foreach ($diskDrive in @(Get-CimInstance -ClassName Win32_DiskDrive)) {
        $lun = [int]$diskDrive.SCSILogicalUnit
        if (-not $map.ContainsKey($lun)) {
            $map[$lun] = @()
        }
        $map[$lun] += $diskDrive
    }
    return $map
}

function Resolve-ApprovedDiskTarget {
    <#
        Resolves exactly one approved expected-disk descriptor to a Windows
        disk number, after independently validating: LUN presence in IMDS,
        managed-disk resource name, managed-disk resource ID subscription/
        resource-group prefix, capacity, an unambiguous (exactly one) WMI
        LUN match, and non-boot/non-system flags. Any failure here stops the
        entire run before any mutation is attempted on any disk.
    #>
    param(
        [Parameter(Mandatory = $true)] $ExpectedDisk,
        [Parameter(Mandatory = $true)] [hashtable] $ImdsDataDisksByLun,
        [Parameter(Mandatory = $true)] [hashtable] $WindowsDiskDriveLunMap,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName
    )

    $lun = [int]$ExpectedDisk.Lun

    if (-not $ImdsDataDisksByLun.ContainsKey($lun)) {
        Assert-GuestDiskPreparationFailure "LUN $lun is not present in this VM's IMDS data-disk inventory; refusing to proceed."
    }
    $imdsDisk = $ImdsDataDisksByLun[$lun]

    if ($imdsDisk.name -ne $ExpectedDisk.DiskName) {
        Assert-GuestDiskPreparationFailure "LUN $lun managed-disk name mismatch: IMDS reports '$($imdsDisk.name)', expected '$($ExpectedDisk.DiskName)'."
    }

    $expectedResourceIdPrefix = "/subscriptions/$ExpectedSubscriptionId/resourceGroups/$ExpectedResourceGroupName/providers/Microsoft.Compute/disks/"
    $actualManagedDiskId = [string]$imdsDisk.managedDisk.id
    if ([string]::IsNullOrWhiteSpace($actualManagedDiskId) -or
        -not $actualManagedDiskId.StartsWith($expectedResourceIdPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $actualManagedDiskId.EndsWith("/$($ExpectedDisk.DiskName)", [System.StringComparison]::OrdinalIgnoreCase)) {
        Assert-GuestDiskPreparationFailure "LUN $lun managed-disk resource ID '$actualManagedDiskId' does not match the expected subscription/resource group/disk name."
    }

    $imdsSizeBytes = $null
    if ($imdsDisk.PSObject.Properties.Name -contains 'diskCapacityBytes' -and $imdsDisk.diskCapacityBytes) {
        $imdsSizeBytes = [int64]$imdsDisk.diskCapacityBytes
    }
    elseif ($imdsDisk.PSObject.Properties.Name -contains 'diskSizeGB' -and $imdsDisk.diskSizeGB) {
        $imdsSizeBytes = [int64]$imdsDisk.diskSizeGB * 1GB
    }
    $expectedSizeBytes = [int64]$ExpectedDisk.SizeBytes
    if (-not $imdsSizeBytes -or [math]::Abs($imdsSizeBytes - $expectedSizeBytes) -gt 1MB) {
        Assert-GuestDiskPreparationFailure "LUN $lun capacity mismatch: IMDS reports approximately $imdsSizeBytes bytes, expected $expectedSizeBytes bytes."
    }

    if (-not $WindowsDiskDriveLunMap.ContainsKey($lun)) {
        Assert-GuestDiskPreparationFailure "LUN $lun does not correspond to any Windows disk device (Win32_DiskDrive.SCSILogicalUnit); refusing to proceed without an unambiguous mapping."
    }
    $matchingDiskDrives = @($WindowsDiskDriveLunMap[$lun])
    if ($matchingDiskDrives.Count -ne 1) {
        Assert-GuestDiskPreparationFailure "LUN $lun maps to $($matchingDiskDrives.Count) Windows disk device(s); an unambiguous one-to-one mapping is required and was not found."
    }
    $windowsDiskNumber = [int]$matchingDiskDrives[0].Index

    $disk = Get-Disk -Number $windowsDiskNumber
    if ($disk.IsBoot -or $disk.IsSystem) {
        Assert-GuestDiskPreparationFailure "LUN $lun resolved to Windows disk $windowsDiskNumber, which is flagged boot and/or system; refusing to proceed."
    }
    if ([math]::Abs([int64]$disk.Size - $expectedSizeBytes) -gt 1MB) {
        Assert-GuestDiskPreparationFailure "LUN $lun resolved to Windows disk $windowsDiskNumber, whose reported size ($($disk.Size) bytes) does not match the expected $expectedSizeBytes bytes."
    }

    return [pscustomobject]@{
        Lun                 = $lun
        DiskNumber          = $windowsDiskNumber
        DiskName            = [string]$ExpectedDisk.DiskName
        SizeBytes           = $expectedSizeBytes
        DriveLetter         = ([string]$ExpectedDisk.DriveLetter).ToUpperInvariant()
        FileSystemLabel     = [string]$ExpectedDisk.FileSystemLabel
        AllocationUnitBytes = [int]$ExpectedDisk.AllocationUnitBytes
    }
}

function Test-ResolvedDiskIdentityStillValid {
    <#
        Immediate pre-mutation re-check: re-queries WMI/Storage state fresh
        (rather than trusting the earlier preflight pass) and confirms the
        LUN -> disk-number mapping, boot/system flags, and size still hold.
        Returns $false (never throws) so the caller can fail the run for
        that specific disk without having already begun any mutation.
    #>
    param([Parameter(Mandatory = $true)] $Target)

    $diskDrive = Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$($Target.DiskNumber)"
    if (-not $diskDrive -or [int]$diskDrive.SCSILogicalUnit -ne [int]$Target.Lun) {
        return $false
    }
    $disk = Get-Disk -Number $Target.DiskNumber
    if ($disk.IsBoot -or $disk.IsSystem) {
        return $false
    }
    if ([math]::Abs([int64]$disk.Size - [int64]$Target.SizeBytes) -gt 1MB) {
        return $false
    }
    return $true
}

function Invoke-ApprovedDiskPreparation {
    <#
        Applies the idempotent check-then-act behavior for exactly one
        already-resolved, already-identity-verified target:
          - RAW, zero partitions                     -> initialize, partition, format.
          - GPT, one matching data partition/volume   -> already correct, no-op.
          - GPT, anything else                        -> hard failure, no auto-repair.
          - any other PartitionStyle                  -> hard failure.
    #>
    param([Parameter(Mandatory = $true)] $Target)

    $disk = Get-Disk -Number $Target.DiskNumber
    $partitions = @(Get-Partition -DiskNumber $Target.DiskNumber -ErrorAction SilentlyContinue)
    $dataPartitions = @($partitions | Where-Object { $_.GptType -ne $script:MsrPartitionGptType })

    if ($disk.PartitionStyle -eq 'RAW') {
        if ($partitions.Count -gt 0) {
            Assert-GuestDiskPreparationFailure "Windows disk $($Target.DiskNumber) reports PartitionStyle RAW but already has $($partitions.Count) partition(s); inconsistent state, refusing to proceed."
        }

        if (-not (Test-ResolvedDiskIdentityStillValid -Target $Target)) {
            Assert-GuestDiskPreparationFailure "Windows disk $($Target.DiskNumber) failed immediate pre-mutation identity re-validation; refusing to proceed."
        }

        Write-Output "Disk $($Target.DiskNumber) (LUN $($Target.Lun), $($Target.DiskName)) is RAW with no partitions -- initializing."
        Initialize-Disk -Number $Target.DiskNumber -PartitionStyle GPT

        $partitionsAfterInit = @(Get-Partition -DiskNumber $Target.DiskNumber -ErrorAction SilentlyContinue)
        $unexpectedAfterInit = @($partitionsAfterInit | Where-Object { $_.GptType -ne $script:MsrPartitionGptType })
        if ($unexpectedAfterInit.Count -gt 0) {
            Assert-GuestDiskPreparationFailure "Disk $($Target.DiskNumber) shows unexpected partition(s) immediately after GPT initialization; stopping for manual review rather than proceeding."
        }

        $newPartition = New-Partition -DiskNumber $Target.DiskNumber -UseMaximumSize -DriveLetter ([char]$Target.DriveLetter)
        $null = Format-Volume -Partition $newPartition -FileSystem NTFS `
            -AllocationUnitSize $Target.AllocationUnitBytes `
            -NewFileSystemLabel $Target.FileSystemLabel `
            -Confirm:$false -Force

        Write-Output "Disk $($Target.DiskNumber) initialized, partitioned, and formatted as $($Target.DriveLetter): ('$($Target.FileSystemLabel)')."
        return
    }

    if ($disk.PartitionStyle -eq 'GPT') {
        if ($dataPartitions.Count -eq 0) {
            Assert-GuestDiskPreparationFailure "Disk $($Target.DiskNumber) is already GPT-initialized but has no data partition -- an ambiguous partial-completion state; stopping for manual review rather than resuming automatically."
        }
        if ($dataPartitions.Count -gt 1) {
            Assert-GuestDiskPreparationFailure "Disk $($Target.DiskNumber) has $($dataPartitions.Count) non-reserved partitions; the expected single-data-partition layout was not found, refusing to proceed."
        }

        $dataPartition = $dataPartitions[0]
        $volume = Get-Volume -Partition $dataPartition -ErrorAction SilentlyContinue
        if (-not $volume) {
            Assert-GuestDiskPreparationFailure "Disk $($Target.DiskNumber) has a data partition but no formatted volume -- an ambiguous partial-completion state; stopping for manual review."
        }

        $currentDriveLetter = if ($dataPartition.DriveLetter) { [string]$dataPartition.DriveLetter } else { '' }
        $matchesIntendedLayout = (
            $currentDriveLetter.ToUpperInvariant() -eq $Target.DriveLetter -and
            $volume.FileSystem -eq 'NTFS' -and
            $volume.FileSystemLabel -eq $Target.FileSystemLabel -and
            [int64]$volume.AllocationUnitSize -eq [int64]$Target.AllocationUnitBytes
        )

        if ($matchesIntendedLayout) {
            Write-Output "Disk $($Target.DiskNumber) already matches the intended layout ($($Target.DriveLetter): '$($Target.FileSystemLabel)') -- validated, no action taken."
            return
        }

        Assert-GuestDiskPreparationFailure ("Disk $($Target.DiskNumber) is already initialized/formatted but does not match the intended layout " +
            "(letter='$currentDriveLetter', fileSystem='$($volume.FileSystem)', label='$($volume.FileSystemLabel)', allocationUnitSize=$($volume.AllocationUnitSize)); " +
            'refusing to repair or reformat automatically.')
        return
    }

    Assert-GuestDiskPreparationFailure "Disk $($Target.DiskNumber) has unexpected PartitionStyle '$($disk.PartitionStyle)'; refusing to proceed."
}

function Move-DvdRomDriveLetterIfRequired {
    <#
        SQL-only, conditional on a non-empty $DvdLetterMoveTarget. Moves the
        drive letter of a confirmed CD-ROM-type volume at E: to the target
        letter, only if that target letter is free. Any other state (E: not
        a CD-ROM volume, or the target letter already in use) is a hard
        failure. Never touches a DVD-ROM letter when $DvdLetterMoveTarget is
        empty (the APP VM case).
    #>
    param([Parameter(Mandatory = $false)] [string] $DvdLetterMoveTarget = '')

    if ([string]::IsNullOrWhiteSpace($DvdLetterMoveTarget)) {
        return
    }

    $targetLetter = $DvdLetterMoveTarget.ToUpperInvariant()
    $dvdCandidateVolume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='E:'" -ErrorAction SilentlyContinue

    if (-not $dvdCandidateVolume) {
        Write-Output 'No volume currently mounted at E: -- nothing to move.'
        return
    }

    # Win32_Volume.DriveType 5 == CD-ROM. https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-volume
    if ([int]$dvdCandidateVolume.DriveType -ne 5) {
        Assert-GuestDiskPreparationFailure "E: is not a CD-ROM volume (DriveType=$($dvdCandidateVolume.DriveType)); refusing to move a non-DVD-ROM volume."
    }

    $targetAlreadyInUse = Get-Volume -DriveLetter $targetLetter -ErrorAction SilentlyContinue
    if ($targetAlreadyInUse) {
        Assert-GuestDiskPreparationFailure "Target drive letter ${targetLetter}: is already in use; refusing to move the DVD-ROM there."
    }

    Set-CimInstance -InputObject $dvdCandidateVolume -Property @{ DriveLetter = "${targetLetter}:" }
    Write-Output "Moved the empty virtual DVD-ROM from E: to ${targetLetter}:."
}

function Invoke-GuestDiskPreparation {
    param(
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $ExpectedComputerName,
        [Parameter(Mandatory = $true)] [string] $ExpectedDisksJson,
        [Parameter(Mandatory = $false)] [string] $DvdLetterMoveTarget = ''
    )

    if (-not (Test-CurrentIdentityIsAdministratorOrSystem)) {
        Assert-GuestDiskPreparationFailure "This script must run as SYSTEM or an Administrator. Current identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }

    try {
        $parsedExpectedDisks = ConvertFrom-Json -InputObject $ExpectedDisksJson
    }
    catch {
        Assert-GuestDiskPreparationFailure "ExpectedDisksJson could not be parsed as JSON: $($_.Exception.Message)"
    }
    # ConvertFrom-Json writes each element of a top-level JSON array as a
    # separate pipeline object rather than a single array value — @(...)
    # here re-collects them into one array regardless of whether the JSON
    # held one disk or several, so a single-disk (APP) and multi-disk (SQL)
    # payload are both handled identically below.
    $expectedDisks = @($parsedExpectedDisks)
    if ($expectedDisks.Count -eq 0) {
        Assert-GuestDiskPreparationFailure 'ExpectedDisksJson resolved to zero approved disks; refusing to proceed with nothing to validate.'
    }

    # ---- Step 1: independent Azure/Windows identity verification (IMDS + local hostname) ----
    $compute = Get-ImdsComputeMetadata

    if ([string]::IsNullOrWhiteSpace([string]$compute.subscriptionId) -or
        [string]::IsNullOrWhiteSpace([string]$compute.resourceGroupName) -or
        [string]::IsNullOrWhiteSpace([string]$compute.name)) {
        Assert-GuestDiskPreparationFailure 'IMDS returned incomplete compute identity metadata (missing subscriptionId, resourceGroupName, or name).'
    }
    if ([string]$compute.subscriptionId -ne $ExpectedSubscriptionId) {
        Assert-GuestDiskPreparationFailure "Subscription mismatch: IMDS reports '$($compute.subscriptionId)', expected '$ExpectedSubscriptionId'."
    }
    if ([string]$compute.resourceGroupName -ne $ExpectedResourceGroupName) {
        Assert-GuestDiskPreparationFailure "Resource group mismatch: IMDS reports '$($compute.resourceGroupName)', expected '$ExpectedResourceGroupName'."
    }
    if ([string]$compute.name -ne $ExpectedVmName) {
        Assert-GuestDiskPreparationFailure "VM name mismatch: IMDS reports '$($compute.name)', expected '$ExpectedVmName'."
    }

    $actualComputerName = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($actualComputerName)) {
        Assert-GuestDiskPreparationFailure 'Could not determine the local Windows computer name.'
    }
    if ($actualComputerName -ne $ExpectedComputerName) {
        Assert-GuestDiskPreparationFailure "Windows computer name mismatch: local reports '$actualComputerName', expected '$ExpectedComputerName'."
    }

    Write-Output "Identity verified: subscriptionId=$($compute.subscriptionId) resourceGroupName=$($compute.resourceGroupName) vmName=$($compute.name) computerName=$actualComputerName"

    if (-not $compute.storageProfile -or -not $compute.storageProfile.dataDisks) {
        Assert-GuestDiskPreparationFailure 'IMDS reported no data disks attached to this VM.'
    }
    $imdsDataDisksByLun = @{}
    foreach ($imdsDisk in @($compute.storageProfile.dataDisks)) {
        $lun = [int]$imdsDisk.lun
        if ($imdsDataDisksByLun.ContainsKey($lun)) {
            Assert-GuestDiskPreparationFailure "IMDS reports more than one data disk at LUN $lun; cannot establish an unambiguous mapping."
        }
        $imdsDataDisksByLun[$lun] = $imdsDisk
    }

    $windowsDiskDriveLunMap = Get-WindowsDiskDriveLunMap

    # ---- Step 2: resolve and fully validate every approved target before any mutation ----
    $targets = @()
    foreach ($expectedDisk in $expectedDisks) {
        $targets += Resolve-ApprovedDiskTarget -ExpectedDisk $expectedDisk `
            -ImdsDataDisksByLun $imdsDataDisksByLun `
            -WindowsDiskDriveLunMap $windowsDiskDriveLunMap `
            -ExpectedSubscriptionId $ExpectedSubscriptionId `
            -ExpectedResourceGroupName $ExpectedResourceGroupName
    }

    $duplicateDiskNumbers = $targets | Group-Object DiskNumber | Where-Object { $_.Count -gt 1 }
    if ($duplicateDiskNumbers) {
        Assert-GuestDiskPreparationFailure 'More than one approved disk descriptor resolved to the same Windows disk number; refusing to proceed.'
    }
    $duplicateDriveLetters = $targets | Group-Object DriveLetter | Where-Object { $_.Count -gt 1 }
    if ($duplicateDriveLetters) {
        Assert-GuestDiskPreparationFailure 'More than one approved disk descriptor requests the same drive letter; refusing to proceed.'
    }

    # ---- Step 3: conflicting drive-letter preflight across the whole guest, not only approved disks ----
    $allPartitions = @(Get-Partition -ErrorAction SilentlyContinue)
    foreach ($target in $targets) {
        $partitionAlreadyOwningLetter = $allPartitions | Where-Object { $_.DriveLetter -and [string]$_.DriveLetter -eq $target.DriveLetter }
        $conflicting = $partitionAlreadyOwningLetter | Where-Object { $_.DiskNumber -ne $target.DiskNumber }
        if ($conflicting) {
            Assert-GuestDiskPreparationFailure "Drive letter $($target.DriveLetter): is already in use by a disk other than the approved target (Windows disk $($target.DiskNumber)); refusing to proceed."
        }
    }

    # ---- Step 4: per-disk idempotent validate-or-prepare (no mutation has occurred before this point) ----
    foreach ($target in $targets) {
        Invoke-ApprovedDiskPreparation -Target $target
    }

    # ---- Step 5: SQL-only DVD-ROM letter move, never touching anything else ----
    Move-DvdRomDriveLetterIfRequired -DvdLetterMoveTarget $DvdLetterMoveTarget

    Write-Output 'Guest data-disk preparation completed successfully.'
}

# ---- Top-level invocation guard ----
# Set LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY=1 before dot-sourcing this file
# (e.g. from a Pester test) to load every function above without executing
# Invoke-GuestDiskPreparation, so cmdlets such as Initialize-Disk,
# New-Partition, Format-Volume, and Set-CimInstance can be safely mocked and
# asserted against instead of ever running on a real local disk.
if ($env:LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-GuestDiskPreparation -ExpectedSubscriptionId $ExpectedSubscriptionId `
            -ExpectedResourceGroupName $ExpectedResourceGroupName `
            -ExpectedVmName $ExpectedVmName `
            -ExpectedComputerName $ExpectedComputerName `
            -ExpectedDisksJson $ExpectedDisksJson `
            -DvdLetterMoveTarget $DvdLetterMoveTarget
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

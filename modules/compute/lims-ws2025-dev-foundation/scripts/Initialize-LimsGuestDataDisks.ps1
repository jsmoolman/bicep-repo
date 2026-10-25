<#
.SYNOPSIS
    Safely initializes, partitions, formats, labels, and assigns a drive
    letter to a small, explicit, pre-approved set of RAW Azure managed data
    disks inside a single Windows guest (vm-lims-dev-v2-westeu-001 or
    vm-lims-dev-v2-westeu-002 only) -- and nothing else.

.DESCRIPTION
    Delivered inline via a Microsoft.Compute/virtualMachines/runCommands
    resource (see modules/compute/lims-ws2025-dev-foundation/main.bicep) --
    never from a storage account, never containing a secret.

    SAFETY MODEL (see docs/operations.md for the full behavioral contract):

    1) Independent fixed allowlist (Get-ApprovedDiskPreparationAllowlist).
       The exact approved subscription/resource-group/VM-name/computer-name/
       disk/LUN/size/drive-letter/label/allocation-unit combination for the
       APP and SQL targets is hardcoded in this script, independent of any
       caller-supplied parameter. Both the caller-supplied -Expected*
       parameters AND the live Azure Instance Metadata Service (IMDS)
       response are each independently required to match this fixed
       allowlist -- the two of them merely agreeing with EACH OTHER is not
       sufficient, since a misconfigured caller and a misdirected guest
       could in principle agree with each other while both being wrong.

    2) Guest disk correlation that excludes the OS and temporary disks
       BEFORE resolving data disks (see Select-NonOsNonTemporaryDiskCandidates).
       The OS disk is excluded via the Windows Storage module's own
       documented IsBoot/IsSystem flags
       (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk),
       never by a hardcoded disk number. The Azure temporary (resource) disk
       carries no Azure LUN and never appears in IMDS's
       storageProfile.dataDisks[] array, so it cannot be positively resolved
       by LUN the way a real data disk can; this script instead excludes it
       by deriving, at runtime, whichever SCSI bus/port pair the OS disk
       itself is actually attached to (never a hardcoded port number such as
       assuming data disks are always on port 1) and excluding every OTHER
       disk sharing that exact pair -- the documented pattern of the
       platform's own boot controller hosting both the OS and the temporary
       disk together (see https://troubleshootingsql.com, "the C: drive
       would also be an IDE drive but with a SCSI Target ID = 0", describing
       the OS/temporary disks sharing one controller while data disks use
       another). Only after this exclusion are the remaining candidate disks
       correlated to an approved Azure LUN via the documented
       Win32_DiskDrive.SCSILogicalUnit property
       (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive),
       which Microsoft's own "How to map Azure Disks to Windows VM guest
       disks" guidance
       (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/azure-to-guest-disk-mapping)
       identifies as the correct way to disambiguate same-size data disks.
       Disks are never selected by size alone, by picking the first LUN
       match, or by enumerating "all RAW disks" -- any remaining ambiguity
       (zero or more than one candidate at a given LUN) is a hard failure.

    3) Stable identity capture and re-validation. Every resolved disk's
       Windows Storage module UniqueId
       (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk)
       is captured at first resolution. -Mode Apply unconditionally rebuilds
       the ENTIRE plan above from scratch -- fresh IMDS query, fresh guest
       disk/partition/volume/DVD inventory, fresh allowlist/identity/LUN/
       mapping/state/partition/destination checks -- immediately before any
       mutation, and additionally confirms every disk's UniqueId has not
       changed between the two plans. A previous (or even this same
       invocation's first) report is never treated as authorization to
       trust stale state.

    4) Complete, non-mutating preflight before any mutation on either
       target disk of a VM. Every approved disk's layout, partitions,
       volumes, mount paths (partition AccessPaths, not only drive letters),
       disk state, and drive-letter conflicts (against the WHOLE guest, not
       only approved disks) are validated up front. If any approved disk on
       a VM fails validation, the entire VM's plan is Blocked and ZERO
       mutations are attempted against ANY disk on that VM -- for example, a
       SQL LOG validation failure leaves SQL DATA completely untouched, even
       if SQL DATA's own checks would otherwise have passed.
       Guest inventory (disks, partitions, volumes, DVD volumes) is fetched
       IN FULL exactly once per plan build, then filtered entirely in
       memory. This deliberately avoids per-letter/per-disk filtered guest
       queries with -ErrorAction SilentlyContinue, which would make a
       genuine query failure indistinguishable from a legitimate "no
       partitions"/"free letter" result -- a real query failure on the
       initial full fetch propagates as a hard failure instead.

    5) RAW alone is never sufficient to initialize a disk -- it is treated
       only as one of several required preconditions (also: unambiguous
       LUN/name/size/UniqueId resolution, zero existing partitions, and not
       boot/system), never as proof a disk has never held data. A disk
       already carrying the exact intended GPT layout (single data
       partition of the expected type/size/mount-path, NTFS, matching
       allocation unit size, label, and drive letter) is validated and left
       completely untouched, including when it already holds files -- this
       makes the script safe to run on every redeployment/revalidation.
       Windows may create a Microsoft Reserved (MSR) partition automatically
       as part of GPT initialization (every GPT disk must carry one -- see
       https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-and-gpt-faq)
       -- this one documented partition type is tolerated; any other
       unexpected partition, partition type, undersized/oversized layout, or
       partial completion (GPT-initialized but no/incomplete data partition)
       is a hard failure, never auto-repaired, auto-reformatted, or retried.
       Clear-Disk, diskpart clean, partition deletion, storage pools, and
       any blanket/wildcard disk-state change are never used anywhere in
       this script. Every mutating adapter targets an explicit disk,
       partition, or volume object/number -- never a drive letter alone.
       Unnecessary -Force flags are not used; Format-Volume suppresses only
       the interactive confirmation prompt (-Confirm:$false), which is
       required for unattended Run Command execution and is not itself a
       destructive-bypass flag.

    6) SQL-only, conditional DVD-ROM letter move (E: -> the fixed
       allowlist's DvdLetterMoveTarget, 'Z'). E: and the target letter are
       both preflighted (read-only) before any mutation on the VM. The move
       is attempted only when E: is confirmed to be an empty (no loaded
       media -- a non-empty volume label is treated as loaded media and
       blocks the move) CD-ROM-type volume (Win32_Volume.DriveType=5) and
       the target letter is confirmed free, and -- critically -- only when
       the approved SQL DATA disk at E: is NOT already correctly prepared
       (if it is, E: already belongs to that validated data volume: no DVD
       action is taken, and the run does not fail merely because E: is no
       longer a DVD-ROM). When a move is required, it is performed BEFORE
       the SQL DATA disk's own partition is created at E:, and the move's
       success is independently re-confirmed before any further mutation.
       The APP VM's DvdLetterMoveTarget is always empty, so its DVD-ROM
       letter is never evaluated for a move and never touched.

    7) This script never touches pagefile configuration, the Azure
       temporary disk itself, SQL TempDB/configuration/folders/permissions/
       shares, or application content.

    TESTABILITY. Decision/planning logic (Get-ApprovedDiskPreparationAllowlist,
    Test-TargetIdentityMatchesAllowlist, Select-NonOsNonTemporaryDiskCandidates,
    Resolve-ApprovedDiskTarget, Get-DiskPreparationPlan, Get-DvdPreparationPlan,
    Get-GuestDiskPreparationPlan) operates exclusively on plain data objects
    (hashtables/pscustomobjects) and never calls a real cmdlet -- it runs
    identically, and is fully unit-testable, on any OS with any PowerShell
    version, including Pester on Ubuntu CI with no Windows Storage cmdlets,
    Windows CIM schemas, or administrator APIs available. All interaction
    with real cmdlets is isolated in small, separately named "*Adapter"
    functions (inventory adapters such as Get-GuestDiskInventoryAdapter;
    mutation adapters such as Initialize-ApprovedDiskAdapter). Pester tests
    mock only these adapters -- never the decision/planning functions
    themselves -- so the actual safety logic always runs for real in every
    test. See Initialize-LimsGuestDataDisks.Tests.ps1.

    EXECUTION RUNTIME. Managed Run Command on Windows executes scripts under
    Windows PowerShell 5.1 by default (scriptShell: 'Default' -- see
    https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines/runcommands
    and https://devblogs.microsoft.com/azure-vm-runtime/using-powershell7-with-managed-runcommand/,
    "all scripts run through Managed RunCommand will by default use
    Powershell 5"). This script deliberately targets Windows PowerShell 5.1
    syntax and does not request scriptShell: 'Powershell7' or install
    PowerShell 7 on either VM merely to use newer syntax (e.g. -NoProxy on
    Invoke-RestMethod, which requires PowerShell 6+). Requires administrator
    or SYSTEM execution; Run Command executes as SYSTEM by default when no
    RunAsUser is supplied
    (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command,
    "Scripts run as System on Windows"), and this script independently
    verifies that execution context rather than relying solely on that
    default.

.PARAMETER Target
    Which fixed allowlist entry this invocation is for: 'App' or 'Sql'.
    Mandatory, with no default -- an invocation that omits -Target is
    rejected by PowerShell parameter binding itself before any other check
    runs, rather than silently defaulting to one target or attempting both.

.PARAMETER Mode
    'Validate' (read-only: builds and prints the full plan, never calls a
    mutating adapter -- mutation functions are unreachable from this code
    path) or 'Apply' (rebuilds the plan fresh immediately before mutating,
    then executes exactly the actions that plan approved). Mandatory, with
    no default.

.PARAMETER ExpectedSubscriptionId
    The caller-supplied subscription ID this VM is expected to belong to.
    Checked against the fixed allowlist (not merely against IMDS).

.PARAMETER ExpectedResourceGroupName
    The caller-supplied resource group name this VM is expected to belong
    to. Checked against the fixed allowlist (not merely against IMDS).

.PARAMETER ExpectedVmName
    The caller-supplied Azure VM resource name. Checked against the fixed
    allowlist (not merely against IMDS).

.PARAMETER ExpectedComputerName
    The caller-supplied Windows (NetBIOS) computer name. Checked against the
    fixed allowlist (not merely against the actual local $env:COMPUTERNAME).

.PARAMETER ExpectedDisksJson
    A JSON array of objects, each describing one disk the caller believes is
    approved: Lun, DiskName, SizeBytes, DriveLetter, FileSystemLabel,
    AllocationUnitBytes. Checked against the fixed allowlist entry for
    -Target -- a caller-supplied descriptor that does not exactly match the
    fixed allowlist is rejected before any guest action.

.PARAMETER DvdLetterMoveTarget
    Caller-supplied DVD-ROM letter-move target (no colon), or an empty
    string. Checked against the fixed allowlist entry for -Target.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('App', 'Sql')]
    [string] $Target,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Validate', 'Apply')]
    [string] $Mode,

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

function Test-IsMsrPartition {
    param([Parameter(Mandatory = $true)] $Partition)
    $gptType = [string]$Partition.GptType
    if ([string]::IsNullOrWhiteSpace($gptType)) { return $false }
    return $gptType.ToLowerInvariant() -eq $script:MsrPartitionGptType.ToLowerInvariant()
}

# =============================================================================
# DECISION / PLANNING LOGIC -- plain data objects only, no real cmdlet calls.
# Fully unit-testable on any platform (including Pester on Ubuntu CI).
# =============================================================================

function Get-ApprovedDiskPreparationAllowlist {
    <#
        Independent, fixed, hardcoded allowlist -- the single source of
        truth for exactly which subscription/resource-group/VM/computer/
        disk/LUN/size/drive-letter/label/allocation-unit combination may
        ever be touched. See the module .DESCRIPTION above: caller
        parameters and IMDS must EACH independently match this allowlist.
    #>
    return @{
        App = [pscustomobject]@{
            SubscriptionId      = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            ResourceGroupName   = 'rg-compute-lims-dev-westeu'
            VmName              = 'vm-lims-dev-v2-westeu-001'
            ComputerName        = 'lims-dev-v2-001'
            DvdLetterMoveTarget = ''
            Disks               = @(
                [pscustomobject]@{
                    Lun                 = 0
                    DiskName            = 'appdata-vm-lims-dev-v2-westeu-001'
                    SizeBytes           = [int64]128 * 1024 * 1024 * 1024
                    DriveLetter         = 'A'
                    FileSystemLabel     = 'LIMS-App'
                    AllocationUnitBytes = 4096
                }
            )
        }
        Sql = [pscustomobject]@{
            SubscriptionId      = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            ResourceGroupName   = 'rg-compute-lims-dev-westeu'
            VmName              = 'vm-lims-dev-v2-westeu-002'
            ComputerName        = 'lims-dev-v2-002'
            DvdLetterMoveTarget = 'Z'
            Disks               = @(
                [pscustomobject]@{
                    Lun                 = 0
                    DiskName            = 'sqldata-vm-lims-dev-v2-westeu-002'
                    SizeBytes           = [int64]1024 * 1024 * 1024 * 1024
                    DriveLetter         = 'E'
                    FileSystemLabel     = 'SQL-Data'
                    AllocationUnitBytes = 65536
                }
                [pscustomobject]@{
                    Lun                 = 1
                    DiskName            = 'sqllog-vm-lims-dev-v2-westeu-002'
                    SizeBytes           = [int64]512 * 1024 * 1024 * 1024
                    DriveLetter         = 'F'
                    FileSystemLabel     = 'SQL-Logs'
                    AllocationUnitBytes = 65536
                }
            )
        }
    }
}

function Test-TargetIdentityMatchesAllowlist {
    <#
        Returns $null when every caller-supplied value AND the IMDS compute
        identity each independently match the fixed allowlist entry for
        -Target; otherwise returns a non-null error string describing the
        first mismatch found. Never compares caller parameters against IMDS
        directly -- both are compared only against the fixed allowlist.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $ExpectedComputerName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $ExpectedDisks,
        # Mandatory but legitimately '' for App (its allowlist entry's own
        # DvdLetterMoveTarget is empty) -- AllowEmptyString prevents
        # PowerShell's own default Mandatory-parameter-rejects-empty-string
        # behavior from throwing a raw ParameterBindingValidationException
        # on App's normal, valid, non-mutating input.
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DvdLetterMoveTarget,
        [Parameter(Mandatory = $true)] $ImdsCompute
    )

    $allowlist = Get-ApprovedDiskPreparationAllowlist
    if (-not $allowlist.ContainsKey($Target)) {
        return "Unknown target '$Target'; no fixed allowlist entry exists for it."
    }
    $entry = $allowlist[$Target]

    # 1) Caller-supplied parameters must exactly match the fixed allowlist.
    if ($ExpectedSubscriptionId -ne $entry.SubscriptionId) {
        return "Caller-supplied subscription ID '$ExpectedSubscriptionId' does not match the fixed allowlist for target '$Target'."
    }
    if ($ExpectedResourceGroupName -ne $entry.ResourceGroupName) {
        return "Caller-supplied resource group '$ExpectedResourceGroupName' does not match the fixed allowlist for target '$Target'."
    }
    if ($ExpectedVmName -ne $entry.VmName) {
        return "Caller-supplied VM name '$ExpectedVmName' does not match the fixed allowlist for target '$Target'. Substituting a v1 or any other VM name is rejected here."
    }
    if ($ExpectedComputerName -ne $entry.ComputerName) {
        return "Caller-supplied computer name '$ExpectedComputerName' does not match the fixed allowlist for target '$Target'."
    }
    if ($DvdLetterMoveTarget -ne $entry.DvdLetterMoveTarget) {
        return "Caller-supplied DVD letter move target '$DvdLetterMoveTarget' does not match the fixed allowlist for target '$Target'."
    }

    $expectedDiskArray = @($ExpectedDisks)
    $allowlistDiskArray = @($entry.Disks)
    if ($expectedDiskArray.Count -ne $allowlistDiskArray.Count) {
        return "Caller-supplied disk count ($($expectedDiskArray.Count)) does not match the fixed allowlist for target '$Target' ($($allowlistDiskArray.Count))."
    }
    foreach ($callerDisk in $expectedDiskArray) {
        $allowlistDisk = $allowlistDiskArray | Where-Object { [int]$_.Lun -eq [int]$callerDisk.Lun }
        if (-not $allowlistDisk) {
            return "Caller-supplied LUN $($callerDisk.Lun) is not part of the fixed allowlist for target '$Target'."
        }
        if ($allowlistDisk.DiskName -ne [string]$callerDisk.DiskName -or
            [int64]$allowlistDisk.SizeBytes -ne [int64]$callerDisk.SizeBytes -or
            $allowlistDisk.DriveLetter -ne ([string]$callerDisk.DriveLetter).ToUpperInvariant() -or
            $allowlistDisk.FileSystemLabel -ne [string]$callerDisk.FileSystemLabel -or
            [int64]$allowlistDisk.AllocationUnitBytes -ne [int64]$callerDisk.AllocationUnitBytes) {
            return "Caller-supplied descriptor for LUN $($callerDisk.Lun) does not exactly match the fixed allowlist for target '$Target'."
        }
    }

    # 2) IMDS must INDEPENDENTLY match the same fixed allowlist entry -- not
    #    merely agree with the caller-supplied parameters checked above.
    if ([string]$ImdsCompute.subscriptionId -ne $entry.SubscriptionId) {
        return "IMDS subscription ID '$($ImdsCompute.subscriptionId)' does not match the fixed allowlist for target '$Target'."
    }
    if ([string]$ImdsCompute.resourceGroupName -ne $entry.ResourceGroupName) {
        return "IMDS resource group '$($ImdsCompute.resourceGroupName)' does not match the fixed allowlist for target '$Target'."
    }
    if ([string]$ImdsCompute.name -ne $entry.VmName) {
        return "IMDS VM name '$($ImdsCompute.name)' does not match the fixed allowlist for target '$Target'."
    }

    return $null
}

function Select-NonOsNonTemporaryDiskCandidates {
    <#
        Excludes the OS disk (Get-Disk's own documented IsBoot/IsSystem
        flags) and the Azure temporary/resource disk (derived at runtime as
        any OTHER disk sharing the OS disk's own ScsiBus/ScsiPort pair --
        never a hardcoded port number) from the candidate pool later used to
        resolve approved data-disk targets by LUN. See the module
        .DESCRIPTION for the full reasoning and sources.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDiskInventory)

    $osDisks = @($GuestDiskInventory | Where-Object { $_.IsBoot -or $_.IsSystem })
    if ($osDisks.Count -ne 1) {
        return [pscustomobject]@{
            Candidates = @()
            Error      = "Expected exactly one boot/system Windows disk, found $($osDisks.Count); refusing to proceed without an unambiguous OS disk to exclude."
        }
    }
    $osDisk = $osDisks[0]
    $osControllerPair = "$($osDisk.ScsiBus)/$($osDisk.ScsiPort)"

    $candidates = @($GuestDiskInventory | Where-Object {
            (-not $_.IsBoot) -and (-not $_.IsSystem) -and
            ("$($_.ScsiBus)/$($_.ScsiPort)") -ne $osControllerPair
        })

    return [pscustomobject]@{
        Candidates = $candidates
        Error      = $null
    }
}

function Resolve-ApprovedDiskTarget {
    <#
        Resolves exactly one approved disk descriptor to a Windows disk,
        after independently validating: an unambiguous IMDS LUN match,
        managed-disk resource name/ID, capacity, an unambiguous match among
        the (already OS/temporary-excluded) candidate guest disks, non-boot/
        non-system flags, and a captured stable UniqueId. Returns a
        pscustomobject with either .Target (resolved) or .Error (a reason
        string) set -- never throws, so callers can continue collecting
        every error for the whole VM before deciding anything is Blocked.
    #>
    param(
        [Parameter(Mandatory = $true)] $ExpectedDisk,
        # Both legitimately empty when a VM is (mis)configured with fewer
        # data disks than expected -- AllowEmptyCollection lets that produce
        # this function's own clean "0 found" error below instead of a raw
        # ParameterBindingValidationException.
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $ImdsDataDisks,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $CandidateGuestDisks,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName
    )

    $lun = [int]$ExpectedDisk.Lun

    $imdsMatches = @($ImdsDataDisks | Where-Object { [int]$_.lun -eq $lun })
    if ($imdsMatches.Count -ne 1) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun does not resolve to exactly one IMDS data disk ($($imdsMatches.Count) found)." }
    }
    $imdsDisk = $imdsMatches[0]

    if ([string]$imdsDisk.name -ne [string]$ExpectedDisk.DiskName) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun managed-disk name mismatch: IMDS reports '$($imdsDisk.name)', expected '$($ExpectedDisk.DiskName)'." }
    }

    $expectedResourceIdPrefix = "/subscriptions/$ExpectedSubscriptionId/resourceGroups/$ExpectedResourceGroupName/providers/Microsoft.Compute/disks/"
    $actualManagedDiskId = [string]$imdsDisk.managedDisk.id
    if ([string]::IsNullOrWhiteSpace($actualManagedDiskId) -or
        -not $actualManagedDiskId.StartsWith($expectedResourceIdPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $actualManagedDiskId.EndsWith("/$($ExpectedDisk.DiskName)", [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun managed-disk resource ID '$actualManagedDiskId' does not match the expected subscription/resource group/disk name." }
    }

    $imdsSizeBytes = $null
    if ($imdsDisk.PSObject.Properties.Name -contains 'diskCapacityBytes' -and $imdsDisk.diskCapacityBytes) {
        $imdsSizeBytes = [int64]$imdsDisk.diskCapacityBytes
    }
    elseif ($imdsDisk.PSObject.Properties.Name -contains 'diskSizeGB' -and $imdsDisk.diskSizeGB) {
        $imdsSizeBytes = [int64]$imdsDisk.diskSizeGB * 1024 * 1024 * 1024
    }
    $expectedSizeBytes = [int64]$ExpectedDisk.SizeBytes
    if (-not $imdsSizeBytes -or [math]::Abs($imdsSizeBytes - $expectedSizeBytes) -gt 1048576) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun capacity mismatch: IMDS reports approximately $imdsSizeBytes bytes, expected $expectedSizeBytes bytes." }
    }

    $guestMatches = @($CandidateGuestDisks | Where-Object { [int]$_.ScsiLogicalUnit -eq $lun })
    if ($guestMatches.Count -ne 1) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolves to $($guestMatches.Count) non-OS/non-temporary Windows disk device(s) after exclusion; an unambiguous one-to-one mapping is required." }
    }
    $guestDisk = $guestMatches[0]

    if ($guestDisk.IsBoot -or $guestDisk.IsSystem) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), which is flagged boot and/or system; refusing to proceed." }
    }
    if ([math]::Abs([int64]$guestDisk.SizeBytes - $expectedSizeBytes) -gt 1048576) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), whose reported size ($($guestDisk.SizeBytes) bytes) does not match the expected $expectedSizeBytes bytes." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$guestDisk.UniqueId)) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), which reported no stable UniqueId; refusing to proceed without one to re-validate against immediately before mutation." }
    }

    return [pscustomobject]@{
        Target = [pscustomobject]@{
            Lun                 = $lun
            DiskNumber          = [int]$guestDisk.Number
            DiskUniqueId        = [string]$guestDisk.UniqueId
            DiskName            = [string]$ExpectedDisk.DiskName
            SizeBytes           = $expectedSizeBytes
            DriveLetter         = ([string]$ExpectedDisk.DriveLetter).ToUpperInvariant()
            FileSystemLabel     = [string]$ExpectedDisk.FileSystemLabel
            AllocationUnitBytes = [int64]$ExpectedDisk.AllocationUnitBytes
        }
        Error  = $null
    }
}

function Get-DiskPreparationPlan {
    <#
        Decides exactly one of: Initialize (RAW, zero partitions -- every
        identity/mapping check already passed in Resolve-ApprovedDiskTarget),
        NoOp (GPT, already matching the intended layout exactly, including
        partition type/capacity/mount path -- left untouched even if it
        already holds files), or Fail (anything else: unexpected partition
        count/type/size/mount-path, partial completion, mismatched NTFS
        layout, or an unexpected PartitionStyle). Never mutates anything.
    #>
    param(
        [Parameter(Mandatory = $true)] $Target,
        [Parameter(Mandatory = $true)] $GuestDisk,
        # A RAW disk with zero partitions -- the normal, expected,
        # not-yet-initialized state -- legitimately passes an empty array
        # here; AllowEmptyCollection prevents that valid, common input from
        # throwing a raw ParameterBindingValidationException.
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions,
        [Parameter(Mandatory = $false)] $Volume
    )

    $dataPartitions = @($Partitions | Where-Object { -not (Test-IsMsrPartition $_) })

    if ($GuestDisk.PartitionStyle -eq 'RAW') {
        if (@($Partitions).Count -gt 0) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Windows disk $($Target.DiskNumber) reports PartitionStyle RAW but already has $(@($Partitions).Count) partition(s); inconsistent state, refusing to proceed." }
        }
        return [pscustomobject]@{ Action = 'Initialize'; Reason = $null }
    }

    if ($GuestDisk.PartitionStyle -eq 'GPT') {
        if ($dataPartitions.Count -eq 0) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) is already GPT-initialized but has no data partition -- an ambiguous partial-completion state; stopping for manual review rather than resuming automatically." }
        }
        if ($dataPartitions.Count -gt 1) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) has $($dataPartitions.Count) non-reserved partitions; the expected single-data-partition layout was not found, refusing to proceed." }
        }

        $dataPartition = $dataPartitions[0]

        if ($dataPartition.Type -and @('Basic', 'IFS') -notcontains $dataPartition.Type) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition has unexpected partition type '$($dataPartition.Type)'; refusing to proceed." }
        }
        if ([math]::Abs([int64]$dataPartition.SizeBytes - [int64]$Target.SizeBytes) -gt 67108864) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition size ($($dataPartition.SizeBytes) bytes) does not match the expected disk capacity ($($Target.SizeBytes) bytes); undersized or oversized layout." }
        }
        $expectedAccessPath = "$($Target.DriveLetter):\"
        $unexpectedAccessPaths = @($dataPartition.AccessPaths | Where-Object { $_ -and $_ -ne $expectedAccessPath })
        if ($unexpectedAccessPaths.Count -gt 0) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition has unexpected mount path(s): $($unexpectedAccessPaths -join ', ')." }
        }

        if (-not $Volume) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) has a data partition but no formatted volume -- an ambiguous partial-completion state; stopping for manual review." }
        }

        $currentDriveLetter = if ($dataPartition.DriveLetter) { [string]$dataPartition.DriveLetter } else { '' }
        $matchesIntendedLayout = (
            $currentDriveLetter.ToUpperInvariant() -eq $Target.DriveLetter -and
            $Volume.FileSystem -eq 'NTFS' -and
            $Volume.FileSystemLabel -eq $Target.FileSystemLabel -and
            [int64]$Volume.AllocationUnitSize -eq [int64]$Target.AllocationUnitBytes
        )
        if ($matchesIntendedLayout) {
            return [pscustomobject]@{ Action = 'NoOp'; Reason = $null }
        }
        return [pscustomobject]@{
            Action = 'Fail'
            Reason = ("Disk $($Target.DiskNumber) is already initialized/formatted but does not match the intended layout " +
                "(letter='$currentDriveLetter', fileSystem='$($Volume.FileSystem)', label='$($Volume.FileSystemLabel)', allocationUnitSize=$($Volume.AllocationUnitSize)); " +
                'refusing to repair or reformat automatically.')
        }
    }

    return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) has unexpected PartitionStyle '$($GuestDisk.PartitionStyle)'; refusing to proceed." }
}

function Get-DvdPreparationPlan {
    <#
        SQL-only DVD-ROM letter-move decision: Move, AlreadyCorrect/
        NoneRequired (nothing to do), or Fail. Never mutates anything. See
        the module .DESCRIPTION, point 6, for the full decision rules.
    #>
    param(
        # Legitimately '' for App -- see Test-TargetIdentityMatchesAllowlist's
        # DvdLetterMoveTarget parameter comment above for why AllowEmptyString
        # is required here.
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DvdLetterMoveTarget,
        [Parameter(Mandatory = $false)] $EVolumeOrNull,
        [Parameter(Mandatory = $false)] $ZVolumeOrNull,
        [Parameter(Mandatory = $true)] [string] $EDataDiskPlanAction
    )

    if ([string]::IsNullOrWhiteSpace($DvdLetterMoveTarget)) {
        return [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null }
    }

    # If the approved E: target already matches its intended layout exactly
    # (NoOp), E: already belongs to the correctly prepared SQL DATA volume --
    # never attempt a DVD move, and never fail merely because E: is not a
    # DVD-ROM in that case.
    if ($EDataDiskPlanAction -eq 'NoOp') {
        return [pscustomobject]@{ Action = 'AlreadyCorrect'; Reason = $null }
    }

    if (-not $EVolumeOrNull) {
        return [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null }
    }

    # Win32_Volume.DriveType 5 == CD-ROM.
    if ([int]$EVolumeOrNull.DriveType -ne 5) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "E: is occupied by a non-DVD-ROM volume (DriveType=$($EVolumeOrNull.DriveType)) and the approved SQL DATA disk at E: is not yet correctly prepared; refusing to proceed." }
    }

    if ($EVolumeOrNull.Label -and $EVolumeOrNull.Label.Trim().Length -gt 0) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "E: is a DVD-ROM volume with a non-empty label ('$($EVolumeOrNull.Label)'), suggesting loaded media; refusing to move it." }
    }

    if ($ZVolumeOrNull) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Target drive letter ${DvdLetterMoveTarget}: is already in use; refusing to move the DVD-ROM there." }
    }

    return [pscustomobject]@{ Action = 'Move'; Reason = $null }
}

function Get-GuestDiskPreparationPlan {
    <#
        Builds one complete, read-only plan: allowlist/identity verification
        (caller params AND IMDS, each independently), OS/temporary disk
        exclusion, per-approved-disk resolution + preparation plan, a
        whole-guest drive-letter conflict preflight, and (SQL only) the
        DVD-ROM letter-move plan. Never calls a mutating adapter. Used
        identically for -Mode Validate and as the mandatory, fresh,
        immediately-pre-mutation re-validation inside -Mode Apply.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $ExpectedComputerName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $ExpectedDisks,
        # Legitimately '' for App -- see Test-TargetIdentityMatchesAllowlist's
        # DvdLetterMoveTarget parameter comment above.
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DvdLetterMoveTarget,
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ActualComputerName,
        # All four inventories legitimately empty on a freshly provisioned
        # guest (e.g. zero partitions/volumes before any disk is prepared,
        # or no DVD-ROM device attached at all) -- AllowEmptyCollection
        # prevents those valid states from throwing a raw
        # ParameterBindingValidationException instead of flowing through
        # this function's own decision logic.
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDiskInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestPartitionInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestVolumeInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDvdVolumeInventory
    )

    $blockingErrors = @()
    $dvdPlan = [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null }

    $allowlist = Get-ApprovedDiskPreparationAllowlist
    if (-not $allowlist.ContainsKey($Target)) {
        return [pscustomobject]@{ Target = $Target; Blocked = $true; Errors = @("Unknown target '$Target'."); DiskPlans = @(); DvdPlan = $dvdPlan }
    }
    $allowlistEntry = $allowlist[$Target]

    $allowlistAgreementError = Test-TargetIdentityMatchesAllowlist -Target $Target `
        -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
        -ExpectedVmName $ExpectedVmName -ExpectedComputerName $ExpectedComputerName `
        -ExpectedDisks $ExpectedDisks -DvdLetterMoveTarget $DvdLetterMoveTarget -ImdsCompute $ImdsCompute
    if ($allowlistAgreementError) { $blockingErrors += $allowlistAgreementError }

    if ($ActualComputerName -ne $allowlistEntry.ComputerName) {
        $blockingErrors += "Actual Windows computer name '$ActualComputerName' does not match the fixed allowlist for target '$Target' ('$($allowlistEntry.ComputerName)')."
    }

    if ($blockingErrors.Count -gt 0) {
        # Identity could not be established -- do not attempt disk
        # correlation at all.
        return [pscustomobject]@{ Target = $Target; Blocked = $true; Errors = $blockingErrors; DiskPlans = @(); DvdPlan = $dvdPlan }
    }

    $candidateResult = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $GuestDiskInventory
    if ($candidateResult.Error) {
        $blockingErrors += $candidateResult.Error
        return [pscustomobject]@{ Target = $Target; Blocked = $true; Errors = $blockingErrors; DiskPlans = @(); DvdPlan = $dvdPlan }
    }

    $imdsDataDisks = @()
    if ($ImdsCompute.storageProfile -and $ImdsCompute.storageProfile.dataDisks) {
        $imdsDataDisks = @($ImdsCompute.storageProfile.dataDisks)
    }
    $imdsLunGroups = @($imdsDataDisks | Group-Object { [int]$_.lun })
    foreach ($g in $imdsLunGroups) {
        if ($g.Count -gt 1) { $blockingErrors += "IMDS reports more than one data disk at LUN $($g.Name); cannot establish an unambiguous mapping." }
    }

    $resolvedTargets = @()
    $diskPlans = @()
    if ($blockingErrors.Count -eq 0) {
        foreach ($expectedDisk in $ExpectedDisks) {
            $resolution = Resolve-ApprovedDiskTarget -ExpectedDisk $expectedDisk -ImdsDataDisks $imdsDataDisks `
                -CandidateGuestDisks $candidateResult.Candidates `
                -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName
            if ($resolution.Error) {
                $blockingErrors += $resolution.Error
            }
            else {
                $resolvedTargets += $resolution.Target
            }
        }
    }

    if ($blockingErrors.Count -eq 0) {
        $dupDiskNumbers = @($resolvedTargets | Group-Object DiskNumber | Where-Object { $_.Count -gt 1 })
        if ($dupDiskNumbers.Count -gt 0) { $blockingErrors += 'More than one approved disk descriptor resolved to the same Windows disk number; refusing to proceed.' }
        $dupLetters = @($resolvedTargets | Group-Object DriveLetter | Where-Object { $_.Count -gt 1 })
        if ($dupLetters.Count -gt 0) { $blockingErrors += 'More than one approved disk descriptor requests the same drive letter; refusing to proceed.' }
    }

    # Whole-guest drive-letter conflict preflight -- any existing partition
    # on ANY disk (not just approved ones) already holding an approved
    # target's drive letter on a DIFFERENT disk is a conflict.
    # NOTE: the per-disk loop variable below is deliberately named
    # $resolvedTarget, never $target -- PowerShell variables are
    # case-insensitive, so a loop variable named $target would be the SAME
    # variable slot as this function's own typed [string] $Target
    # parameter. Assigning a pscustomobject to that slot would silently
    # coerce it to a string (via .ToString()) instead of erroring, which
    # would then make every $resolvedTarget.DiskNumber/.DriveLetter/etc.
    # access below fail with a confusing PropertyNotFoundException. This
    # was caught by actually running these tests under Windows PowerShell
    # 5.1 locally, not by static review.
    if ($blockingErrors.Count -eq 0) {
        foreach ($resolvedTarget in $resolvedTargets) {
            $conflict = @($GuestPartitionInventory | Where-Object {
                    $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq $resolvedTarget.DriveLetter -and $_.DiskNumber -ne $resolvedTarget.DiskNumber
                })
            if ($conflict.Count -gt 0) {
                $blockingErrors += "Drive letter $($resolvedTarget.DriveLetter): is already in use by a disk other than the approved target (Windows disk $($resolvedTarget.DiskNumber))."
            }
        }
    }

    if ($blockingErrors.Count -eq 0) {
        foreach ($resolvedTarget in $resolvedTargets) {
            $guestDisk = $GuestDiskInventory | Where-Object { $_.Number -eq $resolvedTarget.DiskNumber } | Select-Object -First 1
            $partitions = @($GuestPartitionInventory | Where-Object { $_.DiskNumber -eq $resolvedTarget.DiskNumber })
            $dataPartitions = @($partitions | Where-Object { -not (Test-IsMsrPartition $_) })
            $volume = $null
            if ($dataPartitions.Count -eq 1 -and $dataPartitions[0].DriveLetter) {
                $letter = $dataPartitions[0].DriveLetter.ToUpperInvariant()
                $volume = $GuestVolumeInventory | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq $letter } | Select-Object -First 1
            }
            $plan = Get-DiskPreparationPlan -Target $resolvedTarget -GuestDisk $guestDisk -Partitions $partitions -Volume $volume
            $diskPlans += [pscustomobject]@{ Target = $resolvedTarget; Plan = $plan }
            if ($plan.Action -eq 'Fail') { $blockingErrors += $plan.Reason }
        }
    }

    # SQL-only DVD-ROM plan (APP's DvdLetterMoveTarget is always empty).
    $eDataDiskPlanAction = 'NotApplicable'
    $ePlanEntry = $diskPlans | Where-Object { $_.Target.DriveLetter -eq 'E' } | Select-Object -First 1
    if ($ePlanEntry) { $eDataDiskPlanAction = $ePlanEntry.Plan.Action }
    $eVolume = $GuestDvdVolumeInventory | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq 'E:' } | Select-Object -First 1
    # The destination letter can legitimately be occupied by an ORDINARY
    # (non-DVD) volume too -- e.g. some other disk already using Z:. The
    # DVD-ROM inventory adapter only enumerates optical devices, so it alone
    # would miss that case and let a destination-conflict move proceed.
    # Check the DVD inventory first (for a descriptive "already a DVD at
    # Z:" case) and fall back to the ordinary volume inventory for any
    # other occupant.
    $zVolume = $GuestDvdVolumeInventory | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq 'Z:' } | Select-Object -First 1
    if (-not $zVolume) {
        # Get-Volume's DriveLetter is a bare letter with no trailing colon
        # (unlike the Win32_Volume-backed DVD inventory above, which always
        # includes it) -- compare against the bare form here.
        $zVolume = $GuestVolumeInventory | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq 'Z' } | Select-Object -First 1
    }
    $dvdPlan = Get-DvdPreparationPlan -DvdLetterMoveTarget $DvdLetterMoveTarget -EVolumeOrNull $eVolume -ZVolumeOrNull $zVolume -EDataDiskPlanAction $eDataDiskPlanAction
    if ($dvdPlan.Action -eq 'Fail') { $blockingErrors += $dvdPlan.Reason }

    return [pscustomobject]@{
        Target    = $Target
        Blocked   = ($blockingErrors.Count -gt 0)
        Errors    = $blockingErrors
        DiskPlans = $diskPlans
        DvdPlan   = $dvdPlan
    }
}

# =============================================================================
# INVENTORY ADAPTERS -- the only functions that call real Windows cmdlets to
# READ guest/Azure state. Each fetches its FULL inventory exactly once per
# plan build; all later filtering happens in memory in the decision functions
# above, so a genuine query failure here always propagates as a hard failure
# instead of being reinterpreted downstream as "no partitions" or "free
# letter". Pester mocks these functions directly; they never need to exist as
# real cmdlets on the test platform.
# =============================================================================

function Test-CurrentIdentityIsAdministratorOrSystemAdapter {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.User -and $identity.User.Value -eq 'S-1-5-18'
    $isAdministrator = ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
    return [bool]($isSystem -or $isAdministrator)
}

function Get-CurrentIdentityNameAdapter {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-ActualComputerNameAdapter {
    return $env:COMPUTERNAME
}

function Get-ImdsComputeMetadataAdapter {
    <#
        Windows PowerShell 5.1 compatible IMDS query. -NoProxy on
        Invoke-RestMethod requires PowerShell 6+ and is unavailable in
        Windows PowerShell 5.1 -- the runtime Run Command actually uses on
        Windows by default. This uses the documented PowerShell 5-compatible
        proxy-bypass technique instead (an empty System.Net.WebProxy bound
        to a WebRequestSession), taken from Microsoft's own IMDS sample
        repository and troubleshooting guidance:
        https://github.com/Microsoft/azureimds/blob/master/IMDSSample.ps1
        https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/activation-watermark-appears
        ("PowerShell 5 and earlier versions").
    #>
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json'
    try {
        $proxy = New-Object System.Net.WebProxy
        $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $webSession.Proxy = $proxy
        return Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -WebSession $webSession -TimeoutSec 15
    }
    catch {
        Assert-GuestDiskPreparationFailure "Unable to query the Azure Instance Metadata Service (IMDS): $($_.Exception.Message)"
    }
}

function Get-GuestDiskInventoryAdapter {
    <#
        Merges Get-Disk (Windows Storage module: IsBoot/IsSystem/
        PartitionStyle/Size/UniqueId -- https://learn.microsoft.com/en-us/powershell/module/storage/get-disk)
        with Win32_DiskDrive (SCSI addressing: SCSIBus/SCSIPort/
        SCSITargetId/SCSILogicalUnit --
        https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive)
        into one plain-object inventory, fetched in full exactly once.
    #>
    $disks = @(Get-Disk)
    $diskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive)
    $diskDrivesByIndex = @{}
    foreach ($dd in $diskDrives) { $diskDrivesByIndex[[int]$dd.Index] = $dd }

    $result = @()
    foreach ($disk in $disks) {
        $dd = $diskDrivesByIndex[[int]$disk.Number]
        $result += [pscustomobject]@{
            Number          = [int]$disk.Number
            UniqueId        = [string]$disk.UniqueId
            IsBoot          = [bool]$disk.IsBoot
            IsSystem        = [bool]$disk.IsSystem
            PartitionStyle  = [string]$disk.PartitionStyle
            SizeBytes       = [int64]$disk.Size
            ScsiBus         = if ($dd) { [int]$dd.SCSIBus } else { -1 }
            ScsiPort        = if ($dd) { [int]$dd.SCSIPort } else { -1 }
            ScsiTargetId    = if ($dd) { [int]$dd.SCSITargetId } else { -1 }
            ScsiLogicalUnit = if ($dd) { [int]$dd.SCSILogicalUnit } else { -1 }
            FriendlyName    = [string]$disk.FriendlyName
        }
    }
    return $result
}

function Get-GuestPartitionInventoryAdapter {
    $partitions = @(Get-Partition)
    return @($partitions | ForEach-Object {
            [pscustomobject]@{
                DiskNumber      = [int]$_.DiskNumber
                PartitionNumber = [int]$_.PartitionNumber
                DriveLetter     = if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }
                GptType         = if ($_.GptType) { [string]$_.GptType } else { '' }
                Type            = [string]$_.Type
                SizeBytes       = [int64]$_.Size
                AccessPaths     = @($_.AccessPaths)
            }
        })
}

function Get-GuestVolumeInventoryAdapter {
    $volumes = @(Get-Volume)
    return @($volumes | ForEach-Object {
            [pscustomobject]@{
                DriveLetter        = if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }
                FileSystem         = [string]$_.FileSystem
                FileSystemLabel    = [string]$_.FileSystemLabel
                AllocationUnitSize = [int64]$_.AllocationUnitSize
                SizeBytes          = [int64]$_.Size
            }
        })
}

function Get-GuestDvdVolumeInventoryAdapter {
    <#
        Win32_Volume (not Get-Volume) is used specifically because it is the
        only documented way to later change an optical drive's letter
        (Set-CimInstance -InputObject); fetched once, in full, for the same
        reason as the other inventory adapters.
    #>
    $volumes = @(Get-CimInstance -ClassName Win32_Volume)
    return @($volumes | ForEach-Object {
            [pscustomobject]@{
                DriveLetter = if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }
                DriveType   = [int]$_.DriveType
                Label       = [string]$_.Label
            }
        })
}

# =============================================================================
# MUTATION ADAPTERS -- the only functions in this script that change guest
# disk state. Every one operates on an explicit disk/partition number or
# object, never on a drive letter alone; none uses Clear-Disk, diskpart
# clean, or any blanket operation; none retries automatically on failure.
# =============================================================================

function Initialize-ApprovedDiskAdapter {
    param([Parameter(Mandatory = $true)] [int] $DiskNumber)
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT
}

function New-ApprovedPartitionAdapter {
    param([Parameter(Mandatory = $true)] [int] $DiskNumber, [Parameter(Mandatory = $true)] [string] $DriveLetter)
    return New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter ([char]$DriveLetter)
}

function Format-ApprovedVolumeAdapter {
    param(
        [Parameter(Mandatory = $true)] [int] $DiskNumber,
        [Parameter(Mandatory = $true)] [int] $PartitionNumber,
        [Parameter(Mandatory = $true)] [int64] $AllocationUnitBytes,
        [Parameter(Mandatory = $true)] [string] $FileSystemLabel
    )
    $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
    # -Confirm:$false only suppresses the interactive ShouldProcess prompt
    # (required for unattended Run Command execution); -Force is
    # deliberately not used -- it is not needed to format a freshly created,
    # unmounted partition and is not a flag this script relies on.
    return Format-Volume -Partition $partition -FileSystem NTFS -AllocationUnitSize $AllocationUnitBytes -NewFileSystemLabel $FileSystemLabel -Confirm:$false
}

function Move-DvdRomLetterAdapter {
    param([Parameter(Mandatory = $true)] [string] $FromLetter, [Parameter(Mandatory = $true)] [string] $ToLetter)
    $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($FromLetter):'"
    if (-not $volume) {
        Assert-GuestDiskPreparationFailure "No volume found at ${FromLetter}: immediately before the mutating move; identity changed since the immediate pre-mutation re-check."
    }
    Set-CimInstance -InputObject $volume -Property @{ DriveLetter = "${ToLetter}:" }
}

function Confirm-DvdRomLetterMoveSucceededAdapter {
    param([Parameter(Mandatory = $true)] [string] $FromLetter, [Parameter(Mandatory = $true)] [string] $ToLetter)
    $atTarget = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($ToLetter):'"
    $stillAtSource = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($FromLetter):'"
    return [bool]($atTarget -and -not $stillAtSource)
}

# =============================================================================
# ORCHESTRATION -- ties inventory adapters + decision logic + (Apply only)
# mutation adapters together. This is the only layer where plan-building and
# real I/O are combined; it is covered by Pester end-to-end tests that mock
# only the adapter functions above.
# =============================================================================

function Get-FreshGuestDiskPreparationPlan {
    <#
        Gathers every adapter's inventory fresh (no caching, no reuse across
        calls) and builds one complete plan via Get-GuestDiskPreparationPlan.
        Called at least twice per -Mode Apply invocation -- see
        Invoke-GuestDiskPreparation -- so that a previous plan is never
        treated as authorization to trust stale state.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $ExpectedComputerName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $ExpectedDisks,
        # Legitimately '' for App -- see Test-TargetIdentityMatchesAllowlist's
        # DvdLetterMoveTarget parameter comment above.
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DvdLetterMoveTarget
    )

    $imdsCompute = Get-ImdsComputeMetadataAdapter
    if ([string]::IsNullOrWhiteSpace([string]$imdsCompute.subscriptionId) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.resourceGroupName) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.name)) {
        Assert-GuestDiskPreparationFailure 'IMDS returned incomplete compute identity metadata (missing subscriptionId, resourceGroupName, or name).'
    }
    $actualComputerName = Get-ActualComputerNameAdapter
    if ([string]::IsNullOrWhiteSpace($actualComputerName)) {
        Assert-GuestDiskPreparationFailure 'Could not determine the local Windows computer name.'
    }

    # Every call below is wrapped in @(...) at the ASSIGNMENT site, not only
    # inside each adapter's own return statement. A real guest state with
    # zero partitions/volumes/DVD devices (e.g. a freshly RAW disk, or no
    # optical drive attached at all) is entirely legitimate -- but
    # PowerShell unrolls a zero-element array returned from a function onto
    # the output stream as zero objects, so an unwrapped
    # `$x = Get-SomeAdapter` assignment would silently become $null rather
    # than an empty array in exactly that legitimate case, which would then
    # fail Mandatory-but-AllowEmptyCollection binding below with a confusing
    # "because it is null" error instead of flowing through normally. This
    # was caught by actually running these tests under Windows PowerShell
    # 5.1 locally, not by static review.
    $guestDiskInventory = @(Get-GuestDiskInventoryAdapter)
    $guestPartitionInventory = @(Get-GuestPartitionInventoryAdapter)
    $guestVolumeInventory = @(Get-GuestVolumeInventoryAdapter)
    $guestDvdVolumeInventory = @(Get-GuestDvdVolumeInventoryAdapter)

    return Get-GuestDiskPreparationPlan -Target $Target `
        -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
        -ExpectedVmName $ExpectedVmName -ExpectedComputerName $ExpectedComputerName `
        -ExpectedDisks $ExpectedDisks -DvdLetterMoveTarget $DvdLetterMoveTarget `
        -ImdsCompute $imdsCompute -ActualComputerName $actualComputerName `
        -GuestDiskInventory $guestDiskInventory -GuestPartitionInventory $guestPartitionInventory `
        -GuestVolumeInventory $guestVolumeInventory -GuestDvdVolumeInventory $guestDvdVolumeInventory
}

function Write-GuestDiskPreparationReport {
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] [string] $Mode)

    Write-Output "===== Guest disk preparation report (Target=$($Plan.Target), Mode=$Mode) ====="
    if ($Plan.Blocked) {
        Write-Output 'RESULT: BLOCKED -- no mutation will be attempted.'
        foreach ($e in $Plan.Errors) { Write-Output "  ERROR: $e" }
    }
    else {
        Write-Output 'RESULT: all checks passed.'
    }
    foreach ($dp in $Plan.DiskPlans) {
        $reasonSuffix = if ($dp.Plan.Reason) { " ($($dp.Plan.Reason))" } else { '' }
        Write-Output "  LUN $($dp.Target.Lun) '$($dp.Target.DiskName)' -> Windows disk $($dp.Target.DiskNumber) (UniqueId=$($dp.Target.DiskUniqueId)): proposed action = $($dp.Plan.Action)$reasonSuffix"
    }
    $dvdReasonSuffix = if ($Plan.DvdPlan.Reason) { " ($($Plan.DvdPlan.Reason))" } else { '' }
    Write-Output "  DVD-ROM: proposed action = $($Plan.DvdPlan.Action)$dvdReasonSuffix"
    Write-Output '===== end report ====='
}

function Invoke-GuestDiskPreparation {
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('App', 'Sql')] [string] $Target,
        [Parameter(Mandatory = $true)] [ValidateSet('Validate', 'Apply')] [string] $Mode,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $ExpectedComputerName,
        [Parameter(Mandatory = $true)] [string] $ExpectedDisksJson,
        [Parameter(Mandatory = $false)] [string] $DvdLetterMoveTarget = ''
    )

    if (-not (Test-CurrentIdentityIsAdministratorOrSystemAdapter)) {
        Assert-GuestDiskPreparationFailure "This script must run as SYSTEM or an Administrator. Current identity: $(Get-CurrentIdentityNameAdapter)"
    }

    try {
        $parsedExpectedDisks = ConvertFrom-Json -InputObject $ExpectedDisksJson
    }
    catch {
        Assert-GuestDiskPreparationFailure "ExpectedDisksJson could not be parsed as JSON: $($_.Exception.Message)"
    }
    # ConvertFrom-Json writes each element of a top-level JSON array as a
    # separate pipeline object rather than a single array value -- @(...)
    # here re-collects them into one array regardless of whether the JSON
    # held one disk or several.
    $expectedDisks = @($parsedExpectedDisks)
    if ($expectedDisks.Count -eq 0) {
        Assert-GuestDiskPreparationFailure 'ExpectedDisksJson resolved to zero approved disks; refusing to proceed with nothing to validate.'
    }

    $planArgs = @{
        Target                    = $Target
        ExpectedSubscriptionId    = $ExpectedSubscriptionId
        ExpectedResourceGroupName = $ExpectedResourceGroupName
        ExpectedVmName            = $ExpectedVmName
        ExpectedComputerName      = $ExpectedComputerName
        ExpectedDisks             = $expectedDisks
        DvdLetterMoveTarget       = $DvdLetterMoveTarget
    }

    $plan = Get-FreshGuestDiskPreparationPlan @planArgs
    Write-GuestDiskPreparationReport -Plan $plan -Mode $Mode

    if ($Mode -eq 'Validate') {
        # Mutation adapters are never referenced anywhere above this point
        # in the Validate code path -- they are unreachable here by
        # construction, not merely skipped by a runtime flag.
        if ($plan.Blocked) {
            Assert-GuestDiskPreparationFailure 'Validation found one or more blocking issues; see the report above. No mutation was attempted (Validate mode never mutates).'
        }
        Write-Output 'Validate mode completed: proposed actions printed above. No mutation was performed.'
        return
    }

    # ---- -Mode Apply from here on ----
    # The plan above (and its printed report) is NEVER treated as
    # authorization to mutate by itself. The entire plan is rebuilt from
    # scratch -- fresh IMDS query, fresh guest disk/partition/volume/DVD
    # inventory -- immediately before any mutation, re-running every
    # allowlist/identity/LUN-mapping/state/partition/destination check.
    $applyPlan = Get-FreshGuestDiskPreparationPlan @planArgs
    if ($applyPlan.Blocked) {
        Write-GuestDiskPreparationReport -Plan $applyPlan -Mode $Mode
        Assert-GuestDiskPreparationFailure 'Immediate pre-mutation re-validation found one or more blocking issues; see the report above. No mutation was attempted.'
    }

    # Stable-identity confirmation: every disk resolved in the first plan
    # must still resolve to the SAME UniqueId in the fresh re-validation --
    # never continue mutating using a stale Windows disk number.
    foreach ($firstDiskPlan in $plan.DiskPlans) {
        $matching = $applyPlan.DiskPlans | Where-Object { $_.Target.Lun -eq $firstDiskPlan.Target.Lun }
        if (-not $matching -or $matching.Target.DiskUniqueId -ne $firstDiskPlan.Target.DiskUniqueId) {
            Assert-GuestDiskPreparationFailure "Stable disk identity for LUN $($firstDiskPlan.Target.Lun) changed between validation and the immediate pre-mutation re-check; refusing to proceed."
        }
    }

    # DVD move (if required) strictly before any partition creation on E:,
    # then per-disk Initialize/New-Partition/Format in LUN order. Every
    # mutating adapter call below operates on an exact disk/partition/volume
    # object or number -- never a drive letter alone, never Clear-Disk/
    # diskpart clean/forced reformatting, never retried automatically on
    # failure.
    if ($applyPlan.DvdPlan.Action -eq 'Move') {
        Write-Output "Moving the confirmed empty virtual DVD-ROM from E: to ${DvdLetterMoveTarget}:."
        Move-DvdRomLetterAdapter -FromLetter 'E' -ToLetter $DvdLetterMoveTarget
        if (-not (Confirm-DvdRomLetterMoveSucceededAdapter -FromLetter 'E' -ToLetter $DvdLetterMoveTarget)) {
            Assert-GuestDiskPreparationFailure "DVD-ROM letter move to ${DvdLetterMoveTarget}: could not be confirmed; stopping before any disk mutation."
        }
        Write-Output "Confirmed: the virtual DVD-ROM is now at ${DvdLetterMoveTarget}: and E: is free."
    }

    foreach ($diskPlan in ($applyPlan.DiskPlans | Sort-Object { $_.Target.Lun })) {
        if ($diskPlan.Plan.Action -eq 'NoOp') {
            Write-Output "Disk for LUN $($diskPlan.Target.Lun) ($($diskPlan.Target.DiskName)) already matches the intended layout -- validated, no action taken."
            continue
        }
        if ($diskPlan.Plan.Action -ne 'Initialize') {
            # Unreachable in practice: a Fail action already made $applyPlan
            # Blocked above. Kept as an explicit guard rather than assumed.
            Assert-GuestDiskPreparationFailure "Unexpected plan action '$($diskPlan.Plan.Action)' for LUN $($diskPlan.Target.Lun); stopping."
        }

        # Deliberately $diskTarget, never $target -- see the matching
        # comment in Get-GuestDiskPreparationPlan: this function also has
        # its own typed [string] $Target parameter (-ValidateSet('App','Sql')),
        # and a same-named loop/assignment variable would silently coerce
        # this pscustomobject into that string slot instead of erroring.
        $diskTarget = $diskPlan.Target
        Write-Output "Disk $($diskTarget.DiskNumber) (LUN $($diskTarget.Lun), $($diskTarget.DiskName)) is RAW with no partitions -- initializing."
        Initialize-ApprovedDiskAdapter -DiskNumber $diskTarget.DiskNumber

        $partitionsAfterInit = @(Get-GuestPartitionInventoryAdapter | Where-Object { $_.DiskNumber -eq $diskTarget.DiskNumber })
        $unexpectedAfterInit = @($partitionsAfterInit | Where-Object { -not (Test-IsMsrPartition $_) })
        if ($unexpectedAfterInit.Count -gt 0) {
            Assert-GuestDiskPreparationFailure "Disk $($diskTarget.DiskNumber) shows unexpected partition(s) immediately after GPT initialization; stopping for manual review rather than proceeding."
        }

        $newPartition = New-ApprovedPartitionAdapter -DiskNumber $diskTarget.DiskNumber -DriveLetter $diskTarget.DriveLetter
        $null = Format-ApprovedVolumeAdapter -DiskNumber $diskTarget.DiskNumber -PartitionNumber $newPartition.PartitionNumber `
            -AllocationUnitBytes $diskTarget.AllocationUnitBytes -FileSystemLabel $diskTarget.FileSystemLabel

        Write-Output "Disk $($diskTarget.DiskNumber) initialized, partitioned, and formatted as $($diskTarget.DriveLetter): ('$($diskTarget.FileSystemLabel)')."
    }

    Write-Output 'Apply mode completed successfully.'
}

# ---- Top-level invocation guard ----
# Set LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY=1 before dot-sourcing this file
# (e.g. from a Pester test) to load every function above without executing
# Invoke-GuestDiskPreparation, so mutation adapters can be safely mocked and
# asserted against instead of ever running on a real local disk.
if ($env:LIMS_GUEST_DISK_PREP_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-GuestDiskPreparation -Target $Target -Mode $Mode `
            -ExpectedSubscriptionId $ExpectedSubscriptionId `
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

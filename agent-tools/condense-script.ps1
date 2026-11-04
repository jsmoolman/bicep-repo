# Splices condensed comment replacements into Initialize-LimsGuestDataDisks.ps1
# to bring it under the project's 100,000-character budget while preserving
# every executable token. Full original prose moved to
# Initialize-LimsGuestDataDisks.research.md. Run, then verify with
# compare-tokens.ps1.

$path = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'

$replacements = @(
    @{
        StartLine = 1
        EndLine   = 344
        NewText   = @'
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

    SAFETY MODEL SUMMARY -- full rationale, real-world evidence, and
    Microsoft documentation citations for every point below are kept in
    Initialize-LimsGuestDataDisks.research.md (co-located with this script)
    and docs/operations.md, not in this file, to stay well under Bicep's
    loadTextContent() size limit:

    1) Independent fixed allowlist (Get-ApprovedDiskPreparationAllowlist).
       Caller-supplied parameters AND the live IMDS response must EACH
       independently match the fixed, hardcoded allowlist for -Target --
       the two of them merely agreeing with each other is never
       sufficient.
    2) OS and temporary-disk exclusion before resolving data disks
       (Select-NonOsNonTemporaryDiskCandidates). The OS disk is excluded
       via Get-Disk's own IsBoot/IsSystem flags. The Azure temporary
       (resource) disk is not a managed disk and never appears in IMDS's
       data-disk list, so it is excluded by cross-referencing IMDS's own
       reported temporary-disk size against each candidate's guest-
       reported size -- never a guest-only SCSI/topology guess, and any
       ambiguity is a hard failure. Remaining candidates are then
       correlated to an approved Azure LUN via
       Win32_DiskDrive.SCSILogicalUnit, with capacity checked via a small,
       fixed, one-sided tolerance (Test-ManagedDiskCapacityWithinTolerance)
       -- size is corroborating evidence only, never the sole identifier.
    2a) Customer-attested guest-disk-UniqueId binding -- ENABLED for both
       real targets (Test-AttestedGuestUniqueIdBindingConfiguration,
       Resolve-ApprovedDiskTarget -AttestedGuestUniqueId). Every disk for
       App and Sql now carries a reviewed, customer-supplied
       Get-Disk.UniqueId, which disambiguates each approved LUN without
       depending on temporary-disk exclusion. This is ADDITIONAL
       verification only -- every check in point 2 still applies
       unchanged, and a UniqueId is never treated as cryptographic or
       platform-asserted proof of the Azure resource relationship. A
       mixed or duplicate configuration is a hard failure, never a silent
       fallback.
    3) Guest disk and partition state is fully validated, never
       auto-corrected. Offline/read-only/non-'Online' disks, foreign or
       missing volume-GUID correlation, conflicting drive letters, and
       any partition type other than the exact GPT Basic Data type each
       block the whole VM's plan; this script never mutates these states
       itself.
    4) Stable identity capture and re-validation at every granularity.
       -Mode Apply rebuilds the entire plan from scratch (fresh IMDS
       query, fresh guest inventory) immediately before any mutation, and
       independently re-resolves and re-asserts each disk's exact
       expected shape again immediately before each individual mutating
       call (Initialize-Disk / New-Partition / Format-Volume / the DVD
       move). Nothing is ever retried automatically, and no step that
       already succeeded earlier in this invocation is ever rolled back
       because a later step failed.
    5) Complete, non-mutating preflight before any mutation on either
       target disk of a VM. If any approved disk on a VM fails
       validation, the entire VM's plan is Blocked and ZERO mutations are
       attempted against ANY disk on that VM.
    6) RAW alone is never sufficient to initialize a disk -- it is only
       one of several required preconditions. A disk already carrying the
       exact intended layout is validated and left completely untouched,
       even if it already holds files. Clear-Disk, diskpart clean,
       partition deletion, and any blanket/wildcard disk-state change are
       never used anywhere in this script.
    7) SQL-only, conditional DVD-ROM letter move (E: -> the fixed
       allowlist's DvdLetterMoveTarget, 'Z'), positively verified via a
       dedicated Win32_CDROMDrive identity and media-state check before
       ever planning a move, and re-verified immediately before the
       mutating call. The APP VM's DvdLetterMoveTarget is always empty,
       so its DVD-ROM is never touched.
    8) This script never touches pagefile configuration, the Azure
       temporary disk itself, SQL TempDB/configuration/folders/
       permissions/shares, or application content.

    TESTABILITY. Decision/planning logic operates exclusively on plain
    data objects and never calls a real cmdlet -- it is fully
    unit-testable on any OS/PowerShell version, including Pester on
    Ubuntu CI with no Windows Storage/CIM APIs available. All interaction
    with real cmdlets is isolated in small "*Adapter" functions; Pester
    mocks only those, never the decision/planning functions themselves.
    See Initialize-LimsGuestDataDisks.Tests.ps1.

    EXECUTION RUNTIME. Managed Run Command on Windows executes scripts
    under Windows PowerShell 5.1 by default; this script deliberately
    targets 5.1 syntax (e.g. no -NoProxy, no PowerShell 7 request) and
    requires administrator or SYSTEM execution, which it independently
    verifies rather than relying solely on Run Command's own default.

.PARAMETER Target
    Which fixed allowlist entry this invocation is for: 'App' or 'Sql'.
    Mandatory, with no default -- an invocation that omits -Target is
    rejected by PowerShell parameter binding itself before any other check
    runs, rather than silently defaulting to one target or attempting both.

.PARAMETER Mode
    'Validate' (read-only: builds and prints the full plan, never calls a
    mutating adapter -- mutation functions are unreachable from this code
    path) or 'Apply' (rebuilds the plan fresh immediately before mutating,
    then executes exactly the actions that plan approved, re-verifying
    identity and shape again immediately before each individual mutating
    call). Mandatory, with no default.

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
'@
    },
    @{
        StartLine = 378
        EndLine   = 385
        NewText   = @'
# GPT partition-type GUID for a Microsoft Reserved (MSR) partition --
# the one, documented, Windows-generated partition type tolerated
# alongside the single intended data partition. See
# Initialize-LimsGuestDataDisks.research.md ("GPT partition-type and
# volume-GUID-path constants") for the exact Microsoft documentation
# citations.
'@
    },
    @{
        StartLine = 388
        EndLine   = 397
        NewText   = @'
# GPT partition-type GUID for a Basic Data Partition -- the EXACT type
# checked for the single approved data partition on each disk, never
# Get-Partition's friendly `Type` string. See
# Initialize-LimsGuestDataDisks.research.md ("GPT partition-type and
# volume-GUID-path constants") for the exact Microsoft documentation
# citations.
'@
    },
    @{
        StartLine = 400
        EndLine   = 407
        NewText   = @'
# A volume GUID path, as documented in "Naming a Volume" -- used to
# recognize this single, specific, documented access-path shape among a
# partition's AccessPaths. See Initialize-LimsGuestDataDisks.research.md
# ("GPT partition-type and volume-GUID-path constants") for the exact
# Microsoft documentation citation.
'@
    },
    @{
        StartLine = 430
        EndLine   = 467
        NewText   = @'
    <#
        Extracts IMDS's own reported temporary (resource) disk size, in
        bytes, from a compute metadata object -- or $null if IMDS did not
        report it at all (0 is IMDS's own documented "no local temp disk
        for this VM size" value, distinct from "not reported").

        An observed, currently unresolved discrepancy between this value
        and the real guest-observed temporary disk on the two real LIMS
        WS2025 DEV v2 VMs -- with exact byte-count evidence and Microsoft
        documentation citations -- is recorded in
        Initialize-LimsGuestDataDisks.research.md under this function's
        own heading. Do not "fix" the x1024 conversion below by guessing a
        different unit -- IMDS documents only kB.
    #>
'@
    },
    @{
        StartLine = 477
        EndLine   = 506
        NewText   = @'
# The managed-disk capacity tolerance below is a deliberately
# conservative, FIXED, application-level policy calibrated against real
# ppm-level byte-count evidence from the two named v2 VMs (not a
# Microsoft-published tolerance value), applied ONE-SIDED (rejecting any
# guest-reported capacity greater than nominal). Size remains
# corroborating evidence only, never the sole identifier. See
# Initialize-LimsGuestDataDisks.research.md ("Managed-disk capacity
# tolerance") for the exact byte-count evidence and calibration
# arithmetic.
'@
    },
    @{
        StartLine = 531
        EndLine   = 587
        NewText   = @'
    <#
        Independent, fixed, hardcoded allowlist -- the single source of
        truth for exactly which subscription/resource-group/VM/computer/
        disk/LUN/size/drive-letter/label/allocation-unit combination may
        ever be touched. See the module .DESCRIPTION above: caller
        parameters and IMDS must EACH independently match this allowlist.

        ExpectedOpticalDriveName is an OBSERVED property of these two
        specific Azure VMs' virtual DVD-ROM device (not a Microsoft-
        documented guarantee for all Azure VMs); only ever used by Sql to
        verify the device at E: before moving it, never to identify a
        disk.

        AttestedGuestUniqueId activates the customer-attested guest-disk-
        UniqueId binding mechanism (see docs/operations.md). When every
        disk for a target carries a non-empty, mutually unique value here,
        that target disambiguates each approved LUN by attested UniqueId
        instead of by excluding the temporary disk by size. This is
        ADDITIONAL verification only, layered on top of (never a
        replacement for) the exact managed-disk-resource-ID/LUN checks,
        and is never treated as cryptographic or platform-asserted proof
        of the Azure resource relationship. A disk's AttestedGuestUniqueId
        left '' keeps that target on the default, fully-automatic
        identification path.

        Full BINDING PROVENANCE (exact evidence and how/when each of the
        three populated values below was captured and reviewed) is
        recorded in Initialize-LimsGuestDataDisks.research.md under this
        function's own heading -- not independently re-queried or
        re-verified by this script at any point, and not a guarantee these
        values remain correct after any future disk replacement on either
        VM (see Test-AttestedGuestUniqueIdBindingConfiguration's own
        comment and docs/operations.md for what happens if a UniqueId
        changes: the bound disk fails to resolve and the whole target's
        plan blocks).
    #>
'@
    },
    @{
        StartLine = 604
        EndLine   = 610
        NewText   = @'
                    # Customer-attested binding (App LUN 0). See "BINDING
                    # PROVENANCE" in Get-ApprovedDiskPreparationAllowlist's
                    # own comment above and
                    # Initialize-LimsGuestDataDisks.research.md for the
                    # exact evidence.
'@
    },
    @{
        StartLine = 630
        EndLine   = 634
        NewText   = @'
                    # Customer-attested binding (Sql LUN 0 / SQL DATA). See
                    # "BINDING PROVENANCE" above and
                    # Initialize-LimsGuestDataDisks.research.md.
'@
    },
    @{
        StartLine = 644
        EndLine   = 654
        NewText   = @'
                    # Customer-attested binding (Sql LUN 1 / SQL LOG) --
                    # this LUN also numerically collides with this VM's
                    # own temporary disk; this attested UniqueId is what
                    # disambiguates the two. See "BINDING PROVENANCE"
                    # above and Initialize-LimsGuestDataDisks.research.md.
'@
    },
    @{
        StartLine = 663
        EndLine   = 686
        NewText   = @'
    <#
        Pure validation of the customer-attested guest-disk-UniqueId
        binding mechanism (see Get-ApprovedDiskPreparationAllowlist's
        AttestedGuestUniqueId comment and docs/operations.md). ADDITIONAL
        verification only, layered on top of (never a replacement for) the
        exact managed-disk-resource-ID + Azure LUN checks already
        performed in Resolve-ApprovedDiskTarget.

        Returns IsAttestedMode=$true only when EVERY disk for this target
        carries a non-empty, mutually unique, AttestedGuestUniqueId (an
        explicit, all-or-nothing-per-VM opt-in) -- the actual state for
        both real App and Sql allowlist entries (see "BINDING PROVENANCE"
        there). Returns IsAttestedMode=$false with no error when NONE do.
        Any OTHER configuration -- some but not all disks attested
        ("missing"), or the same attested UniqueId reused across more
        than one disk ("duplicate") -- is a hard configuration error that
        blocks the whole target's plan rather than silently choosing a
        mode or falling back.
    #>
'@
    },
    @{
        StartLine = 794
        EndLine   = 853
        NewText   = @'
    <#
        Excludes the OS disk (Get-Disk's own IsBoot/IsSystem flags) and the
        Azure temporary/resource disk from the candidate pool later used to
        resolve approved data-disk targets by LUN.

        The temporary/resource disk is NOT a managed disk and never
        appears in IMDS's storageProfile.dataDisks[] by LUN; it is
        positively identified here by cross-referencing IMDS's own
        reported temporary-disk size (compute.storageProfile.resourceDisk.size)
        against each remaining candidate disk's own guest-reported size
        (Get-Disk.Size) -- never a guess from guest-only topology, a drive
        letter, a label, or a disk number. A disk is only ever excluded
        when its size matches Azure's own reported temporary-disk size,
        and any ambiguity (more than one candidate matching) is a hard
        failure, never a silent pick. A previous version of this function
        instead assumed every non-OS disk sharing the OS disk's SCSI
        bus/port was temporary storage, citing an unofficial source --
        that assumption has been removed entirely.

        If IMDS does not report resourceDisk.size at all (missing, not
        merely zero), the whole plan fails closed rather than silently
        skipping the exclusion. Any non-OS disk reporting missing/invalid
        SCSI addressing is never allowed to become a data-disk candidate.

        DEFECT FIX (previously accepted a "zero matches" result as "no
        temporary disk present"): when IMDS reports a NONZERO
        resourceDisk.size, failing to find EXACTLY ONE non-OS disk whose
        size matches it is now ALSO a hard failure, never silently treated
        as "nothing to exclude". On the two real LIMS WS2025 DEV v2 VMs
        this has been observed to correctly block this path -- see
        Test-AttestedGuestUniqueIdBindingConfiguration /
        -SkipTemporaryDiskExclusion below, now enabled for both real
        targets, for the alternate path that does not depend on this
        discrepancy being resolved.

        Full rationale, Microsoft documentation citations, and the exact
        observed IMDS-discrepancy evidence are recorded in
        Initialize-LimsGuestDataDisks.research.md under this function's
        own heading and under "Get-ImdsResourceDiskSizeBytes".
    #>
'@
    },
    @{
        StartLine = 952
        EndLine   = 980
        NewText   = @'
    <#
        Resolves exactly one approved disk descriptor to a Windows disk,
        after independently validating: an unambiguous IMDS LUN match,
        managed-disk resource name/ID, capacity, an unambiguous match
        among the (already OS/temporary-excluded) candidate guest disks,
        non-boot/non-system flags, suitable operational state, and a
        captured stable UniqueId. Returns a pscustomobject with either
        .Target (resolved) or .Error (a reason string) set -- never
        throws, so callers can collect every error for the whole VM before
        deciding anything is Blocked.

        -AttestedGuestUniqueId (optional, '' by default) activates the
        customer-attested guest-disk-UniqueId binding mechanism for THIS
        disk (see Get-ApprovedDiskPreparationAllowlist's own comment and
        Test-AttestedGuestUniqueIdBindingConfiguration). When non-empty,
        the guest disk at the approved LUN must ALSO carry this exact
        UniqueId -- disambiguating cleanly even when a LUN number
        numerically collides between the real target disk and an
        unrelated disk. This is ADDITIONAL verification only -- every
        other check below still applies unchanged; a UniqueId is never,
        by itself, treated as proof of the Azure resource relationship.
    #>
'@
    },
    @{
        StartLine = 1006
        EndLine   = 1015
        NewText   = @'
    # Exact full managed-disk resource ID equality -- deliberately NOT
    # StartsWith(prefix) + EndsWith(diskName) (a prior version used that
    # combination, which could wrongly accept an ID with an intervening,
    # unexpected path segment). See Initialize-LimsGuestDataDisks.research.md
    # under this function's own heading for the exact defect example.
'@
    },
    @{
        StartLine = 1042
        EndLine   = 1050
        NewText   = @'
        # Customer-attested guest-disk-UniqueId binding mode (see this
        # function's own .DESCRIPTION/-AttestedGuestUniqueId comment
        # above): the guest LUN match AND the attested UniqueId must BOTH
        # agree on the same disk.
'@
    },
    @{
        StartLine = 1096
        EndLine   = 1106
        NewText   = @'
    <#
        Decides exactly one of: Initialize (RAW, zero partitions, suitable
        state), NoOp (GPT, already matching the intended layout exactly --
        left untouched even if it already holds files), or Fail (anything
        else: unexpected partition count/type/size/mount-path, foreign or
        missing volume-GUID correlation, conflicting drive letters,
        partial completion, mismatched NTFS layout, or an unexpected
        PartitionStyle). Never mutates anything.
    #>
'@
    },
    @{
        StartLine = 1208
        EndLine   = 1222
        NewText   = @'
    <#
        SQL-only DVD-ROM letter-move decision: Move, AlreadyCorrect/
        NoneRequired (nothing to do), or Fail. Never mutates anything. See
        the module .DESCRIPTION, point 7.

        Positive verification before ever planning a Move: an empty
        Win32_Volume label alone does NOT establish that no media is
        loaded or that the device at E: is the approved virtual DVD-ROM.
        This requires an unambiguous, positively identified
        Win32_CDROMDrive device at E: reporting the exact expected device
        Name and MediaLoaded=$false (unknown/null is never treated as
        "false"), correlated 1:1 with exactly one CD-ROM-type
        Win32_Volume at E:.
    #>
'@
    },
    @{
        StartLine = 1285
        EndLine   = 1293
        NewText   = @'
    <#
        Checks whether a candidate destination letter is already occupied,
        across EVERY relevant inventory -- optical devices, DVD volumes,
        ordinary volumes, and partitions -- so neither "another DVD is
        already there" nor "an unrelated volume/partition is already
        there" can be missed by checking only one source.
    #>
'@
    },
    @{
        StartLine = 1313
        EndLine   = 1319
        NewText   = @'
    <#
        Pure shape assertion for the IMMEDIATE pre-Initialize-Disk recheck
        (see Assert-DiskReadyForDestructiveStage): the freshly re-resolved
        disk must still be RAW, zero partitions, suitable state, and the
        approved drive letter must still be free guest-wide. Returns $null
        when ready, or a reason string when not.
    #>
'@
    },
    @{
        StartLine = 1344
        EndLine   = 1353
        NewText   = @'
    <#
        Pure shape assertion for the IMMEDIATE pre-New-Partition recheck:
        the disk must now show exactly the expected post-initialization
        state (GPT, suitable state, only the Windows-generated MSR
        partition, no data partition yet) -- this EXPECTED transition
        caused by this same invocation's own prior Initialize-Disk call is
        recognized as correct; any OTHER partition already present is
        always unexpected. Returns $null when ready, or a reason string
        when not.
    #>
'@
    },
    @{
        StartLine = 1378
        EndLine   = 1385
        NewText   = @'
    <#
        Pure shape assertion for the IMMEDIATE pre-Format-Volume recheck:
        the same disk identity must now show exactly the newly created
        data partition -- same partition number, exact Basic Data GPT
        type, matching size, and the approved drive letter -- with no
        filesystem already present. Returns $null when ready, or a reason
        string when not.
    #>
'@
    },
    @{
        StartLine = 1422
        EndLine   = 1430
        NewText   = @'
    <#
        Builds one complete, read-only plan: allowlist/identity
        verification (caller params AND IMDS, each independently),
        OS/temporary disk exclusion, per-approved-disk resolution +
        preparation plan, a whole-guest drive-letter conflict preflight,
        and (SQL only) the DVD-ROM letter-move plan. Never calls a
        mutating adapter. Used identically for -Mode Validate and as the
        mandatory, fresh, immediately-pre-mutation re-validation inside
        -Mode Apply.
    #>
'@
    },
    @{
        StartLine = 1548
        EndLine   = 1560
        NewText   = @'
    # Whole-guest drive-letter conflict preflight -- any existing partition
    # on ANY disk (not just approved ones) already holding an approved
    # target's drive letter on a DIFFERENT disk is a conflict.
    # NOTE: the per-disk loop variable below is deliberately named
    # $resolvedEntry, never $target -- this function's own typed
    # [string] $Target parameter would silently collide with a same-named
    # loop variable (PowerShell variables are case-insensitive). See
    # Initialize-LimsGuestDataDisks.research.md under this function's own
    # heading for the exact failure mode this avoids.
'@
    },
    @{
        StartLine = 1664
        EndLine   = 1679
        NewText   = @'
    <#
        Windows PowerShell 5.1 compatible IMDS query. -NoProxy on
        Invoke-RestMethod requires PowerShell 6+ and is unavailable in
        Windows PowerShell 5.1 -- the runtime Run Command actually uses on
        Windows by default. Uses the documented PowerShell 5-compatible
        proxy-bypass technique instead (an empty System.Net.WebProxy bound
        to a WebRequestSession). See
        Initialize-LimsGuestDataDisks.research.md under this function's
        own heading for the exact Microsoft documentation citations.
    #>
'@
    },
    @{
        StartLine = 1693
        EndLine   = 1701
        NewText   = @'
    <#
        Merges Get-Disk (IsBoot/IsSystem/IsOffline/IsReadOnly/
        OperationalStatus/PartitionStyle/Size/UniqueId) with
        Win32_DiskDrive (SCSI addressing: SCSIBus/SCSIPort/SCSITargetId/
        SCSILogicalUnit) into one plain-object inventory, fetched in full
        exactly once.
    #>
'@
    },
    @{
        StartLine = 1746
        EndLine   = 1752
        NewText   = @'
    <#
        Get-Volume's own `Path` property is exactly the volume's own
        canonical volume-GUID path -- used (instead of drive letter alone)
        to correlate a partition's AccessPaths to this specific volume.
    #>
'@
    },
    @{
        StartLine = 1767
        EndLine   = 1772
        NewText   = @'
    <#
        Win32_Volume (not Get-Volume) is used specifically because it is
        the only documented way to later change an optical drive's letter
        (Set-CimInstance -InputObject).
    #>
'@
    },
    @{
        StartLine = 1784
        EndLine   = 1794
        NewText   = @'
    <#
        Win32_CDROMDrive -- the documented source for an optical device's
        own stable identity (DeviceID, which survives a drive-letter move)
        and positive media-loaded state (MediaLoaded). MediaLoaded is
        deliberately left as whatever WMI reports (can be $null, i.e.
        unknown) rather than force-cast to [bool], since
        Get-DvdPreparationPlan must tell "unknown" apart from "false".
    #>
'@
    },
    @{
        StartLine = 1868
        EndLine   = 1874
        NewText   = @'
    <#
        Gathers every adapter's inventory fresh (no caching, no reuse
        across calls) and builds one complete plan via
        Get-GuestDiskPreparationPlan. Called at least twice per -Mode
        Apply invocation so that a previous plan is never treated as
        authorization to trust stale state.
    #>
'@
    },
    @{
        StartLine = 1898
        EndLine   = 1909
        NewText   = @'
    # Every call below is wrapped in @(...) at the ASSIGNMENT site, not
    # only inside each adapter's own return statement, so a legitimate
    # zero-element inventory (e.g. no optical drive attached) is never
    # silently unrolled to $null. See
    # Initialize-LimsGuestDataDisks.research.md under this function's own
    # heading for the exact failure mode this avoids.
'@
    },
    @{
        StartLine = 1948
        EndLine   = 1972
        NewText   = @'
    <#
        Immediately before Initialize-Disk / New-Partition / Format-Volume:
        re-fetches a FRESH IMDS query and FRESH guest inventory (never
        reusing the whole-VM $applyPlan snapshot) and re-resolves exactly
        the one approved disk descriptor for this disk plan, confirming
        its UniqueId/disk number have not changed, then applies a
        stage-specific pure shape assertion. Throws (via
        Assert-GuestDiskPreparationFailure) on any mismatch -- never
        retries, never rolls back a prior successful step.

        -Target is used ONLY to look up the SAME fixed allowlist entry's
        own AttestedGuestUniqueId configuration (never caller-supplied) so
        the customer-attested binding, if active, is honored consistently
        in every immediate pre-mutation re-check.
    #>
'@
    },
    @{
        StartLine = 2040
        EndLine   = 2049
        NewText   = @'
    <#
        Immediately before the mutating DVD-ROM letter move: re-fetches
        every relevant inventory fresh (never reusing the whole-VM
        $applyPlan snapshot) and re-runs the SAME positive-verification
        decision logic (Get-DvdPreparationPlan), confirming the SAME
        optical device identity, media state, and source/destination
        occupancy are still exactly as previously verified. Returns the
        re-checked plan or throws on any mismatch.
    #>
'@
    }
)

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Script does not parse cleanly before edit: $($parseErrors.Count) error(s)."
}
$allComments = $tokens | Where-Object { $_.Kind -eq 'Comment' }

$spans = @()
foreach ($r in $replacements) {
    $matching = @($allComments | Where-Object { $_.Extent.StartLineNumber -ge $r.StartLine -and $_.Extent.StartLineNumber -le $r.EndLine })
    if ($matching.Count -eq 0) {
        throw "No comment tokens found for range $($r.StartLine)-$($r.EndLine)."
    }
    $minStart = ($matching | ForEach-Object { $_.Extent.StartOffset } | Sort-Object | Select-Object -First 1)
    $maxEnd = ($matching | ForEach-Object { $_.Extent.EndOffset } | Sort-Object -Descending | Select-Object -First 1)
    if ($null -eq $minStart -or $null -eq $maxEnd) {
        throw "Could not compute offsets for range $($r.StartLine)-$($r.EndLine)."
    }
    $spans += [pscustomobject]@{
        StartLine   = $r.StartLine
        EndLine     = $r.EndLine
        StartOffset = $minStart
        EndOffset   = $maxEnd
        NewText     = $r.NewText.TrimEnd("`r", "`n")
    }
}

# Detect overlaps (shouldn't happen, but fail loudly rather than corrupt the file).
$sortedCheck = $spans | Sort-Object StartOffset
for ($i = 1; $i -lt $sortedCheck.Count; $i++) {
    if ($sortedCheck[$i].StartOffset -lt $sortedCheck[$i - 1].EndOffset) {
        throw "Overlapping replacement spans detected near line $($sortedCheck[$i].StartLine)."
    }
}

$raw = Get-Content -Raw -LiteralPath $path
# Process from the end of the file backward so earlier offsets stay valid.
$spansDescending = $spans | Sort-Object StartOffset -Descending
foreach ($s in $spansDescending) {
    $before = $raw.Substring(0, $s.StartOffset)
    $after = $raw.Substring($s.EndOffset)
    $raw = $before + $s.NewText + $after
}

if ($raw.Length -ge 136420) {
    throw "Sanity check failed: new length ($($raw.Length)) is not smaller than the original (136420). Aborting without writing."
}

$verifyErrors = $null
$verifyTokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$verifyTokens, [ref]$verifyErrors)
if ($verifyErrors.Count -gt 0) {
    Write-Output "PARSE ERRORS in new content ($($verifyErrors.Count)):"
    $verifyErrors | ForEach-Object { Write-Output "  $($_.Message) at line $($_.Extent.StartLineNumber)" }
    throw "Aborting without writing due to parse errors in the new content."
}

Set-Content -LiteralPath $path -Value $raw -NoNewline -Encoding UTF8

Write-Output "Applied $($spans.Count) replacements."
Write-Output ("Original file length: 136420 characters.")
Write-Output ("New file length: {0} characters." -f $raw.Length)

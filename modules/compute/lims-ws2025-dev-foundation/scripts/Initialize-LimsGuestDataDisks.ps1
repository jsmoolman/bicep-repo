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

    1) Independent fixed allowlist (Get-ApprovedDiskPreparationAllowlist):
       caller parameters AND live IMDS must EACH independently match it.
    2) OS/temporary-disk exclusion (Select-NonOsNonTemporaryDiskCandidates)
       via Get-Disk IsBoot/IsSystem plus an IMDS temp-disk-size
       cross-check -- never a topology guess; any ambiguity fails. Disks
       are then matched to an Azure LUN via SCSILogicalUnit, with
       capacity checked via a small, one-sided tolerance
       (Test-ManagedDiskCapacityWithinTolerance) -- never the sole
       identifier.
    2a) Customer-attested guest-disk-UniqueId binding -- ENABLED for both
       real targets. ADDITIONAL verification only; a UniqueId is never
       proof of the Azure relationship. Mixed/duplicate config fails.
    3) Guest disk/partition state is fully validated, never
       auto-corrected or mutated by this script itself.
    4) Stable UniqueId capture/re-validation at every granularity --
       -Mode Apply rebuilds the whole plan and re-asserts each disk's
       shape immediately before each mutating call. Never auto-retried
       or rolled back.
    5) Complete, non-mutating preflight -- one disk's validation failure
       blocks the entire VM's plan; zero mutations on that VM.
    6) RAW alone never suffices to initialize a disk. A disk already
       matching the intended layout is left untouched. Clear-Disk,
       diskpart clean, and wildcard disk-state changes are never used.
    7) SQL-only, conditional DVD-ROM move (E: -> Z), verified via
       Win32_CDROMDrive identity/media state before and after. App's
       DVD-ROM is never touched.
    8) Never touches pagefile, the Azure temp disk, SQL TempDB/config/
       folders/shares, or app content.

    TESTABILITY. Decision logic uses only plain data objects, never a
    real cmdlet -- testable on Pester/Ubuntu CI. Real calls are isolated
    in "*Adapter" functions, which Pester mocks.

    EXECUTION RUNTIME. Run Command on Windows executes under Windows
    PowerShell 5.1 by default; this script targets 5.1 syntax and
    independently verifies administrator/SYSTEM execution.

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

# GPT type GUID for a Microsoft Reserved (MSR) partition -- the one
# Windows-generated type tolerated alongside the data partition. See
# Initialize-LimsGuestDataDisks.research.md ("GPT partition-type and
# volume-GUID-path constants").
$script:MsrPartitionGptType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

# GPT type GUID for a Basic Data Partition -- the EXACT type checked for
# the approved data partition, never Get-Partition's friendly `Type`
# string. See Initialize-LimsGuestDataDisks.research.md.
$script:BasicDataPartitionGptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

# A documented volume GUID path shape, used to recognize this access
# path among a partition's AccessPaths. See
# Initialize-LimsGuestDataDisks.research.md.
$script:VolumeGuidPathPattern = '^\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\$'

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

function Get-ImdsResourceDiskSizeBytes {
        <#
        Extracts IMDS's own reported temporary disk size in bytes, or
        $null if not reported at all (0 is IMDS's documented "no local
        temp disk" value, distinct from "not reported"). An observed,
        unresolved discrepancy vs. the real guest-observed temp disk on
        the two real v2 VMs is recorded in
        Initialize-LimsGuestDataDisks.research.md under this heading. Do
        not "fix" the x1024 below by guessing a unit -- IMDS documents kB.
    #>
    param([Parameter(Mandatory = $true)] $ImdsCompute)

    if ($ImdsCompute.PSObject.Properties.Name -notcontains 'storageProfile' -or -not $ImdsCompute.storageProfile) { return $null }
    if ($ImdsCompute.storageProfile.PSObject.Properties.Name -notcontains 'resourceDisk' -or -not $ImdsCompute.storageProfile.resourceDisk) { return $null }
    if ($ImdsCompute.storageProfile.resourceDisk.PSObject.Properties.Name -notcontains 'size') { return $null }

    return [int64]$ImdsCompute.storageProfile.resourceDisk.size * 1024
}

# Fixed, conservative, one-sided capacity tolerance calibrated against
# real ppm-level evidence from the two named v2 VMs (not a Microsoft-
# published value). See Initialize-LimsGuestDataDisks.research.md
# ("Managed-disk capacity tolerance") for the exact evidence.
$script:ManagedDiskCapacityToleranceFraction = 0.0001

function Test-ManagedDiskCapacityWithinTolerance {
    <#
        True when ActualBytes is at most NominalBytes, and no more than
        $script:ManagedDiskCapacityToleranceFraction smaller than
        NominalBytes. See the constant's own comment above for the exact
        justification and real-evidence calibration.
    #>
    param(
        [Parameter(Mandatory = $true)] [int64] $ActualBytes,
        [Parameter(Mandatory = $true)] [int64] $NominalBytes
    )
    if ($ActualBytes -gt $NominalBytes) { return $false }
    $toleranceBytes = [int64]([math]::Floor([double]$NominalBytes * $script:ManagedDiskCapacityToleranceFraction))
    return ($NominalBytes - $ActualBytes) -le $toleranceBytes
}

# =============================================================================
# DECISION / PLANNING LOGIC -- plain data objects only, no real cmdlet calls.
# Fully unit-testable on any platform (including Pester on Ubuntu CI).
# =============================================================================

function Get-ApprovedDiskPreparationAllowlist {
        <#
        Independent, fixed, hardcoded allowlist -- single source of truth
        for which subscription/RG/VM/computer/disk/LUN/size/letter/
        label/allocation-unit combination may ever be touched; caller
        parameters and IMDS must EACH independently match it (module
        .DESCRIPTION above).

        ExpectedOpticalDriveName: an OBSERVED device name on these two
        VMs, used only by Sql to verify E: before moving it.

        AttestedGuestUniqueId activates the customer-attested binding
        (docs/operations.md) -- ADDITIONAL verification only, never a
        replacement for the resource-ID/LUN checks. Left '' keeps the
        automatic path. Full BINDING PROVENANCE is in
        Initialize-LimsGuestDataDisks.research.md under this heading.
    #>
    return @{
        App = [pscustomobject]@{
            SubscriptionId           = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            ResourceGroupName        = 'rg-compute-lims-dev-westeu'
            VmName                   = 'vm-lims-dev-v2-westeu-001'
            ComputerName             = 'lims-dev-v2-001'
            DvdLetterMoveTarget      = ''
            ExpectedOpticalDriveName = ''
            Disks                    = @(
                [pscustomobject]@{
                    Lun                   = 0
                    DiskName              = 'appdata-vm-lims-dev-v2-westeu-001'
                    SizeBytes             = [int64]128 * 1024 * 1024 * 1024
                    DriveLetter           = 'A'
                    FileSystemLabel       = 'LIMS-App'
                    AllocationUnitBytes   = 4096
                                        # Customer-attested binding (App LUN 0) -- see "BINDING PROVENANCE" above / research.md.
                    AttestedGuestUniqueId = '60022480D1B07E6ACD98417F86591F4B'
                }
            )
        }
        Sql = [pscustomobject]@{
            SubscriptionId           = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
            ResourceGroupName        = 'rg-compute-lims-dev-westeu'
            VmName                   = 'vm-lims-dev-v2-westeu-002'
            ComputerName             = 'lims-dev-v2-002'
            DvdLetterMoveTarget      = 'Z'
            ExpectedOpticalDriveName = 'Microsoft Virtual DVD-ROM'
            Disks                    = @(
                [pscustomobject]@{
                    Lun                   = 0
                    DiskName              = 'sqldata-vm-lims-dev-v2-westeu-002'
                    SizeBytes             = [int64]1024 * 1024 * 1024 * 1024
                    DriveLetter           = 'E'
                    FileSystemLabel       = 'SQL-Data'
                    AllocationUnitBytes   = 65536
                                        # Customer-attested binding (Sql LUN 0 / SQL DATA) -- see "BINDING PROVENANCE" above / research.md.
                    AttestedGuestUniqueId = '60022480FC5A2FF57B5FE802967E448E'
                }
                [pscustomobject]@{
                    Lun                   = 1
                    DiskName              = 'sqllog-vm-lims-dev-v2-westeu-002'
                    SizeBytes             = [int64]512 * 1024 * 1024 * 1024
                    DriveLetter           = 'F'
                    FileSystemLabel       = 'SQL-Logs'
                    AllocationUnitBytes   = 65536
                                        # Customer-attested binding (Sql LUN 1 / SQL LOG) -- this LUN collides numerically with the temp disk; see "BINDING PROVENANCE" above / research.md.
                    AttestedGuestUniqueId = '60022480042D640894BBE41BA513DCFC'
                }
            )
        }
    }
}

function Test-AttestedGuestUniqueIdBindingConfiguration {
        <#
        Pure validation of the customer-attested binding (docs/operations.md).
        ADDITIONAL verification only, never a replacement for
        Resolve-ApprovedDiskTarget's own checks.

        IsAttestedMode=$true only when EVERY disk carries a non-empty,
        mutually unique AttestedGuestUniqueId (all-or-nothing).
        IsAttestedMode=$false, no error, when NONE do. Any OTHER
        configuration (some but not all, or a duplicate value) is a hard
        error that blocks the whole plan.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Disks)

    $diskArray = @($Disks)
    $withAttested = @($diskArray | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.AttestedGuestUniqueId) })

    if ($withAttested.Count -eq 0) {
        return [pscustomobject]@{ IsAttestedMode = $false; Error = $null }
    }
    if ($withAttested.Count -ne $diskArray.Count) {
        return [pscustomobject]@{
            IsAttestedMode = $false
            Error          = "Inconsistent customer-attested guest UniqueId binding configuration: $($withAttested.Count) of $($diskArray.Count) approved disk(s) carry an AttestedGuestUniqueId; either all or none must be configured for a given target (missing binding)."
        }
    }
    $dupGroups = @($withAttested | Group-Object { [string]$_.AttestedGuestUniqueId } | Where-Object { $_.Count -gt 1 })
    if ($dupGroups.Count -gt 0) {
        return [pscustomobject]@{
            IsAttestedMode = $false
            Error          = 'Duplicate customer-attested guest UniqueId configured for more than one approved disk on the same target; each attested UniqueId must be unique (duplicate binding).'
        }
    }

    return [pscustomobject]@{ IsAttestedMode = $true; Error = $null }
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
        Excludes the OS disk (IsBoot/IsSystem) and the Azure temp disk
        from the candidate pool used to resolve data disks by LUN. The
        temp disk is unmanaged and absent from IMDS's data-disk list;
        identified by matching IMDS's reported temp-disk size against
        each candidate's Get-Disk.Size -- never a topology guess. Any
        ambiguity, or missing resourceDisk.size, or a nonzero size
        matching zero candidates (DEFECT FIX), fails closed -- see
        -SkipTemporaryDiskExclusion below for the attested-binding path.
        Full evidence: Initialize-LimsGuestDataDisks.research.md.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDiskInventory,
        # $null is valid here (not [int64]) -- "IMDS did not report it".
        [Parameter(Mandatory = $true)] [AllowNull()] $ImdsResourceDiskSizeBytes,
        # Customer-attested binding opt-in -- see
        # Test-AttestedGuestUniqueIdBindingConfiguration. Always $false
        # unless the caller already confirmed a valid attested binding.
        [Parameter(Mandatory = $false)] [bool] $SkipTemporaryDiskExclusion = $false
    )

    $osDisks = @($GuestDiskInventory | Where-Object { $_.IsBoot -or $_.IsSystem })
    if ($osDisks.Count -ne 1) {
        return [pscustomobject]@{
            Candidates = @()
            Error      = "Expected exactly one boot/system Windows disk, found $($osDisks.Count); refusing to proceed without an unambiguous OS disk to exclude."
        }
    }

    $nonOsDisks = @($GuestDiskInventory | Where-Object { -not ($_.IsBoot -or $_.IsSystem) })

    $invalidScsiDisks = @($nonOsDisks | Where-Object {
            [int]$_.ScsiBus -lt 0 -or [int]$_.ScsiPort -lt 0 -or [int]$_.ScsiTargetId -lt 0 -or [int]$_.ScsiLogicalUnit -lt 0
        })
    if ($invalidScsiDisks.Count -gt 0) {
        $invalidNumbers = ($invalidScsiDisks | ForEach-Object { $_.Number }) -join ', '
        return [pscustomobject]@{
            Candidates = @()
            Error      = "Windows disk(s) $invalidNumbers reported missing or invalid SCSI addressing; cannot establish an Azure LUN mapping for them, so no disk is treated as a data-disk candidate until this is understood."
        }
    }

    if ($SkipTemporaryDiskExclusion) {
        return [pscustomobject]@{
            Candidates = $nonOsDisks
            Error      = $null
        }
    }

    if ($null -eq $ImdsResourceDiskSizeBytes) {
        return [pscustomobject]@{
            Candidates = @()
            Error      = 'IMDS did not report compute.storageProfile.resourceDisk.size; cannot positively establish whether a temporary/resource disk is present to exclude it.'
        }
    }
    if ([int64]$ImdsResourceDiskSizeBytes -lt 0) {
        # A negative value is contradictory/malformed metadata, never
        # IMDS's own documented "no temp disk" value (which is exactly
        # zero -- see Get-ImdsResourceDiskSizeBytes's own comment). Must
        # be a hard failure, not silently treated as "no temporary disk
        # to exclude."
        return [pscustomobject]@{
            Candidates = @()
            Error      = "IMDS reported a negative compute.storageProfile.resourceDisk.size-derived byte count ($ImdsResourceDiskSizeBytes bytes); this is contradictory metadata, not a valid 'no temporary disk' value (which is documented as exactly zero), so no disk is treated as a safe data-disk candidate until this is understood."
        }
    }

    $temporaryDisks = @()
    if ([int64]$ImdsResourceDiskSizeBytes -gt 0) {
        # Up to 64 MiB tolerance for the usual kB/geometry rounding between
        # IMDS's reported size and Get-Disk's own figure.
        $temporaryDisks = @($nonOsDisks | Where-Object { [math]::Abs([int64]$_.SizeBytes - [int64]$ImdsResourceDiskSizeBytes) -le 67108864 })
        if ($temporaryDisks.Count -eq 0) {
            return [pscustomobject]@{
                Candidates = @()
                Error      = "IMDS reports a nonzero temporary disk size ($ImdsResourceDiskSizeBytes bytes) but no non-OS Windows disk's reported size matches it; cannot positively identify and exclude the temporary disk, so no disk is treated as a safe data-disk candidate until this is resolved (see docs/operations.md's customer-attested-binding proposal and Get-LimsGuestDiskDiagnostics.ps1 for the read-only evidence needed to review it)."
            }
        }
        if ($temporaryDisks.Count -gt 1) {
            return [pscustomobject]@{
                Candidates = @()
                Error      = "More than one non-OS Windows disk's reported size matches Azure's own reported temporary disk size ($ImdsResourceDiskSizeBytes bytes); cannot unambiguously identify the temporary disk to exclude it."
            }
        }
    }

    $candidates = @($nonOsDisks | Where-Object { $temporaryDisks -notcontains $_ })

    return [pscustomobject]@{
        Candidates = $candidates
        Error      = $null
    }
}

function Resolve-ApprovedDiskTarget {
        <#
        Resolves one approved disk descriptor to a Windows disk,
        validating: IMDS LUN match, managed-disk resource ID, capacity,
        candidate-guest-disk match, non-boot/non-system, operational
        state, and a captured UniqueId. Returns .Target or .Error --
        never throws, so callers collect every error before Blocking.

        -AttestedGuestUniqueId ('' default): when non-empty, the guest
        disk at the approved LUN must ALSO carry this exact UniqueId.
        ADDITIONAL verification only -- never by itself proof of the
        Azure relationship.
    #>
    param(
        [Parameter(Mandatory = $true)] $ExpectedDisk,
        # Legitimately empty on a misconfigured VM with fewer disks than
        # expected -- yields this function's own clean "0 found" error.
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $ImdsDataDisks,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $CandidateGuestDisks,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $AttestedGuestUniqueId = ''
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

        # Exact full managed-disk resource ID equality -- deliberately NOT
    # StartsWith(prefix) + EndsWith(diskName) (a prior version used that
    # combination, which could wrongly accept an ID with an intervening,
    # unexpected path segment). See Initialize-LimsGuestDataDisks.research.md
    # under this function's own heading for the exact defect example.
    $expectedManagedDiskId = "/subscriptions/$ExpectedSubscriptionId/resourceGroups/$ExpectedResourceGroupName/providers/Microsoft.Compute/disks/$($ExpectedDisk.DiskName)"
    $actualManagedDiskId = [string]$imdsDisk.managedDisk.id
    if ([string]::IsNullOrWhiteSpace($actualManagedDiskId) -or
        -not [string]::Equals($actualManagedDiskId, $expectedManagedDiskId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun managed-disk resource ID '$actualManagedDiskId' does not exactly match the expected resource ID '$expectedManagedDiskId'." }
    }

    $imdsSizeBytes = $null
    if ($imdsDisk.PSObject.Properties.Name -contains 'diskCapacityBytes' -and $imdsDisk.diskCapacityBytes) {
        $imdsSizeBytes = [int64]$imdsDisk.diskCapacityBytes
    }
    elseif ($imdsDisk.PSObject.Properties.Name -contains 'diskSizeGB' -and $imdsDisk.diskSizeGB) {
        $imdsSizeBytes = [int64]$imdsDisk.diskSizeGB * 1024 * 1024 * 1024
    }
    $expectedSizeBytes = [int64]$ExpectedDisk.SizeBytes
    if (-not $imdsSizeBytes -or -not (Test-ManagedDiskCapacityWithinTolerance -ActualBytes $imdsSizeBytes -NominalBytes $expectedSizeBytes)) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun capacity mismatch: IMDS reports approximately $imdsSizeBytes bytes, expected $expectedSizeBytes bytes (outside the documented, evidence-calibrated tolerance -- see Test-ManagedDiskCapacityWithinTolerance)." }
    }

    if ([string]::IsNullOrWhiteSpace($AttestedGuestUniqueId)) {
        $guestMatches = @($CandidateGuestDisks | Where-Object { [int]$_.ScsiLogicalUnit -eq $lun })
        if ($guestMatches.Count -ne 1) {
            return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolves to $($guestMatches.Count) non-OS/non-temporary Windows disk device(s) after exclusion; an unambiguous one-to-one mapping is required." }
        }
    }
    else {
                # Customer-attested guest-disk-UniqueId binding mode (see this
        # function's own .DESCRIPTION/-AttestedGuestUniqueId comment
        # above): the guest LUN match AND the attested UniqueId must BOTH
        # agree on the same disk.
        $guestMatches = @($CandidateGuestDisks | Where-Object { [int]$_.ScsiLogicalUnit -eq $lun -and [string]$_.UniqueId -eq $AttestedGuestUniqueId })
        if ($guestMatches.Count -ne 1) {
            return [pscustomobject]@{ Target = $null; Error = "LUN $lun with a customer-attested guest UniqueId configured resolves to $($guestMatches.Count) Windows disk device(s) matching both that LUN and that UniqueId; refusing to proceed without an unambiguous attested-identity match." }
        }
    }
    $guestDisk = $guestMatches[0]

    if ($guestDisk.IsBoot -or $guestDisk.IsSystem) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), which is flagged boot and/or system; refusing to proceed." }
    }
    if ($guestDisk.IsOffline) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), which is offline; refusing to proceed." }
    }
    if ($guestDisk.IsReadOnly) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), which is read-only; refusing to proceed." }
    }
    if ([string]$guestDisk.OperationalStatus -ne 'Online') {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), whose operational status is '$($guestDisk.OperationalStatus)' (expected 'Online'); refusing to proceed." }
    }
    if (-not (Test-ManagedDiskCapacityWithinTolerance -ActualBytes ([int64]$guestDisk.SizeBytes) -NominalBytes $expectedSizeBytes)) {
        return [pscustomobject]@{ Target = $null; Error = "LUN $lun resolved to Windows disk $($guestDisk.Number), whose reported size ($($guestDisk.SizeBytes) bytes) does not match the expected $expectedSizeBytes bytes (outside the documented, evidence-calibrated tolerance -- see Test-ManagedDiskCapacityWithinTolerance)." }
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
            IsOffline           = [bool]$guestDisk.IsOffline
            IsReadOnly          = [bool]$guestDisk.IsReadOnly
            OperationalStatus   = [string]$guestDisk.OperationalStatus
        }
        Error  = $null
    }
}

function Get-DiskPreparationPlan {
        <#
        Decides Initialize (RAW, zero partitions, suitable state), NoOp
        (GPT, already matching the intended layout exactly -- left
        untouched even if it already holds files), or Fail (anything
        else). Never mutates anything.
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

        # Exact GPT Basic Data Partition type -- never the friendly `Type`
        # string. https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
        $actualGptType = [string]$dataPartition.GptType
        if ([string]::IsNullOrWhiteSpace($actualGptType) -or $actualGptType.ToLowerInvariant() -ne $script:BasicDataPartitionGptType.ToLowerInvariant()) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition has unexpected GPT type '$actualGptType' (expected the Basic Data Partition type $($script:BasicDataPartitionGptType))." }
        }
        if ([math]::Abs([int64]$dataPartition.SizeBytes - [int64]$Target.SizeBytes) -gt 67108864) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition size ($($dataPartition.SizeBytes) bytes) does not match the expected disk capacity ($($Target.SizeBytes) bytes); undersized or oversized layout." }
        }

        # Mount-path shape: only the approved drive-letter root and,
        # once formatted, exactly one volume-GUID access path
        # (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume)
        # are ever accepted -- never an additional directory mount, and
        # never more than one GUID path (which would itself be ambiguous).
        $expectedAccessPath = "$($Target.DriveLetter):\"
        $accessPaths = @($dataPartition.AccessPaths)
        $driveRootPaths = @($accessPaths | Where-Object { $_ -eq $expectedAccessPath })
        $volumeGuidPaths = @($accessPaths | Where-Object { $_ -match $script:VolumeGuidPathPattern })
        $otherPaths = @($accessPaths | Where-Object { $_ -and $_ -ne $expectedAccessPath -and $_ -notmatch $script:VolumeGuidPathPattern })
        if ($otherPaths.Count -gt 0) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition has unexpected mount path(s): $($otherPaths -join ', ')." }
        }
        if ($driveRootPaths.Count -ne 1) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition does not have exactly one mount at the approved drive root ${expectedAccessPath} (found $($driveRootPaths.Count))." }
        }
        if ($volumeGuidPaths.Count -gt 1) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition reports more than one volume GUID access path; ambiguous volume association." }
        }

        if (-not $Volume) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) has a data partition but no formatted volume -- an ambiguous partial-completion state; stopping for manual review." }
        }

        # The partition's own volume-GUID access path must be exactly this
        # correlated volume's own Path (Get-Volume's Path property is
        # exactly the same GUID-path string -- this is what proves the
        # correlation is this partition's OWN verified volume, never a
        # foreign volume's GUID path, and never simply absent once
        # formatted).
        if ($volumeGuidPaths.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Volume.Path) -or $volumeGuidPaths[0] -ne [string]$Volume.Path) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition's access paths do not include this volume's own verified GUID path; refusing to proceed." }
        }

        $currentDriveLetter = if ($dataPartition.DriveLetter) { [string]$dataPartition.DriveLetter } else { '' }
        $volumeDriveLetter = if ($Volume.DriveLetter) { [string]$Volume.DriveLetter } else { '' }
        if ($volumeDriveLetter -and $currentDriveLetter -and $volumeDriveLetter.ToUpperInvariant() -ne $currentDriveLetter.ToUpperInvariant()) {
            return [pscustomobject]@{ Action = 'Fail'; Reason = "Disk $($Target.DiskNumber) data partition reports drive letter '$currentDriveLetter' but its correlated volume reports a different drive letter '$volumeDriveLetter'; conflicting letters." }
        }

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
        NoneRequired, or Fail (module .DESCRIPTION point 7). Requires an
        unambiguous Win32_CDROMDrive at E: with the exact expected Name
        and MediaLoaded=$false (unknown never treated as false),
        correlated 1:1 with one CD-ROM Win32_Volume -- a mere empty
        volume label is never sufficient.
    #>
    param(
        # Legitimately '' for App -- see Test-TargetIdentityMatchesAllowlist's
        # DvdLetterMoveTarget parameter comment above for why AllowEmptyString
        # is required here.
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DvdLetterMoveTarget,
        [Parameter(Mandatory = $true)] [string] $EDataDiskPlanAction,
        # Legitimately '' for App (its allowlist entry's ExpectedOpticalDriveName
        # is always empty, since App never touches any DVD-ROM).
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $ExpectedOpticalDriveName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $EOpticalDrives,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $EDvdVolumes,
        [Parameter(Mandatory = $true)] [bool] $DestinationOccupied
    )

    if ([string]::IsNullOrWhiteSpace($DvdLetterMoveTarget)) {
        return [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null; DeviceId = $null }
    }

    # If the approved E: target already matches its intended layout exactly
    # (NoOp), E: already belongs to the correctly prepared SQL DATA volume --
    # never attempt a DVD move, and never fail merely because E: is not a
    # DVD-ROM in that case. E: is never even inspected for DVD-ness here.
    if ($EDataDiskPlanAction -eq 'NoOp') {
        return [pscustomobject]@{ Action = 'AlreadyCorrect'; Reason = $null; DeviceId = $null }
    }

    $driveCount = @($EOpticalDrives).Count
    $volumeCount = @($EDvdVolumes).Count

    if ($driveCount -eq 0 -and $volumeCount -eq 0) {
        return [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null; DeviceId = $null }
    }
    if ($driveCount -ne 1 -or $volumeCount -ne 1) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Expected exactly one optical device and one DVD-ROM volume at E:, found $driveCount device(s) and $volumeCount volume(s); cannot unambiguously verify E: before moving it."; DeviceId = $null }
    }

    $drive = $EOpticalDrives[0]
    $volume = $EDvdVolumes[0]

    if ([string]$drive.Name -ne $ExpectedOpticalDriveName) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Optical device at E: reports name '$($drive.Name)', expected '$ExpectedOpticalDriveName'; refusing to move an unverified device."; DeviceId = [string]$drive.DeviceId }
    }
    if ($null -eq $drive.MediaLoaded) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = 'Could not determine whether media is loaded in the optical device at E: (MediaLoaded reported unknown); refusing to proceed.'; DeviceId = [string]$drive.DeviceId }
    }
    if ([bool]$drive.MediaLoaded) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = 'Optical device at E: reports media loaded; refusing to move it.'; DeviceId = [string]$drive.DeviceId }
    }
    if ([int]$volume.DriveType -ne 5) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Volume at E: is not a CD-ROM-type volume (DriveType=$($volume.DriveType))."; DeviceId = [string]$drive.DeviceId }
    }
    if ($volume.Label -and $volume.Label.Trim().Length -gt 0) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Optical device at E: reports MediaLoaded=`$false but its volume has a non-empty label ('$($volume.Label)'); inconsistent state, refusing to proceed."; DeviceId = [string]$drive.DeviceId }
    }
    if ($DestinationOccupied) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = "Target drive letter ${DvdLetterMoveTarget}: is already in use; refusing to move the DVD-ROM there."; DeviceId = [string]$drive.DeviceId }
    }

    return [pscustomobject]@{ Action = 'Move'; Reason = $null; DeviceId = [string]$drive.DeviceId }
}

function Test-DestinationLetterOccupied {
        <#
        Checks whether a candidate destination letter is already occupied,
        across EVERY relevant inventory -- optical devices, DVD volumes,
        ordinary volumes, and partitions -- so neither "another DVD is
        already there" nor "an unrelated volume/partition is already
        there" can be missed by checking only one source.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Letter,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $OpticalDrives,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $DvdVolumes,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Volumes,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions
    )

    $letterUpper = $Letter.ToUpperInvariant()

    if (@($OpticalDrives | Where-Object { $_.Drive -and $_.Drive.ToString().ToUpperInvariant() -eq "${letterUpper}:" }).Count -gt 0) { return $true }
    if (@($DvdVolumes | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq "${letterUpper}:" }).Count -gt 0) { return $true }
    if (@($Volumes | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq $letterUpper }).Count -gt 0) { return $true }
    if (@($Partitions | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq $letterUpper }).Count -gt 0) { return $true }

    return $false
}

function Test-DiskReadyForInitializeStage {
        <#
        Pure shape assertion for the IMMEDIATE pre-Initialize-Disk recheck
        (see Assert-DiskReadyForDestructiveStage): the freshly re-resolved
        disk must still be RAW, zero partitions, suitable state, and the
        approved drive letter must still be free guest-wide. Returns $null
        when ready, or a reason string when not.
    #>
    param(
        [Parameter(Mandatory = $false)] $GuestDisk,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions,
        [Parameter(Mandatory = $true)] $Target,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $AllGuestPartitions
    )

    if (-not $GuestDisk) { return "Windows disk $($Target.DiskNumber) could no longer be found." }
    if ($GuestDisk.IsBoot -or $GuestDisk.IsSystem) { return "Windows disk $($Target.DiskNumber) is now flagged boot and/or system." }
    if ($GuestDisk.IsOffline) { return "Windows disk $($Target.DiskNumber) is offline." }
    if ($GuestDisk.IsReadOnly) { return "Windows disk $($Target.DiskNumber) is read-only." }
    if ([string]$GuestDisk.OperationalStatus -ne 'Online') { return "Windows disk $($Target.DiskNumber) operational status is '$($GuestDisk.OperationalStatus)', expected 'Online'." }
    if ($GuestDisk.PartitionStyle -ne 'RAW') { return "Windows disk $($Target.DiskNumber) is no longer RAW (reports '$($GuestDisk.PartitionStyle)')." }
    if (@($Partitions).Count -gt 0) { return "Windows disk $($Target.DiskNumber) now reports $(@($Partitions).Count) partition(s); expected none immediately before initialization." }

    $conflict = @($AllGuestPartitions | Where-Object {
            $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq $Target.DriveLetter -and $_.DiskNumber -ne $Target.DiskNumber
        })
    if ($conflict.Count -gt 0) { return "Drive letter $($Target.DriveLetter): is now in use by a different Windows disk." }

    return $null
}

function Test-DiskReadyForNewPartitionStage {
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
    param(
        [Parameter(Mandatory = $false)] $GuestDisk,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions
    )

    if (-not $GuestDisk) { return 'The Windows disk could no longer be found.' }
    if ($GuestDisk.IsOffline) { return "Disk $($GuestDisk.Number) is offline." }
    if ($GuestDisk.IsReadOnly) { return "Disk $($GuestDisk.Number) is read-only." }
    if ([string]$GuestDisk.OperationalStatus -ne 'Online') { return "Disk $($GuestDisk.Number) operational status is '$($GuestDisk.OperationalStatus)', expected 'Online'." }
    if ($GuestDisk.PartitionStyle -ne 'GPT') { return "Disk $($GuestDisk.Number) is not GPT immediately after initialization (reports '$($GuestDisk.PartitionStyle)')." }

    $nonMsr = @($Partitions | Where-Object { -not (Test-IsMsrPartition $_) })
    if ($nonMsr.Count -gt 0) {
        return "Disk $($GuestDisk.Number) already has $($nonMsr.Count) non-reserved partition(s) immediately after initialization; expected only the Windows-generated MSR partition."
    }
    $msrCount = @($Partitions | Where-Object { Test-IsMsrPartition $_ }).Count
    if ($msrCount -ne 1) {
        return "Disk $($GuestDisk.Number) reports $msrCount Microsoft Reserved partition(s) immediately after initialization; expected exactly one."
    }

    return $null
}

function Test-PartitionReadyForFormatStage {
        <#
        Pure shape assertion for the IMMEDIATE pre-Format-Volume recheck:
        the same disk identity must now show exactly the newly created
        data partition -- same partition number, exact Basic Data GPT
        type, matching size, and the approved drive letter -- with no
        filesystem already present. Returns $null when ready, or a reason
        string when not.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions,
        [Parameter(Mandatory = $true)] $Target,
        [Parameter(Mandatory = $true)] [int] $NewPartitionNumber,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Volumes
    )

    $dataPartitions = @($Partitions | Where-Object { -not (Test-IsMsrPartition $_) })
    if ($dataPartitions.Count -ne 1) {
        return "Expected exactly one newly created data partition immediately before formatting, found $($dataPartitions.Count)."
    }
    $partition = $dataPartitions[0]
    if ($partition.PartitionNumber -ne $NewPartitionNumber) {
        return "The data partition's number ($($partition.PartitionNumber)) no longer matches the partition just created (#$NewPartitionNumber)."
    }
    $actualGptType = [string]$partition.GptType
    if ([string]::IsNullOrWhiteSpace($actualGptType) -or $actualGptType.ToLowerInvariant() -ne $script:BasicDataPartitionGptType.ToLowerInvariant()) {
        return "The newly created partition reports unexpected GPT type '$actualGptType' immediately before formatting."
    }
    if ([math]::Abs([int64]$partition.SizeBytes - [int64]$Target.SizeBytes) -gt 67108864) {
        return "The newly created partition's size ($($partition.SizeBytes) bytes) does not match the expected disk capacity ($($Target.SizeBytes) bytes)."
    }
    $currentLetter = if ($partition.DriveLetter) { [string]$partition.DriveLetter } else { '' }
    if ($currentLetter.ToUpperInvariant() -ne $Target.DriveLetter) {
        return "The newly created partition's drive letter ('$currentLetter') no longer matches the approved target ('$($Target.DriveLetter)')."
    }

    $existingVolume = $Volumes | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToString().ToUpperInvariant() -eq $Target.DriveLetter } | Select-Object -First 1
    if ($existingVolume -and -not [string]::IsNullOrWhiteSpace([string]$existingVolume.FileSystem)) {
        return "A filesystem ('$($existingVolume.FileSystem)') unexpectedly already appears on drive $($Target.DriveLetter): immediately before formatting; refusing to format over unexpected existing state."
    }

    return $null
}

function Get-GuestDiskPreparationPlan {
        <#
        Builds one complete, read-only plan: allowlist/identity checks,
        OS/temporary disk exclusion, per-disk resolution + preparation
        plan, a drive-letter conflict preflight, and (SQL) the DVD plan.
        Never mutates. Used for -Mode Validate and as the mandatory,
        fresh, immediately-pre-mutation re-validation inside Apply.
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
        # All inventories legitimately empty on a freshly provisioned guest
        # (e.g. zero partitions/volumes before any disk is prepared, or no
        # DVD-ROM/optical device attached at all) -- AllowEmptyCollection
        # prevents those valid states from throwing a raw
        # ParameterBindingValidationException instead of flowing through
        # this function's own decision logic.
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDiskInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestPartitionInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestVolumeInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDvdVolumeInventory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestOpticalDriveInventory
    )

    $blockingErrors = @()
    $dvdPlan = [pscustomobject]@{ Action = 'NoneRequired'; Reason = $null; DeviceId = $null }

    $allowlist = Get-ApprovedDiskPreparationAllowlist
    if (-not $allowlist.ContainsKey($Target)) {
        return [pscustomobject]@{ Target = $Target; Blocked = $true; Errors = @("Unknown target '$Target'."); DiskPlans = @(); DvdPlan = $dvdPlan }
    }
    $allowlistEntry = $allowlist[$Target]

    # Validate the OPTIONAL, disabled-by-default customer-attested
    # guest-disk-UniqueId binding configuration for this target BEFORE any
    # guest/IMDS query -- an inconsistent (mixed or duplicate) hardcoded
    # allowlist configuration is a static defect in the allowlist itself,
    # independent of any caller/guest state, and blocks exactly like any
    # other allowlist-agreement failure.
    $attestedBindingConfig = Test-AttestedGuestUniqueIdBindingConfiguration -Disks $allowlistEntry.Disks
    if ($attestedBindingConfig.Error) {
        return [pscustomobject]@{ Target = $Target; Blocked = $true; Errors = @($attestedBindingConfig.Error); DiskPlans = @(); DvdPlan = $dvdPlan }
    }

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

    $imdsResourceDiskSizeBytes = Get-ImdsResourceDiskSizeBytes -ImdsCompute $ImdsCompute
    $candidateResult = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $GuestDiskInventory `
        -ImdsResourceDiskSizeBytes $imdsResourceDiskSizeBytes -SkipTemporaryDiskExclusion $attestedBindingConfig.IsAttestedMode
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

    # Each resolved entry pairs the resolved Target with its own original
    # ExpectedDisk descriptor, so the exact approved descriptor can be
    # re-resolved fresh, independently, immediately before each destructive
    # step later (see Assert-DiskReadyForDestructiveStage) -- never reusing
    # this snapshot's own resolution as authorization.
    $resolvedEntries = @()
    $diskPlans = @()
    if ($blockingErrors.Count -eq 0) {
        foreach ($expectedDisk in $ExpectedDisks) {
            # Looked up from the fixed ALLOWLIST's own Disks (never from
            # caller-supplied $ExpectedDisks, which carries no
            # AttestedGuestUniqueId field at all by design) -- the
            # attested binding is a deliberate, hardcoded, reviewed
            # code-level opt-in, never something a caller/Bicep parameter
            # can supply or influence.
            $allowlistDiskForLun = $allowlistEntry.Disks | Where-Object { [int]$_.Lun -eq [int]$expectedDisk.Lun } | Select-Object -First 1
            $attestedGuestUniqueId = ''
            if ($allowlistDiskForLun) { $attestedGuestUniqueId = [string]$allowlistDiskForLun.AttestedGuestUniqueId }

            $resolution = Resolve-ApprovedDiskTarget -ExpectedDisk $expectedDisk -ImdsDataDisks $imdsDataDisks `
                -CandidateGuestDisks $candidateResult.Candidates `
                -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
                -AttestedGuestUniqueId $attestedGuestUniqueId
            if ($resolution.Error) {
                $blockingErrors += $resolution.Error
            }
            else {
                $resolvedEntries += [pscustomobject]@{ Target = $resolution.Target; ExpectedDisk = $expectedDisk }
            }
        }
    }

    if ($blockingErrors.Count -eq 0) {
        $dupDiskNumbers = @($resolvedEntries | Group-Object { $_.Target.DiskNumber } | Where-Object { $_.Count -gt 1 })
        if ($dupDiskNumbers.Count -gt 0) { $blockingErrors += 'More than one approved disk descriptor resolved to the same Windows disk number; refusing to proceed.' }
        $dupLetters = @($resolvedEntries | Group-Object { $_.Target.DriveLetter } | Where-Object { $_.Count -gt 1 })
        if ($dupLetters.Count -gt 0) { $blockingErrors += 'More than one approved disk descriptor requests the same drive letter; refusing to proceed.' }
    }

    # Whole-guest drive-letter conflict preflight (any disk, not just
    # approved ones). Loop variable deliberately $resolvedEntry, never
    # $target -- see Initialize-LimsGuestDataDisks.research.md under
    # this heading for why.
    if ($blockingErrors.Count -eq 0) {
        foreach ($resolvedEntry in $resolvedEntries) {
            $resolvedTarget = $resolvedEntry.Target
            $conflict = @($GuestPartitionInventory | Where-Object {
                    $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq $resolvedTarget.DriveLetter -and $_.DiskNumber -ne $resolvedTarget.DiskNumber
                })
            if ($conflict.Count -gt 0) {
                $blockingErrors += "Drive letter $($resolvedTarget.DriveLetter): is already in use by a disk other than the approved target (Windows disk $($resolvedTarget.DiskNumber))."
            }
        }
    }

    if ($blockingErrors.Count -eq 0) {
        foreach ($resolvedEntry in $resolvedEntries) {
            $resolvedTarget = $resolvedEntry.Target
            $guestDisk = $GuestDiskInventory | Where-Object { $_.Number -eq $resolvedTarget.DiskNumber } | Select-Object -First 1
            $partitions = @($GuestPartitionInventory | Where-Object { $_.DiskNumber -eq $resolvedTarget.DiskNumber })
            $dataPartitions = @($partitions | Where-Object { -not (Test-IsMsrPartition $_) })

            # Correlate the data partition to its own volume via the
            # documented volume-GUID access path (Get-Volume's Path
            # property is exactly that string), never by drive letter
            # alone. https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume
            $volume = $null
            if ($dataPartitions.Count -eq 1) {
                $guidPaths = @($dataPartitions[0].AccessPaths | Where-Object { $_ -match $script:VolumeGuidPathPattern })
                if ($guidPaths.Count -eq 1) {
                    $matchingVolumes = @($GuestVolumeInventory | Where-Object { $_.Path -and [string]$_.Path -eq $guidPaths[0] })
                    if ($matchingVolumes.Count -eq 1) {
                        $volume = $matchingVolumes[0]
                    }
                    elseif ($matchingVolumes.Count -gt 1) {
                        $blockingErrors += "More than one guest volume reports the same volume GUID path associated with disk $($resolvedTarget.DiskNumber); ambiguous volume association."
                    }
                }
                elseif ($guidPaths.Count -gt 1) {
                    $blockingErrors += "Disk $($resolvedTarget.DiskNumber)'s data partition reports more than one volume GUID access path; ambiguous volume association."
                }
            }

            $plan = Get-DiskPreparationPlan -Target $resolvedTarget -GuestDisk $guestDisk -Partitions $partitions -Volume $volume
            $diskPlans += [pscustomobject]@{ Target = $resolvedTarget; ExpectedDisk = $resolvedEntry.ExpectedDisk; Plan = $plan }
            if ($plan.Action -eq 'Fail') { $blockingErrors += $plan.Reason }
        }
    }

    # SQL-only DVD-ROM plan (APP's DvdLetterMoveTarget is always empty).
    $eDataDiskPlanAction = 'NotApplicable'
    $ePlanEntry = $diskPlans | Where-Object { $_.Target.DriveLetter -eq 'E' } | Select-Object -First 1
    if ($ePlanEntry) { $eDataDiskPlanAction = $ePlanEntry.Plan.Action }

    $eOpticalDrives = @($GuestOpticalDriveInventory | Where-Object { $_.Drive -and $_.Drive.ToString().ToUpperInvariant() -eq 'E:' })
    $eDvdVolumes = @($GuestDvdVolumeInventory | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq 'E:' -and [int]$_.DriveType -eq 5 })

    $destinationOccupied = $false
    if (-not [string]::IsNullOrWhiteSpace($DvdLetterMoveTarget)) {
        $destinationOccupied = Test-DestinationLetterOccupied -Letter $DvdLetterMoveTarget `
            -OpticalDrives $GuestOpticalDriveInventory -DvdVolumes $GuestDvdVolumeInventory `
            -Volumes $GuestVolumeInventory -Partitions $GuestPartitionInventory
    }

    $dvdPlan = Get-DvdPreparationPlan -DvdLetterMoveTarget $DvdLetterMoveTarget -EDataDiskPlanAction $eDataDiskPlanAction `
        -ExpectedOpticalDriveName $allowlistEntry.ExpectedOpticalDriveName -EOpticalDrives $eOpticalDrives -EDvdVolumes $eDvdVolumes `
        -DestinationOccupied $destinationOccupied
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
# INVENTORY ADAPTERS -- the only functions that call real cmdlets to READ
# guest/Azure state. Each fetches its FULL inventory once per plan build;
# filtering happens in memory, so a query failure always hard-fails rather
# than looking like "no partitions"/"free letter". Pester mocks these.
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
        PS 5.1-compatible IMDS query. -NoProxy on Invoke-RestMethod
        requires PS 6+, unavailable in PS 5.1 (Run Command's default
        Windows runtime). Uses the PS5-compatible proxy-bypass instead
        (empty System.Net.WebProxy bound to a WebRequestSession). See
        Initialize-LimsGuestDataDisks.research.md under this heading.
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
        Merges Get-Disk (IsBoot/IsSystem/IsOffline/IsReadOnly/
        OperationalStatus/PartitionStyle/Size/UniqueId) with
        Win32_DiskDrive (SCSI addressing: SCSIBus/SCSIPort/SCSITargetId/
        SCSILogicalUnit) into one plain-object inventory, fetched in full
        exactly once.
    #>
    $disks = @(Get-Disk)
    $diskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive)
    $diskDrivesByIndex = @{}
    foreach ($dd in $diskDrives) { $diskDrivesByIndex[[int]$dd.Index] = $dd }

    $result = @()
    foreach ($disk in $disks) {
        $dd = $diskDrivesByIndex[[int]$disk.Number]
        $result += [pscustomobject]@{
            Number            = [int]$disk.Number
            UniqueId          = [string]$disk.UniqueId
            IsBoot            = [bool]$disk.IsBoot
            IsSystem          = [bool]$disk.IsSystem
            IsOffline         = [bool]$disk.IsOffline
            IsReadOnly        = [bool]$disk.IsReadOnly
            OperationalStatus = [string]$disk.OperationalStatus
            PartitionStyle    = [string]$disk.PartitionStyle
            SizeBytes         = [int64]$disk.Size
            ScsiBus           = if ($dd) { [int]$dd.SCSIBus } else { -1 }
            ScsiPort          = if ($dd) { [int]$dd.SCSIPort } else { -1 }
            ScsiTargetId      = if ($dd) { [int]$dd.SCSITargetId } else { -1 }
            ScsiLogicalUnit   = if ($dd) { [int]$dd.SCSILogicalUnit } else { -1 }
            FriendlyName      = [string]$disk.FriendlyName
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
        <#
        Get-Volume's own `Path` property is exactly the volume's own
        canonical volume-GUID path -- used (instead of drive letter alone)
        to correlate a partition's AccessPaths to this specific volume.
    #>
    $volumes = @(Get-Volume)
    return @($volumes | ForEach-Object {
            [pscustomobject]@{
                DriveLetter        = if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }
                FileSystem         = [string]$_.FileSystem
                FileSystemLabel    = [string]$_.FileSystemLabel
                AllocationUnitSize = [int64]$_.AllocationUnitSize
                SizeBytes          = [int64]$_.Size
                Path               = [string]$_.Path
            }
        })
}

function Get-GuestDvdVolumeInventoryAdapter {
        <#
        Win32_Volume (not Get-Volume) is used specifically because it is
        the only documented way to later change an optical drive's letter
        (Set-CimInstance -InputObject).
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

function Get-GuestOpticalDriveInventoryAdapter {
        <#
        Win32_CDROMDrive -- source for an optical device's stable
        identity (DeviceID survives a letter move) and MediaLoaded,
        left as whatever WMI reports (can be $null) rather than
        force-cast to [bool], so Get-DvdPreparationPlan can tell
        "unknown" apart from "false".
    #>
    $drives = @(Get-CimInstance -ClassName Win32_CDROMDrive)
    return @($drives | ForEach-Object {
            [pscustomobject]@{
                DeviceId    = [string]$_.DeviceID
                Name        = [string]$_.Name
                Drive       = if ($_.Drive) { [string]$_.Drive } else { '' }
                MediaLoaded = $_.MediaLoaded
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
    param([Parameter(Mandatory = $true)] [string] $DeviceId, [Parameter(Mandatory = $true)] [string] $ToLetter)
    $drive = Get-CimInstance -ClassName Win32_CDROMDrive | Where-Object { $_.DeviceID -eq $DeviceId }
    if (-not $drive) {
        Assert-GuestDiskPreparationFailure "Optical device '$DeviceId' could no longer be found immediately before the mutating move."
    }
    $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='E:'"
    if (-not $volume) {
        Assert-GuestDiskPreparationFailure 'No volume found at E: immediately before the mutating move; identity changed since the immediate pre-mutation re-check.'
    }
    Set-CimInstance -InputObject $volume -Property @{ DriveLetter = "${ToLetter}:" }
}

function Confirm-DvdRomLetterMoveSucceededAdapter {
    param([Parameter(Mandatory = $true)] [string] $DeviceId, [Parameter(Mandatory = $true)] [string] $ToLetter)
    $drive = Get-CimInstance -ClassName Win32_CDROMDrive | Where-Object { $_.DeviceID -eq $DeviceId }
    $atTargetVolume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($ToLetter):'"
    $stillAtSourceVolume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='E:'"
    $driveNowAtTarget = $drive -and $drive.Drive -and ([string]$drive.Drive).ToUpperInvariant() -eq "${ToLetter}:".ToUpperInvariant()
    return [bool]($driveNowAtTarget -and $atTargetVolume -and -not $stillAtSourceVolume)
}

# =============================================================================
# ORCHESTRATION -- ties inventory adapters + decision logic + (Apply only)
# mutation adapters together. This is the only layer where plan-building and
# real I/O are combined; it is covered by Pester end-to-end tests that mock
# only the adapter functions above.
# =============================================================================

function Get-FreshGuestDiskPreparationPlan {
        <#
        Gathers every adapter's inventory fresh (no caching, no reuse
        across calls) and builds one complete plan via
        Get-GuestDiskPreparationPlan. Called at least twice per -Mode
        Apply invocation so that a previous plan is never treated as
        authorization to trust stale state.
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

        # Every call below is wrapped in @(...) at the ASSIGNMENT site, not
    # only inside each adapter's own return statement, so a legitimate
    # zero-element inventory (e.g. no optical drive attached) is never
    # silently unrolled to $null. See
    # Initialize-LimsGuestDataDisks.research.md under this function's own
    # heading for the exact failure mode this avoids.
    $guestDiskInventory = @(Get-GuestDiskInventoryAdapter)
    $guestPartitionInventory = @(Get-GuestPartitionInventoryAdapter)
    $guestVolumeInventory = @(Get-GuestVolumeInventoryAdapter)
    $guestDvdVolumeInventory = @(Get-GuestDvdVolumeInventoryAdapter)
    $guestOpticalDriveInventory = @(Get-GuestOpticalDriveInventoryAdapter)

    return Get-GuestDiskPreparationPlan -Target $Target `
        -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
        -ExpectedVmName $ExpectedVmName -ExpectedComputerName $ExpectedComputerName `
        -ExpectedDisks $ExpectedDisks -DvdLetterMoveTarget $DvdLetterMoveTarget `
        -ImdsCompute $imdsCompute -ActualComputerName $actualComputerName `
        -GuestDiskInventory $guestDiskInventory -GuestPartitionInventory $guestPartitionInventory `
        -GuestVolumeInventory $guestVolumeInventory -GuestDvdVolumeInventory $guestDvdVolumeInventory `
        -GuestOpticalDriveInventory $guestOpticalDriveInventory
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
        Write-Output "  LUN $($dp.Target.Lun) '$($dp.Target.DiskName)' -> Windows disk $($dp.Target.DiskNumber) (UniqueId=$($dp.Target.DiskUniqueId), IsOffline=$($dp.Target.IsOffline), IsReadOnly=$($dp.Target.IsReadOnly), OperationalStatus=$($dp.Target.OperationalStatus)): proposed action = $($dp.Plan.Action)$reasonSuffix"
    }
    $dvdReasonSuffix = if ($Plan.DvdPlan.Reason) { " ($($Plan.DvdPlan.Reason))" } else { '' }
    $dvdDeviceSuffix = if ($Plan.DvdPlan.DeviceId) { " (device='$($Plan.DvdPlan.DeviceId)')" } else { '' }
    Write-Output "  DVD-ROM: proposed action = $($Plan.DvdPlan.Action)$dvdReasonSuffix$dvdDeviceSuffix"
    Write-Output '===== end report ====='
}

function Assert-DiskReadyForDestructiveStage {
        <#
        Immediately before Initialize-Disk/New-Partition/Format-Volume:
        re-fetches a FRESH IMDS query and guest inventory (never the
        $applyPlan snapshot), re-resolves the disk, confirms its
        UniqueId/number unchanged, then applies a stage-specific shape
        assertion. Throws on mismatch -- never retries or rolls back.

        -Target looks up the SAME allowlist entry's own
        AttestedGuestUniqueId (never caller-supplied) so an active
        attested binding is honored consistently here.
    #>
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('App', 'Sql')] [string] $Target,
        [Parameter(Mandatory = $true)] [ValidateSet('Initialize', 'NewPartition', 'Format')] [string] $Stage,
        [Parameter(Mandatory = $true)] $DiskPlan,
        [Parameter(Mandatory = $true)] [string] $ExpectedSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ExpectedResourceGroupName,
        [Parameter(Mandatory = $false)] [int] $NewPartitionNumber
    )

    $originalTarget = $DiskPlan.Target
    $expectedDisk = $DiskPlan.ExpectedDisk

    $allowlistEntry = (Get-ApprovedDiskPreparationAllowlist)[$Target]
    $attestedBindingConfig = Test-AttestedGuestUniqueIdBindingConfiguration -Disks $allowlistEntry.Disks
    $attestedGuestUniqueId = ''
    if ($attestedBindingConfig.IsAttestedMode) {
        $allowlistDiskForLun = $allowlistEntry.Disks | Where-Object { [int]$_.Lun -eq [int]$originalTarget.Lun } | Select-Object -First 1
        if ($allowlistDiskForLun) { $attestedGuestUniqueId = [string]$allowlistDiskForLun.AttestedGuestUniqueId }
    }

    $imdsCompute = Get-ImdsComputeMetadataAdapter
    $imdsDataDisks = @()
    if ($imdsCompute.storageProfile -and $imdsCompute.storageProfile.dataDisks) {
        $imdsDataDisks = @($imdsCompute.storageProfile.dataDisks)
    }
    $imdsResourceDiskSizeBytes = Get-ImdsResourceDiskSizeBytes -ImdsCompute $imdsCompute

    $freshGuestDiskInventory = @(Get-GuestDiskInventoryAdapter)
    $candidateResult = Select-NonOsNonTemporaryDiskCandidates -GuestDiskInventory $freshGuestDiskInventory `
        -ImdsResourceDiskSizeBytes $imdsResourceDiskSizeBytes -SkipTemporaryDiskExclusion $attestedBindingConfig.IsAttestedMode
    if ($candidateResult.Error) {
        Assert-GuestDiskPreparationFailure "Immediate pre-mutation re-check ($Stage) failed: $($candidateResult.Error)"
    }

    $resolution = Resolve-ApprovedDiskTarget -ExpectedDisk $expectedDisk -ImdsDataDisks $imdsDataDisks `
        -CandidateGuestDisks $candidateResult.Candidates -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
        -AttestedGuestUniqueId $attestedGuestUniqueId
    if ($resolution.Error) {
        Assert-GuestDiskPreparationFailure "Immediate pre-mutation re-check ($Stage) failed: $($resolution.Error)"
    }
    $freshTarget = $resolution.Target

    if ($freshTarget.DiskUniqueId -ne $originalTarget.DiskUniqueId -or $freshTarget.DiskNumber -ne $originalTarget.DiskNumber) {
        Assert-GuestDiskPreparationFailure "Disk identity for LUN $($originalTarget.Lun) changed immediately before the '$Stage' step (was Windows disk $($originalTarget.DiskNumber)/UniqueId=$($originalTarget.DiskUniqueId), now Windows disk $($freshTarget.DiskNumber)/UniqueId=$($freshTarget.DiskUniqueId)); refusing to proceed."
    }

    $freshPartitionsWide = @(Get-GuestPartitionInventoryAdapter)
    $freshPartitionsForDisk = @($freshPartitionsWide | Where-Object { $_.DiskNumber -eq $freshTarget.DiskNumber })
    $freshGuestDisk = $freshGuestDiskInventory | Where-Object { $_.Number -eq $freshTarget.DiskNumber } | Select-Object -First 1

    $shapeError = $null
    if ($Stage -eq 'Initialize') {
        $shapeError = Test-DiskReadyForInitializeStage -GuestDisk $freshGuestDisk -Partitions $freshPartitionsForDisk -Target $freshTarget -AllGuestPartitions $freshPartitionsWide
    }
    elseif ($Stage -eq 'NewPartition') {
        $shapeError = Test-DiskReadyForNewPartitionStage -GuestDisk $freshGuestDisk -Partitions $freshPartitionsForDisk
    }
    elseif ($Stage -eq 'Format') {
        $freshVolumesWide = @(Get-GuestVolumeInventoryAdapter)
        $shapeError = Test-PartitionReadyForFormatStage -Partitions $freshPartitionsForDisk -Target $freshTarget -NewPartitionNumber $NewPartitionNumber -Volumes $freshVolumesWide
    }
    if ($shapeError) {
        Assert-GuestDiskPreparationFailure "Immediate pre-mutation re-check ($Stage) failed: $shapeError"
    }
}

function Assert-DvdReadyForMove {
        <#
        Immediately before the mutating DVD-ROM move: re-fetches every
        inventory fresh (never $applyPlan) and re-runs
        Get-DvdPreparationPlan, confirming the SAME device identity,
        media state, and occupancy as previously verified. Returns the
        re-checked plan or throws on any mismatch.
    #>
    param(
        [Parameter(Mandatory = $true)] $DvdPlan,
        [Parameter(Mandatory = $true)] [string] $DvdLetterMoveTarget,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $ExpectedOpticalDriveName
    )

    $freshOpticalDrives = @(Get-GuestOpticalDriveInventoryAdapter)
    $freshDvdVolumes = @(Get-GuestDvdVolumeInventoryAdapter)
    $freshVolumes = @(Get-GuestVolumeInventoryAdapter)
    $freshPartitions = @(Get-GuestPartitionInventoryAdapter)

    $eOpticalDrives = @($freshOpticalDrives | Where-Object { $_.Drive -and $_.Drive.ToString().ToUpperInvariant() -eq 'E:' })
    $eDvdVolumes = @($freshDvdVolumes | Where-Object { $_.DriveLetter -and $_.DriveLetter.ToUpperInvariant() -eq 'E:' -and [int]$_.DriveType -eq 5 })
    $destinationOccupied = Test-DestinationLetterOccupied -Letter $DvdLetterMoveTarget `
        -OpticalDrives $freshOpticalDrives -DvdVolumes $freshDvdVolumes -Volumes $freshVolumes -Partitions $freshPartitions

    # EDataDiskPlanAction is deliberately passed as 'Initialize' (a
    # placeholder meaning merely "not NoOp") -- the caller only reaches this
    # function after already confirming, via the whole-VM $applyPlan, that
    # the SQL DATA disk is NOT already correctly prepared; recomputing that
    # here would require re-running the entire disk plan rather than just
    # this device's own identity/media/occupancy state.
    $recheckPlan = Get-DvdPreparationPlan -DvdLetterMoveTarget $DvdLetterMoveTarget -EDataDiskPlanAction 'Initialize' `
        -ExpectedOpticalDriveName $ExpectedOpticalDriveName -EOpticalDrives $eOpticalDrives -EDvdVolumes $eDvdVolumes -DestinationOccupied $destinationOccupied

    if ($recheckPlan.Action -ne 'Move') {
        $reasonSuffix = if ($recheckPlan.Reason) { " ($($recheckPlan.Reason))" } else { '' }
        Assert-GuestDiskPreparationFailure "Immediate pre-move DVD-ROM re-check failed: expected a confirmed Move but got '$($recheckPlan.Action)'$reasonSuffix; stopping before any mutation."
    }
    if ($recheckPlan.DeviceId -ne $DvdPlan.DeviceId) {
        Assert-GuestDiskPreparationFailure "The optical device at E: identity changed between the original plan and the immediate pre-move re-check (was '$($DvdPlan.DeviceId)', now '$($recheckPlan.DeviceId)'); refusing to proceed."
    }

    return $recheckPlan
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
    # The plan above is NEVER authorization to mutate by itself -- the
    # entire plan is rebuilt from scratch immediately before any mutation
    # (the whole-VM preflight); each mutating call below ALSO re-verifies
    # its own exact target via Assert-DiskReadyForDestructiveStage /
    # Assert-DvdReadyForMove immediately before it runs.
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

    $expectedOpticalDriveName = (Get-ApprovedDiskPreparationAllowlist)[$Target].ExpectedOpticalDriveName

    # DVD move (if required) strictly before any partition creation on E:,
    # then per-disk Initialize/New-Partition/Format in LUN order, each
    # re-verified immediately before its own mutating call. Never a drive
    # letter alone, never Clear-Disk/diskpart clean, never auto-retried,
    # and a step already succeeded this invocation is never rolled back.
    if ($applyPlan.DvdPlan.Action -eq 'Move') {
        $reconfirmedDvdPlan = Assert-DvdReadyForMove -DvdPlan $applyPlan.DvdPlan -DvdLetterMoveTarget $DvdLetterMoveTarget -ExpectedOpticalDriveName $expectedOpticalDriveName
        Write-Output "Moving the confirmed empty virtual DVD-ROM (device '$($reconfirmedDvdPlan.DeviceId)') from E: to ${DvdLetterMoveTarget}:."
        Move-DvdRomLetterAdapter -DeviceId $reconfirmedDvdPlan.DeviceId -ToLetter $DvdLetterMoveTarget
        if (-not (Confirm-DvdRomLetterMoveSucceededAdapter -DeviceId $reconfirmedDvdPlan.DeviceId -ToLetter $DvdLetterMoveTarget)) {
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

        Assert-DiskReadyForDestructiveStage -Target $Target -Stage 'Initialize' -DiskPlan $diskPlan `
            -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName
        Write-Output "Disk $($diskTarget.DiskNumber) (LUN $($diskTarget.Lun), $($diskTarget.DiskName)) is RAW with no partitions -- initializing."
        Initialize-ApprovedDiskAdapter -DiskNumber $diskTarget.DiskNumber

        $partitionsAfterInit = @(Get-GuestPartitionInventoryAdapter | Where-Object { $_.DiskNumber -eq $diskTarget.DiskNumber })
        $unexpectedAfterInit = @($partitionsAfterInit | Where-Object { -not (Test-IsMsrPartition $_) })
        if ($unexpectedAfterInit.Count -gt 0) {
            Assert-GuestDiskPreparationFailure "Disk $($diskTarget.DiskNumber) shows unexpected partition(s) immediately after GPT initialization; stopping for manual review rather than proceeding."
        }

        Assert-DiskReadyForDestructiveStage -Target $Target -Stage 'NewPartition' -DiskPlan $diskPlan `
            -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName
        $newPartition = New-ApprovedPartitionAdapter -DiskNumber $diskTarget.DiskNumber -DriveLetter $diskTarget.DriveLetter

        Assert-DiskReadyForDestructiveStage -Target $Target -Stage 'Format' -DiskPlan $diskPlan `
            -ExpectedSubscriptionId $ExpectedSubscriptionId -ExpectedResourceGroupName $ExpectedResourceGroupName `
            -NewPartitionNumber $newPartition.PartitionNumber
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

<#
    Shared pure safety functions for LIMS APP data-disk migration.

    Loaded by the control-plane script, the guest copy script, and the
    pipeline run-id resolver. No Azure CLI, no guest cmdlets, no I/O.
#>

Set-StrictMode -Version Latest

function Test-LimsAppMigNumericBuildId {
    <#
        Azure DevOps Build.BuildId is a decimal integer. Anything else
        (quotes, newlines, metacharacters, logging-command text) is rejected
        before it is published or interpolated.
    #>
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Migration run ID is empty.' }
    }
    if ($Value -match '[^\x20-\x7e]') {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Migration run ID contains non-printable or non-ASCII characters.' }
    }
    if ($Value -match '`n' -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Migration run ID contains a newline.' }
    }
    if ($Value -like '*##vso*') {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Migration run ID contains Azure DevOps logging-command text.' }
    }
    if ($Value -notmatch '^[0-9]+$') {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Migration run ID must be a numeric Azure DevOps Build.BuildId (digits only).' }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null }
}

function Test-LimsAppMigPipelineSafeValue {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Value
    )

    if ($null -eq $Value) { $Value = '' }
    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Pipeline variable '$Name' contains a newline and will not be published." }
    }
    if ($Value -like '*##vso*') {
        return [pscustomobject]@{ Accepted = $false; Reason = "Pipeline variable '$Name' contains Azure DevOps logging-command text and will not be published." }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null }
}

function Resolve-LimsAppMigPipelineRunId {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SuppliedRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $BuildId
    )

    $supplied = if ($null -eq $SuppliedRunId) { '' } else { $SuppliedRunId.Trim() }
    $build = if ($null -eq $BuildId) { '' } else { $BuildId.Trim() }

    if ($Action -eq 'plan') {
        if ([string]::IsNullOrEmpty($supplied)) {
            return [pscustomobject]@{ Accepted = $true; RunId = ''; Reason = $null }
        }
        $check = Test-LimsAppMigNumericBuildId -Value $supplied
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $supplied; Reason = $null }
    }

    if ($Action -eq 'cleanup') {
        if ([string]::IsNullOrEmpty($supplied)) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = 'Cleanup requires migrationRunId set to the numeric Build.BuildId of the stage or attach-and-inspect run that created the temporary disk.' }
        }
        $check = Test-LimsAppMigNumericBuildId -Value $supplied
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $supplied; Reason = $null }
    }

    if ($Action -eq 'stage' -or $Action -eq 'attach-and-inspect' -or $Action -eq 'configure-app' -or $Action -eq 'activate-app') {
        $candidate = $supplied
        if ([string]::IsNullOrEmpty($candidate)) { $candidate = $build }
        $check = Test-LimsAppMigNumericBuildId -Value $candidate
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $candidate; Reason = $null }
    }

    return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = "Unsupported action '$Action'." }
}

function ConvertTo-NormalizedResourceId {
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function Test-NormalizedResourceIdEquals {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Left,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Right
    )
    return (ConvertTo-NormalizedResourceId -ResourceId $Left) -eq (ConvertTo-NormalizedResourceId -ResourceId $Right)
}

function ConvertTo-NormalizedUniqueId {
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $UniqueId)
    if ([string]::IsNullOrWhiteSpace($UniqueId)) { return '' }
    return ($UniqueId.Trim() -replace '[{}\-]', '').ToUpperInvariant()
}

function Test-NormalizedUniqueIdEquals {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Left,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Right
    )
    $a = ConvertTo-NormalizedUniqueId -UniqueId $Left
    $b = ConvertTo-NormalizedUniqueId -UniqueId $Right
    if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return $false }
    return $a -eq $b
}

function Get-AzureCliErrorClassification {
    <#
        Authorization is classified before NotFound: some 403 bodies mention
        "not found". Confirmed NotFound is the only status that may be
        treated as "resource already gone".
    #>
    param(
        [Parameter(Mandatory = $true)] [int] $ExitCode,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Text
    )

    if ($ExitCode -eq 0) { return 'Found' }
    $t = ''
    if ($Text) { $t = $Text.ToLowerInvariant() }

    if ($t -match 'authorizationfailed' -or $t -match 'forbidden' -or $t -match '\(403\)' -or $t -match '\(401\)' -or $t -match 'invalidauthenticationtoken' -or $t -match 'authenticationfailed') {
        return 'Authorization'
    }
    if ($t -match 'timed out' -or $t -match 'timeout' -or $t -match 'connection (was )?(reset|refused|aborted)' -or $t -match 'name or service not known' -or $t -match 'temporary failure in name resolution' -or $t -match 'network is unreachable') {
        return 'Network'
    }
    if ($t -match 'precondition' -or $t -match '\(412\)') {
        return 'PreconditionFailed'
    }
    if ($t -match 'already exists' -or $t -match 'conflicterror' -or $t -match '\(409\)' -or $t -match 'resourcealreadyexists') {
        return 'AlreadyExists'
    }
    if ($t -match 'resourcenotfound' -or $t -match 'resourcenotfounderror' -or $t -match '\(404\)' -or $t -match 'could not be found' -or $t -match 'was not found' -or $t -match 'not found') {
        return 'NotFound'
    }
    return 'Other'
}

function Get-MigrationLockAcquireDecision {
    <#
        Per-environment lock is the destination VM tag set, acquired with
        If-Match before any snapshot, disk create, or attach. Disk create
        is create-or-update and is not exclusive. Stage and
        attach-and-inspect may acquire only when the lock is empty.
        Overlapping attempts are refused even with the same run ID.
        Cleanup of the holding run is allowed after the guest command is
        Found and terminal, or after reviewed pre-submit recovery.
        The run ID remains the ownership key.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExistingLockRunId,
        [Parameter(Mandatory = $true)] [string] $ThisRunId,
        [Parameter(Mandatory = $false)] [ValidateSet('Stage', 'AttachAndInspect', 'Cleanup')] [string] $Purpose = 'Stage'
    )

    if ([string]::IsNullOrWhiteSpace($ExistingLockRunId)) {
        return [pscustomobject]@{ Allowed = $true; Resume = $false; Reason = $null }
    }
    if ($ExistingLockRunId -eq $ThisRunId) {
        if ($Purpose -eq 'Stage' -or $Purpose -eq 'AttachAndInspect') {
            return [pscustomobject]@{
                Allowed = $false
                Resume  = $false
                Reason  = "Environment lock is already held by migration run '$ThisRunId'. Overlapping migration attempts are refused even with the same run ID. Wait for the in-flight attempt to finish, then run cleanup after the guest command is Found and terminal."
            }
        }
        return [pscustomobject]@{ Allowed = $true; Resume = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Allowed = $false
        Resume  = $false
        Reason  = "Environment lock is held by migration run '$ExistingLockRunId'. Refusing concurrent run '$ThisRunId'. Run cleanup for the holding run first, after its guest command is Found and terminal."
    }
}

function Get-GuestCommandCleanupDecision {
    param(
        [Parameter(Mandatory = $true)] [string] $LookupClassification,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExecutionState
    )

    if ($LookupClassification -eq 'NotFound') {
        return [pscustomobject]@{
            Allowed = $false
            State   = 'Indeterminate'
            Reason  = 'Run Command NotFound does not prove the guest command was never submitted. Submission may still be in flight (the window after disk attach and before the command resource exists). Cleanup retains resources until the command is Found and terminal (Succeeded, Failed, or Canceled).'
        }
    }
    if ($LookupClassification -eq 'Authorization' -or $LookupClassification -eq 'Network' -or $LookupClassification -eq 'Other') {
        return [pscustomobject]@{
            Allowed = $false
            State   = 'Indeterminate'
            Reason  = "Guest command lookup classified as '$LookupClassification'. Cleanup retains the temporary disk and snapshot because execution status is indeterminate."
        }
    }
    if ($LookupClassification -ne 'Found') {
        return [pscustomobject]@{
            Allowed = $false
            State   = 'Indeterminate'
            Reason  = "Guest command lookup classification '$LookupClassification' is not a confirmed terminal or never-submitted state."
        }
    }

    $state = ''
    if ($ExecutionState) { $state = $ExecutionState.Trim() }
    if ($state -eq 'Succeeded' -or $state -eq 'Failed' -or $state -eq 'Canceled') {
        return [pscustomobject]@{ Allowed = $true; State = $state; Reason = $null }
    }
    if ([string]::IsNullOrWhiteSpace($state)) {
        return [pscustomobject]@{
            Allowed = $false
            State   = 'Indeterminate'
            Reason  = 'Guest command resource exists but reported no executionState. Cleanup retains resources.'
        }
    }
    return [pscustomobject]@{
        Allowed = $false
        State   = $state
        Reason  = "Guest command executionState is '$state' (not terminal). Cleanup retains resources until Succeeded, Failed, or Canceled. NotFound is not treated as never submitted."
    }
}

function Get-AtomicLockApplyDecision {
    <#
        Destination VM tag update with If-Match. Found means this attempt
        holds the lock. PreconditionFailed (412) means a simultaneous
        attempt won the race. Disk create-or-update is not used as a lock.
    #>
    param([Parameter(Mandatory = $true)] [string] $Classification)

    if ($Classification -eq 'Found') {
        return [pscustomobject]@{ Allowed = $true; Reason = $null }
    }
    if ($Classification -eq 'PreconditionFailed') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Lost the atomic destination-VM lock race (If-Match precondition failed). Another attempt updated the VM. No snapshot, disk create, or attach was performed.'
        }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "Atomic lock apply classified as '$Classification'. Refusing to snapshot or attach without exclusive ownership."
    }
}

function Get-PreSubmitRecoveryDecision {
    <#
        Reviewed recovery when attach-and-inspect ended before guest
        submission. NotFound alone is still indeterminate. Recovery is
        allowed only when the operator explicitly requests it, the
        attempt is inspect-only, guest submission was never recorded,
        the inspect command is NotFound, and this run holds the lock.
    #>
    param(
        [Parameter(Mandatory = $false)] [bool] $Requested = $false,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $GuestSubmittedTag,
        [Parameter(Mandatory = $true)] [string] $LookupClassification,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $LockOwnerRunId,
        [Parameter(Mandatory = $true)] [string] $ThisRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CopyStatusTag
    )

    if (-not $Requested) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Pre-submit recovery was not requested. Run Command NotFound remains indeterminate.'
        }
    }
    if ($CopyStatusTag -ne 'InspectOnly') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Pre-submit recovery is reviewed only for attach-and-inspect (CopyStatus=InspectOnly).'
        }
    }
    $submitted = [string]$GuestSubmittedTag
    if ($submitted -eq 'true' -or $submitted -eq 'True' -or $submitted -eq '1') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Guest submission was recorded. Run Command NotFound is indeterminate; do not treat the command as never submitted.'
        }
    }
    if ($LookupClassification -ne 'NotFound') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-submit recovery requires the inspect command to be NotFound (never created). Lookup is '$LookupClassification'."
        }
    }
    if ([string]::IsNullOrWhiteSpace($LockOwnerRunId) -or $LockOwnerRunId -ne $ThisRunId) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-submit recovery requires the destination VM lock to be held by this run '$ThisRunId'."
        }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = $null }
}

function Get-TemporaryDiskLineageDecision {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $TemporaryDiskId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $TemporaryDiskSourceId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SnapshotId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SnapshotSourceId,
        [Parameter(Mandatory = $true)] [string] $OriginalSourceDiskId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RecordedTemporaryDiskId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RecordedSnapshotId
    )

    if ([string]::IsNullOrWhiteSpace($TemporaryDiskId) -or [string]::IsNullOrWhiteSpace($SnapshotId)) {
        return [pscustomobject]@{ Matches = $false; Reason = 'Positive lineage requires the exact temporary-disk resource ID and snapshot resource ID. Name-only identity is insufficient.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordedTemporaryDiskId) -and -not (Test-NormalizedResourceIdEquals -Left $TemporaryDiskId -Right $RecordedTemporaryDiskId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Temporary disk ID '$TemporaryDiskId' does not match the recorded ID '$RecordedTemporaryDiskId'." }
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordedSnapshotId) -and -not (Test-NormalizedResourceIdEquals -Left $SnapshotId -Right $RecordedSnapshotId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Snapshot ID '$SnapshotId' does not match the recorded ID '$RecordedSnapshotId'." }
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $TemporaryDiskSourceId -Right $SnapshotId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Temporary disk '$TemporaryDiskId' was created from '$TemporaryDiskSourceId', not snapshot '$SnapshotId'." }
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $SnapshotSourceId -Right $OriginalSourceDiskId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Snapshot '$SnapshotId' was created from '$SnapshotSourceId', not the original source disk '$OriginalSourceDiskId'." }
    }
    return [pscustomobject]@{ Matches = $true; Reason = $null }
}

function Get-ImdsResourceDiskSizeBytes {
    param([Parameter(Mandatory = $true)] $ImdsCompute)

    if (-not $ImdsCompute.storageProfile) { return $null }
    $storageProfile = $ImdsCompute.storageProfile
    if ($storageProfile.PSObject.Properties.Name -notcontains 'resourceDisk' -or -not $storageProfile.resourceDisk) { return $null }
    if ($storageProfile.resourceDisk.PSObject.Properties.Name -notcontains 'size') { return $null }
    return [int64]$storageProfile.resourceDisk.size * 1024
}

function Select-NonOsGuestDisks {
    <#
        Excludes only the OS disk (IsBoot/IsSystem). IMDS resourceDisk.size
        is not used: on DEV that value does not match the Windows temporary
        disk size, and LUN 1 collides with Azure temporary storage.
        Independently attested UniqueId (or a captured ARM uniqueId) is
        required to pick a managed disk from this pool.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDisks
    )

    $osDisks = @($GuestDisks | Where-Object { $_.IsBoot -or $_.IsSystem })
    if ($osDisks.Count -ne 1) {
        return [pscustomobject]@{ Candidates = @(); Reason = "Expected exactly one boot/system Windows disk, found $($osDisks.Count)." }
    }
    $nonOs = @($GuestDisks | Where-Object { -not ($_.IsBoot -or $_.IsSystem) })

    $invalidScsi = @($nonOs | Where-Object {
            -not $_.PSObject.Properties['ScsiLogicalUnit'] -or [int]$_.ScsiLogicalUnit -lt 0
        })
    if ($invalidScsi.Count -gt 0) {
        $numbers = ($invalidScsi | ForEach-Object { $_.Number }) -join ', '
        return [pscustomobject]@{ Candidates = @(); Reason = "Windows disk(s) $numbers reported missing SCSI Logical Unit; cannot map Azure LUNs. Evidence needed: Win32_DiskDrive.SCSILogicalUnit for every non-OS disk." }
    }

    return [pscustomobject]@{ Candidates = $nonOs; Reason = $null }
}

function Format-GuestDiskInventoryEvidence {
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDisks)

    if (@($GuestDisks).Count -eq 0) { return '(no Windows disks reported)' }
    return ((@($GuestDisks) | ForEach-Object {
                "Number=$($_.Number);UniqueId='$($_.UniqueId)';Size=$($_.SizeBytes);ScsiLun=$($_.ScsiLogicalUnit);IsBoot=$($_.IsBoot);IsSystem=$($_.IsSystem)"
            }) -join ' | ')
}

function Get-ImdsDataDiskByResourceId {
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedManagedDiskId
    )

    if (-not $ImdsCompute.storageProfile -or -not $ImdsCompute.storageProfile.dataDisks) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = 'IMDS compute document has no storageProfile.dataDisks.' }
    }

    $diskMatches = @()
    foreach ($disk in @($ImdsCompute.storageProfile.dataDisks)) {
        $id = ''
        if ($disk.managedDisk -and $disk.managedDisk.id) { $id = [string]$disk.managedDisk.id }
        if (Test-NormalizedResourceIdEquals -Left $id -Right $ExpectedManagedDiskId) {
            $diskMatches += $disk
        }
    }
    if ($diskMatches.Count -eq 0) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = "IMDS has no data disk whose managedDisk.id equals '$ExpectedManagedDiskId'." }
    }
    if ($diskMatches.Count -gt 1) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = "IMDS reports more than one data disk with managedDisk.id '$ExpectedManagedDiskId'." }
    }
    return [pscustomobject]@{ Matches = $true; Disk = $diskMatches[0]; Reason = $null }
}

function Resolve-GuestDiskIdentity {
    <#
        Correlates an exact Azure managed-disk resource ID to one Windows
        disk by independently attested UniqueId (destination A:) or the
        captured ARM uniqueId (snapshot-derived temporary disk), then the
        caller proves the partition. IMDS resourceDisk.size is not used:
        on DEV that value does not match the Windows temporary disk, and
        SCSI LUN 1 collides with Azure temporary storage. Duplicate SCSI
        LUNs are allowed when UniqueId uniquely identifies the disk.
    #>
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDisks,
        [Parameter(Mandatory = $true)] [string] $ExpectedManagedDiskId,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExpectedUniqueId,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    $imdsEntry = Get-ImdsDataDiskByResourceId -ImdsCompute $ImdsCompute -ExpectedManagedDiskId $ExpectedManagedDiskId
    if (-not $imdsEntry.Matches) {
        return [pscustomobject]@{ Resolved = $false; Disk = $null; Reason = "$Role identity failed: $($imdsEntry.Reason)" }
    }
    $imdsLun = [int]$imdsEntry.Disk.lun
    if ($imdsLun -ne $ExpectedLun) {
        return [pscustomobject]@{ Resolved = $false; Disk = $null; Reason = "$Role IMDS LUN $imdsLun for '$ExpectedManagedDiskId' does not match mapped LUN $ExpectedLun." }
    }

    $pool = Select-NonOsGuestDisks -GuestDisks $GuestDisks
    if ($pool.Reason) {
        return [pscustomobject]@{ Resolved = $false; Disk = $null; Reason = "$Role identity failed: $($pool.Reason) Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)" }
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedUniqueId)) {
        return [pscustomobject]@{
            Resolved = $false
            Disk     = $null
            Reason   = "${Role}: no attested or captured UniqueId was supplied. IMDS resourceDisk.size is not used to pick a Windows disk (DEV size discrepancy / LUN 1 collision). Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks). Needed: ARM uniqueId of '$ExpectedManagedDiskId' matching Get-Disk UniqueId."
        }
    }

    $uniqueMatches = @($pool.Candidates | Where-Object { Test-NormalizedUniqueIdEquals -Left ([string]$_.UniqueId) -Right $ExpectedUniqueId })
    if ($uniqueMatches.Count -ne 1) {
        return [pscustomobject]@{
            Resolved = $false
            Disk     = $null
            Reason   = "${Role}: expected UniqueId '$ExpectedUniqueId' resolved to $($uniqueMatches.Count) guest disk(s) among non-OS disks. Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)."
        }
    }
    return [pscustomobject]@{ Resolved = $true; Disk = $uniqueMatches[0]; Reason = $null }
}

function Test-DriveLetterOnResolvedDisk {
    param(
        [Parameter(Mandatory = $true)] [string] $DriveLetter,
        [Parameter(Mandatory = $true)] [int] $ExpectedDiskNumber,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Partitions,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExpectedLabel,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $VolumeLabel,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    $letter = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant()
    $letterMatches = @($Partitions | Where-Object {
            $_.DriveLetter -and ([string]$_.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant() -eq $letter
        })
    if ($letterMatches.Count -eq 0) {
        return [pscustomobject]@{ Matches = $false; Reason = "$Role drive ${letter}: is not assigned to any partition." }
    }
    if ($letterMatches.Count -gt 1) {
        return [pscustomobject]@{ Matches = $false; Reason = "$Role drive ${letter}: is assigned to more than one partition." }
    }
    $partition = $letterMatches[0]
    if ([int]$partition.DiskNumber -ne $ExpectedDiskNumber) {
        return [pscustomobject]@{
            Matches = $false
            Reason  = "$Role drive ${letter}: is on Windows disk $($partition.DiskNumber), not the resolved managed disk (Windows disk $ExpectedDiskNumber). A matching volume label or letter is insufficient."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLabel) -and $VolumeLabel -ne $ExpectedLabel) {
        return [pscustomobject]@{ Matches = $false; Reason = "$Role volume ${letter}: label '$VolumeLabel' does not match '$ExpectedLabel'." }
    }
    return [pscustomobject]@{ Matches = $true; Partition = $partition; Reason = $null }
}

function Test-CopyRootIsLocalVolume {
    param(
        [Parameter(Mandatory = $true)] [string] $RootPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RootTarget,
        [Parameter(Mandatory = $false)] [AllowNull()] [int] $DriveType,
        [Parameter(Mandatory = $true)] [bool] $IsReparsePoint
    )

    if ($RootPath -match '^\\\\') {
        return [pscustomobject]@{ Local = $false; Reason = "Copy root '$RootPath' is a UNC path (Azure Files / network share). Only local volumes are permitted." }
    }
    if ($RootTarget -match '^\\\\') {
        return [pscustomobject]@{ Local = $false; Reason = "Copy root '$RootPath' resolves to UNC target '$RootTarget'." }
    }
    if ($IsReparsePoint) {
        return [pscustomobject]@{ Local = $false; Reason = "Copy root '$RootPath' is a reparse point. Refusing to copy through a redirected root." }
    }
    if ($null -ne $DriveType -and [int]$DriveType -ne 3) {
        return [pscustomobject]@{ Local = $false; Reason = "Copy root '$RootPath' has Win32 drive type $DriveType (3 = local disk). Refusing a non-local volume." }
    }
    return [pscustomobject]@{ Local = $true; Reason = $null }
}

function Test-ReparsePointPolicy {
    <#
        Source: any reparse point other than the excluded relative path is
        unexpected and fails. Destination: any reparse point in a path the
        copy could write (everything except the excluded relative path)
        fails. The excluded path is not traversed and must not be recreated.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $SourceReparseRelativePaths,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $DestinationReparseRelativePaths,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExcludeRelativePaths
    )

    $exclude = @{}
    foreach ($path in @($ExcludeRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $exclude[$path.Trim().TrimStart('\').ToLowerInvariant()] = $true
        }
    }

    $unexpectedSource = @()
    foreach ($path in @($SourceReparseRelativePaths)) {
        $key = $path.Trim().TrimStart('\').ToLowerInvariant()
        if (-not $exclude.ContainsKey($key)) { $unexpectedSource += $path }
    }
    if ($unexpectedSource.Count -gt 0) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Unexpected source reparse point(s): $($unexpectedSource -join ', '). Refusing to follow or copy them (Azure Files / external storage)." }
    }

    $destHits = @()
    foreach ($path in @($DestinationReparseRelativePaths)) {
        $key = $path.Trim().TrimStart('\').ToLowerInvariant()
        if (-not $exclude.ContainsKey($key)) { $destHits += $path }
    }
    if ($destHits.Count -gt 0) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Destination reparse point(s) in a path the copy could write: $($destHits -join ', '). Refusing to copy through redirected destinations." }
    }

    return [pscustomobject]@{ Accepted = $true; Reason = $null }
}

function ConvertTo-RelativeWindowsPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $FullPath
    )
    $rootNorm = $Root.TrimEnd('\') + '\'
    $fullNorm = $FullPath
    if ($fullNorm.Length -ge $rootNorm.Length -and $fullNorm.Substring(0, $rootNorm.Length).ToLowerInvariant() -eq $rootNorm.ToLowerInvariant()) {
        return $fullNorm.Substring($rootNorm.Length).TrimStart('\')
    }
    return $FullPath
}

function Test-LimsAppV2SecretPresent {
    <#
        Reasons never include the secret value.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{ Present = $false; Reason = "Protected parameter '$Name' is missing or empty. Refusing to continue. The secret value is not logged." }
    }
    return [pscustomobject]@{ Present = $true; Reason = $null }
}

function Test-TextContainsSecret {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Secret
    )
    if ([string]::IsNullOrWhiteSpace($Secret)) { return $false }
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.Contains($Secret)
}

function Test-LimsAppV2ProcrunSettingsComplete {
    param([Parameter(Mandatory = $true)] $AppV2)

    $required = @(
        'JbossProcrunExePath', 'JbossProcrunJvm', 'JbossProcrunStartClass',
        'JbossProcrunStartMode', 'JbossProcrunWorkingPath'
    )
    $missing = @()
    foreach ($name in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$AppV2.$name)) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            Complete = $false
            Missing  = $missing
            Reason   = "JBoss Procrun settings are incomplete ($($missing -join ', ')). Report these before changing service '$($AppV2.JbossServiceName)'."
        }
    }
    return [pscustomobject]@{ Complete = $true; Missing = @(); Reason = $null }
}

function Test-LimsAppV2ServiceBinarySettingsComplete {
    param(
        [Parameter(Mandatory = $true)] [string] $ServiceName,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $BinaryPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Arguments
    )
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { $missing += 'ServiceName' }
    if ([string]::IsNullOrWhiteSpace($BinaryPath)) { $missing += 'BinaryPath' }
    if ([string]::IsNullOrWhiteSpace($Arguments)) { $missing += 'Arguments' }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            Complete = $false
            Missing  = $missing
            Reason   = "Service '$ServiceName' binary settings are incomplete ($($missing -join ', ')). Report these before changing the service."
        }
    }
    return [pscustomobject]@{ Complete = $true; Missing = @(); Reason = $null }
}

function ConvertTo-NormalizedUnc {
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Unc)
    if ([string]::IsNullOrWhiteSpace($Unc)) { return '' }
    return $Unc.Trim().TrimEnd('\').ToLowerInvariant()
}

function Test-NormalizedUncEquals {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Left,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Right
    )
    return (ConvertTo-NormalizedUnc -Unc $Left) -eq (ConvertTo-NormalizedUnc -Unc $Right)
}

function Get-AzureFilesCredentialTargetFromUnc {
    param([Parameter(Mandatory = $true)] [string] $Unc)
    if ($Unc -notmatch '^\\\\([^\\]+)\\([^\\]+)') {
        return [pscustomobject]@{ Accepted = $false; Target = ''; User = ''; Reason = "Azure Files UNC '$Unc' is not \\\\account.file.core.windows.net\\share." }
    }
    $hostName = $Matches[1]
    $account = ($hostName -split '\.')[0]
    if ([string]::IsNullOrWhiteSpace($account)) {
        return [pscustomobject]@{ Accepted = $false; Target = ''; User = ''; Reason = "Unable to derive the Azure Files account name from UNC '$Unc'." }
    }
    return [pscustomobject]@{
        Accepted = $true
        Target   = $hostName
        User     = "AZURE\$account"
        Reason   = $null
    }
}

function Test-SdmshomeLinkDecision {
    param(
        [Parameter(Mandatory = $true)] [bool] $PathExists,
        [Parameter(Mandatory = $true)] [bool] $IsReparsePoint,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExistingTarget,
        [Parameter(Mandatory = $true)] [string] $ExpectedTarget,
        [Parameter(Mandatory = $false)] [bool] $IsDirectory = $false,
        [Parameter(Mandatory = $false)] [bool] $IsFile = $false
    )
    if (-not $PathExists) {
        return [pscustomobject]@{ Action = 'Create'; Reason = $null }
    }
    if ($IsReparsePoint) {
        if (Test-NormalizedUncEquals -Left $ExistingTarget -Right $ExpectedTarget) {
            return [pscustomobject]@{ Action = 'Reuse'; Reason = $null }
        }
        return [pscustomobject]@{
            Action = 'Fail'
            Reason = "Path is a reparse point targeting '$ExistingTarget', not the reviewed UNC. Refusing to replace it."
        }
    }
    if ($IsFile) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = 'Path is an existing file. Refusing to replace it with a directory symbolic link.' }
    }
    if ($IsDirectory) {
        return [pscustomobject]@{ Action = 'Fail'; Reason = 'Path is an existing directory. Refusing to replace it with a directory symbolic link.' }
    }
    return [pscustomobject]@{ Action = 'Fail'; Reason = 'Path is occupied by an unexpected item. Refusing to create the directory symbolic link.' }
}

function Test-CopyCompletedForConfigure {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CopyCompletedTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CopyStatusTag
    )
    if ($CopyCompletedTag -eq 'Succeeded' -or $CopyStatusTag -eq 'Succeeded') {
        return [pscustomobject]@{ Allowed = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "configure-app requires a completed copy of the mapped A: volume (destination VM tag limsAppMigCopyCompleted or limsAppMigCopyStatus = Succeeded). Current completed='$CopyCompletedTag', status='$CopyStatusTag'."
    }
}

function Test-LimsAppV2ActivationReviews {
    param([Parameter(Mandatory = $true)] $AppV2)
    $blocked = @()
    foreach ($name in @('JdbcSettingsReviewStatus', 'ApacheSettingsReviewStatus', 'ShibbolethSettingsReviewStatus', 'AzureFilesUncReviewStatus')) {
        if ([string]$AppV2.$name -ne 'Passed') { $blocked += "$name='$($AppV2.$name)'" }
    }
    if ($blocked.Count -gt 0) {
        return [pscustomobject]@{
            Passed = $false
            Reason = "Automatic startup stays disabled until v2 JDBC, Apache, Shibboleth, and Azure Files UNC reviews are Passed ($($blocked -join ', '))."
        }
    }
    return [pscustomobject]@{ Passed = $true; Reason = $null }
}

function Test-AzureFilesUncReadyForLink {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SuppliedUnc,
        [Parameter(Mandatory = $true)] $AppV2
    )
    if ([string]::IsNullOrWhiteSpace($SuppliedUnc)) {
        return [pscustomobject]@{ Ready = $false; Skip = $true; Reason = 'Azure Files UNC was not supplied. The startup task is registered disabled and the sdmshome link is not created.' }
    }
    if ([string]$AppV2.AzureFilesUncReviewStatus -ne 'Passed') {
        return [pscustomobject]@{
            Ready  = $false
            Skip   = $false
            Reason = "Azure Files UNC was supplied but mapping AzureFilesUncReviewStatus='$($AppV2.AzureFilesUncReviewStatus)' is not Passed. Refusing to create A:\\lv89\\sdmshome."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$AppV2.AzureFilesUnc)) {
        return [pscustomobject]@{ Ready = $false; Skip = $false; Reason = 'Azure Files UNC was supplied but the reviewed mapping UNC is empty. Record the v2 UNC in the mapping before creating the link.' }
    }
    if (-not (Test-NormalizedUncEquals -Left $SuppliedUnc -Right $AppV2.AzureFilesUnc)) {
        return [pscustomobject]@{
            Ready  = $false
            Skip   = $false
            Reason = 'Supplied Azure Files UNC does not match the reviewed mapping UNC. The supplied value is not logged.'
        }
    }
    return [pscustomobject]@{ Ready = $true; Skip = $false; Reason = $null }
}

function Get-LimsAppV2RegisterPreflight {
    <#
        Collects every register blocker before any guest mutation.
        Reasons never include secret values.
    #>
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $JbossRunnerPassword,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AzureFilesAccessKey,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AzureFilesUnc,
        [Parameter(Mandatory = $false)] [AllowNull()] [hashtable] $PathExists,
        [Parameter(Mandatory = $false)] [AllowNull()] $LinkObservation
    )

    if ($null -eq $PathExists) { $PathExists = @{} }
    $app = $Environment.AppV2
    $issues = @()

    $password = Test-LimsAppV2SecretPresent -Name 'JbossRunnerPassword' -Value $JbossRunnerPassword
    if (-not $password.Present) { $issues += $password.Reason }

    $procrun = Test-LimsAppV2ProcrunSettingsComplete -AppV2 $app
    if (-not $procrun.Complete) {
        $issues += $procrun.Reason
    }
    else {
        foreach ($path in @($app.JbossProcrunExePath, $app.JbossProcrunJvm, $app.JbossProcrunWorkingPath)) {
            if (-not $PathExists.ContainsKey($path) -or -not [bool]$PathExists[$path]) {
                $issues += "Reviewed Procrun path '$path' does not exist on this guest."
            }
        }
    }

    $apache = Test-LimsAppV2ServiceBinarySettingsComplete -ServiceName $app.ApacheServiceName -BinaryPath $app.ApacheBinaryPath -Arguments $app.ApacheArguments
    if (-not $apache.Complete) {
        $issues += $apache.Reason
    }
    elseif (-not $PathExists.ContainsKey($app.ApacheBinaryPath) -or -not [bool]$PathExists[$app.ApacheBinaryPath]) {
        $issues += "Reviewed binary '$($app.ApacheBinaryPath)' for '$($app.ApacheServiceName)' was not found."
    }

    $shib = Test-LimsAppV2ServiceBinarySettingsComplete -ServiceName $app.ShibbolethServiceName -BinaryPath $app.ShibbolethBinaryPath -Arguments $app.ShibbolethArguments
    if (-not $shib.Complete) {
        $issues += $shib.Reason
    }
    elseif (-not $PathExists.ContainsKey($app.ShibbolethBinaryPath) -or -not [bool]$PathExists[$app.ShibbolethBinaryPath]) {
        $issues += "Reviewed binary '$($app.ShibbolethBinaryPath)' for '$($app.ShibbolethServiceName)' was not found."
    }

    $dirPaths = @($app.JbossRunnerDirectoryPaths)
    if ($dirPaths.Count -eq 0) {
        $issues += 'Reviewed application-directory paths are empty; ACLs cannot be granted.'
    }
    else {
        foreach ($path in $dirPaths) {
            if (-not $PathExists.ContainsKey($path) -or -not [bool]$PathExists[$path]) {
                $issues += "Reviewed application directory '$path' does not exist on this guest."
            }
        }
    }

    $unc = Test-AzureFilesUncReadyForLink -SuppliedUnc $AzureFilesUnc -AppV2 $app
    if (-not $unc.Skip -and -not $unc.Ready) {
        $issues += $unc.Reason
    }
    if ($unc.Ready) {
        $key = Test-LimsAppV2SecretPresent -Name 'AzureFilesAccessKey' -Value $AzureFilesAccessKey
        if (-not $key.Present) { $issues += $key.Reason }
        $cred = Get-AzureFilesCredentialTargetFromUnc -Unc $app.AzureFilesUnc
        if (-not $cred.Accepted) { $issues += $cred.Reason }
        if ($null -eq $LinkObservation -or -not [bool]$LinkObservation.ParentExists) {
            $issues += 'Parent path for A:\lv89\sdmshome does not exist. The mapped A: volume is missing lv89 after copy.'
        }
        else {
            $decision = Test-SdmshomeLinkDecision -PathExists ([bool]$LinkObservation.Exists) -IsReparsePoint ([bool]$LinkObservation.IsReparsePoint) -ExistingTarget ([string]$LinkObservation.Target) -ExpectedTarget $app.AzureFilesUnc -IsDirectory ([bool]$LinkObservation.IsDirectory) -IsFile ([bool]$LinkObservation.IsFile)
            if ($decision.Action -eq 'Fail') { $issues += $decision.Reason }
        }
    }

    return [pscustomobject]@{
        Allowed = ($issues.Count -eq 0)
        Issues  = $issues
        Reason  = $(if ($issues.Count -gt 0) { 'Preflight failed before any guest change: ' + ($issues -join ' ') } else { $null })
    }
}

function Test-LimsAppV2ScheduledTaskResultIsFresh {
    <#
        A prior LastTaskResult=0 is not accepted. The current LastRunTime
        must be strictly after the previous LastRunTime and not earlier
        than the attempt start (2s clock skew).
    #>
    param(
        [Parameter(Mandatory = $true)] [datetime] $AttemptStartedUtc,
        [Parameter(Mandatory = $false)] [AllowNull()] $PreviousLastRunTime,
        [Parameter(Mandatory = $false)] [AllowNull()] $CurrentLastRunTime,
        [Parameter(Mandatory = $false)] [AllowNull()] $LastTaskResult
    )

    if ($null -eq $CurrentLastRunTime -or $CurrentLastRunTime -eq [datetime]::MinValue) {
        return [pscustomobject]@{ Fresh = $false; Succeeded = $false; Reason = 'No scheduled-task LastRunTime was recorded for this attempt. Refusing to accept a stale result.' }
    }

    $currentUtc = $CurrentLastRunTime.ToUniversalTime()
    if ($PreviousLastRunTime -and $PreviousLastRunTime -ne [datetime]::MinValue) {
        if ($currentUtc -le $PreviousLastRunTime.ToUniversalTime()) {
            return [pscustomobject]@{ Fresh = $false; Succeeded = $false; Reason = 'Scheduled-task LastRunTime was not updated for this attempt. Refusing to accept a stale result.' }
        }
    }
    if ($currentUtc -lt $AttemptStartedUtc.AddSeconds(-2)) {
        return [pscustomobject]@{ Fresh = $false; Succeeded = $false; Reason = 'Scheduled-task LastRunTime is older than this attempt. Refusing to accept a stale result.' }
    }
    if ($null -eq $LastTaskResult -or [int]$LastTaskResult -ne 0) {
        return [pscustomobject]@{
            Fresh     = $true
            Succeeded = $false
            Reason    = "Scheduled-task context could not access the reviewed path (last result $LastTaskResult)."
        }
    }
    return [pscustomobject]@{ Fresh = $true; Succeeded = $true; Reason = $null }
}

function Test-ScheduledTaskUserResolution {
    <#
        The machine-qualified Register-ScheduledTask -User candidate must
        resolve to the same SID as the local account created/reconciled
        by New-LocalUser / Get-LocalUser. Reasons do not include secrets.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SamAccountName,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Candidate,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExpectedSid,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ResolvedSid
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSid)) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Local account '$SamAccountName' SID was not found. Refusing to register the scheduled task." }
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedSid)) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Machine-qualified name '$Candidate' did not resolve to a SID. Refusing to register the scheduled task." }
    }
    if ($ResolvedSid -ne $ExpectedSid) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Machine-qualified name '$Candidate' resolved to a different SID than local account '$SamAccountName'. Refusing to register the scheduled task." }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null }
}

function Get-ScheduledTaskSamAccountName {
    param([Parameter(Mandatory = $true)] [string] $UserName)
    $trimmed = $UserName.Trim()
    if ($trimmed -match '^[.]\\(.+)$') { return $Matches[1] }
    if ($trimmed -match '^[^\\]+\\(.+)$') { return $Matches[1] }
    return $trimmed
}

function Test-CollectInventoryOnlyFlag {
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] $Value)

    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text.Trim() -eq 'true' -or $text.Trim() -eq 'True' -or $text.Trim() -eq '1' -or $text.Trim() -eq 'yes')
}

function Test-LimsAppMigStageCleanupAllowed {
    param([Parameter(Mandatory = $true)] $Environment)

    $reparse = [string]$Environment.WindowsReparseValidationStatus
    $symlink = [string]$Environment.WindowsSymlinkValidationStatus
    if ($reparse -eq 'Passed' -and $symlink -eq 'Passed') {
        return [pscustomobject]@{ Allowed = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "Stage and cleanup are blocked pending Windows reparse-point validation (junction status='$reparse', directory-symlink status='$symlink'). Plan remains available. See docs/operations.md."
    }
}

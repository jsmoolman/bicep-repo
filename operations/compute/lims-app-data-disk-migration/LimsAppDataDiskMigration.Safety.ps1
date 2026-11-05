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

function Test-LimsAppMigLiteralToken {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Token
    )
    if ($null -eq $Value) { return $false }
    return $Value.Trim() -ceq $Token
}

function Resolve-LimsAppMigPipelineRunId {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SuppliedRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $BuildId
    )

    $supplied = if ($null -eq $SuppliedRunId) { '' } else { $SuppliedRunId.Trim() }
    $build = if ($null -eq $BuildId) { '' } else { $BuildId.Trim() }
    $isAuto = Test-LimsAppMigLiteralToken -Value $supplied -Token 'auto'

    if ($Action -eq 'plan') {
        if ([string]::IsNullOrEmpty($supplied) -or $isAuto) {
            return [pscustomobject]@{ Accepted = $true; RunId = ''; Reason = $null }
        }
        $check = Test-LimsAppMigNumericBuildId -Value $supplied
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $supplied; Reason = $null }
    }

    if ($Action -eq 'cleanup') {
        if ([string]::IsNullOrEmpty($supplied) -or $isAuto) {
            return [pscustomobject]@{
                Accepted = $false
                RunId    = ''
                Reason   = "Cleanup rejects migrationRunId 'auto' and empty values. Supply the original numeric Build.BuildId of the stage or attach-and-inspect run that created the temporary disk."
            }
        }
        $check = Test-LimsAppMigNumericBuildId -Value $supplied
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $supplied; Reason = $null }
    }

    if ($Action -eq 'stage' -or $Action -eq 'attach-and-inspect' -or $Action -eq 'configure-app' -or $Action -eq 'activate-app') {
        $candidate = $supplied
        if ([string]::IsNullOrEmpty($candidate) -or $isAuto) { $candidate = $build }
        $check = Test-LimsAppMigNumericBuildId -Value $candidate
        if (-not $check.Accepted) {
            return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = $check.Reason }
        }
        return [pscustomobject]@{ Accepted = $true; RunId = $candidate; Reason = $null }
    }

    return [pscustomobject]@{ Accepted = $false; RunId = ''; Reason = "Unsupported action '$Action'." }
}

function Resolve-LimsAppMigPipelineAzureFilesUnc {
    <#
        Form default is the literal token not-used so the required
        parameter can be submitted for actions that ignore UNC.
        configure-app and activate-app never accept that placeholder.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SuppliedUnc
    )

    $supplied = if ($null -eq $SuppliedUnc) { '' } else { $SuppliedUnc.Trim() }
    $isPlaceholder = Test-LimsAppMigLiteralToken -Value $supplied -Token 'not-used'

    if ($Action -eq 'configure-app' -or $Action -eq 'activate-app') {
        if ($isPlaceholder) {
            return [pscustomobject]@{
                Accepted = $false
                Unc      = ''
                Reason   = "azureFilesUnc placeholder 'not-used' is not accepted for configure-app or activate-app. Supply the reviewed v2 UNC after AzureFilesUncReviewStatus is Passed."
            }
        }
        return [pscustomobject]@{ Accepted = $true; Unc = $supplied; Reason = $null }
    }

    if ($Action -eq 'plan' -or $Action -eq 'attach-and-inspect' -or $Action -eq 'stage' -or $Action -eq 'cleanup') {
        return [pscustomobject]@{ Accepted = $true; Unc = ''; Reason = $null }
    }

    return [pscustomobject]@{ Accepted = $false; Unc = ''; Reason = "Unsupported action '$Action'." }
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
            Reason  = 'Lost the If-Match race (precondition failed). Another attempt updated the VM. This path must stop.'
        }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "Atomic lock apply classified as '$Classification'. Refusing to snapshot or attach without exclusive ownership."
    }
}

function Get-GuestSubmittedEvidenceDecision {
    <#
        Only the exact token written at lock/attach time is evidence that
        guest submission has not started. Missing, empty, or any other
        value is unknown and blocks recovery and submission.
    #>
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] $Value)

    if ($null -eq $Value) {
        return [pscustomobject]@{ Accepted = $false; Reason = "GuestSubmitted must be the explicit value 'false'. Missing, empty, or other values are unknown and block recovery and submission." }
    }
    if ($Value -is [bool]) {
        return [pscustomobject]@{ Accepted = $false; Reason = "GuestSubmitted must be the explicit value 'false'. Missing, empty, or other values are unknown and block recovery and submission." }
    }
    if ([string]$Value -ceq 'false') {
        return [pscustomobject]@{ Accepted = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Accepted = $false
        Reason   = "GuestSubmitted must be the explicit value 'false'. Missing, empty, or other values are unknown and block recovery and submission."
    }
}

function Get-InspectAttemptStateTransitionDecision {
    <#
        Mutually exclusive inspect-attempt transitions. Only one of
        Prepared -> Submitting or Prepared -> Recovering may succeed.
        The exclusive write uses If-Match; the loser must stop.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $FromState,
        [Parameter(Mandatory = $true)] [string] $ToState
    )

    $from = if ($null -eq $FromState) { '' } else { [string]$FromState }
    if ($from -ceq 'Prepared' -and ($ToState -ceq 'Submitting' -or $ToState -ceq 'Recovering')) {
        return [pscustomobject]@{ Allowed = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "Inspect attempt state '$from' cannot transition to '$ToState'. Only Prepared -> Submitting or Prepared -> Recovering is allowed."
    }
}

function Get-PreSubmitRecoveryDecision {
    <#
        Reviewed recovery when attach-and-inspect ended before guest
        submission. NotFound alone is still indeterminate. Recovery is
        allowed only when the operator explicitly requests it, the
        attempt is inspect-only, GuestSubmitted is the explicit value
        false, the attempt state is Prepared, the inspect command is
        NotFound, and this run holds the lock.
    #>
    param(
        [Parameter(Mandatory = $false)] [bool] $Requested = $false,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $GuestSubmittedTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AttemptStateTag,
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
    $submitted = Get-GuestSubmittedEvidenceDecision -Value $GuestSubmittedTag
    if (-not $submitted.Accepted) {
        return [pscustomobject]@{ Allowed = $false; Reason = $submitted.Reason }
    }
    $transition = Get-InspectAttemptStateTransitionDecision -FromState $AttemptStateTag -ToState 'Recovering'
    if (-not $transition.Allowed) {
        return [pscustomobject]@{ Allowed = $false; Reason = $transition.Reason }
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

function Get-RequiredCustomerManagedEncryptionType {
    return 'EncryptionAtRestWithCustomerKey'
}

function Get-ReviewedPreCreateLockRecoveryRunId {
    return '139523'
}

function Get-CustomerManagedEncryptionDecision {
    <#
        Snapshot and snapshot-derived disk create must preserve the
        verified source encryption type and DES. Microsoft's CMK CLI
        requires both --encryption-type and --disk-encryption-set.
        Platform-key, dual-key, empty, and mismatched settings are
        rejected.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SourceEncryptionType,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SourceDiskEncryptionSetId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $DestinationEncryptionType,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $DestinationDiskEncryptionSetId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExpectedDiskEncryptionSetId
    )

    $required = Get-RequiredCustomerManagedEncryptionType
    if ([string]::IsNullOrWhiteSpace($SourceEncryptionType)) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = 'Source data disk encryption type is missing. Refusing to snapshot without the verified customer-managed encryption type.' }
    }
    if ($SourceEncryptionType -ne $required) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = "Source encryption type '$SourceEncryptionType' is not the verified '$required'. Unsupported or inconsistent encryption settings are rejected." }
    }
    if ([string]::IsNullOrWhiteSpace($DestinationEncryptionType)) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = 'Destination data disk encryption type is missing. Refusing to proceed without the verified customer-managed encryption type.' }
    }
    if ($DestinationEncryptionType -ne $required) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = "Destination encryption type '$DestinationEncryptionType' is not the verified '$required'. Unsupported or inconsistent encryption settings are rejected." }
    }
    if ($SourceEncryptionType -ne $DestinationEncryptionType) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = "Source encryption type '$SourceEncryptionType' does not equal destination encryption type '$DestinationEncryptionType'." }
    }
    if ([string]::IsNullOrWhiteSpace($SourceDiskEncryptionSetId) -or [string]::IsNullOrWhiteSpace($DestinationDiskEncryptionSetId) -or [string]::IsNullOrWhiteSpace($ExpectedDiskEncryptionSetId)) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = 'Customer-managed encryption requires the verified Disk Encryption Set on the source disk, destination disk, and mapping pin.' }
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $SourceDiskEncryptionSetId -Right $DestinationDiskEncryptionSetId) -or -not (Test-NormalizedResourceIdEquals -Left $SourceDiskEncryptionSetId -Right $ExpectedDiskEncryptionSetId)) {
        return [pscustomobject]@{ Accepted = $false; EncryptionType = $null; DiskEncryptionSetId = $null; Reason = "Verified Disk Encryption Set mismatch. Source='$SourceDiskEncryptionSetId', destination='$DestinationDiskEncryptionSetId', mapping='$ExpectedDiskEncryptionSetId'." }
    }
    return [pscustomobject]@{
        Accepted            = $true
        EncryptionType      = $required
        DiskEncryptionSetId = $SourceDiskEncryptionSetId
        Reason              = $null
    }
}

function New-IncrementalSnapshotCreateArgumentList {
    <#
        Pure Azure CLI argument construction for an incremental CMK
        snapshot. Microsoft's customer-managed-key example supplies both
        --encryption-type and --disk-encryption-set.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SnapshotName,
        [Parameter(Mandatory = $true)] [string] $SourceDiskId,
        [Parameter(Mandatory = $true)] [string] $Location,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $EncryptionType,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DiskEncryptionSetId
    )

    $decision = Get-CustomerManagedEncryptionDecision -SourceEncryptionType $EncryptionType -SourceDiskEncryptionSetId $DiskEncryptionSetId -DestinationEncryptionType $EncryptionType -DestinationDiskEncryptionSetId $DiskEncryptionSetId -ExpectedDiskEncryptionSetId $DiskEncryptionSetId
    if (-not $decision.Accepted) {
        return [pscustomobject]@{ Accepted = $false; Arguments = @(); Reason = $decision.Reason }
    }

    return [pscustomobject]@{
        Accepted  = $true
        Reason    = $null
        Arguments = @(
            'snapshot', 'create',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--name', $SnapshotName,
            '--source', $SourceDiskId,
            '--location', $Location,
            '--incremental', 'true',
            '--encryption-type', $decision.EncryptionType,
            '--disk-encryption-set', $decision.DiskEncryptionSetId,
            '--output', 'json'
        )
    }
}

function New-DiskFromSnapshotCreateArgumentList {
    <#
        Pure Azure CLI argument construction for a snapshot-derived disk.
        The same verified CMK type and DES are required; omitting
        --encryption-type is rejected.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName,
        [Parameter(Mandatory = $true)] [string] $SnapshotId,
        [Parameter(Mandatory = $true)] [string] $Location,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $EncryptionType,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $DiskEncryptionSetId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Zone,
        [Parameter(Mandatory = $false)] [hashtable] $Tags
    )

    $decision = Get-CustomerManagedEncryptionDecision -SourceEncryptionType $EncryptionType -SourceDiskEncryptionSetId $DiskEncryptionSetId -DestinationEncryptionType $EncryptionType -DestinationDiskEncryptionSetId $DiskEncryptionSetId -ExpectedDiskEncryptionSetId $DiskEncryptionSetId
    if (-not $decision.Accepted) {
        return [pscustomobject]@{ Accepted = $false; Arguments = @(); Reason = $decision.Reason }
    }

    $arguments = @(
        'disk', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DiskName,
        '--source', $SnapshotId,
        '--location', $Location,
        '--encryption-type', $decision.EncryptionType,
        '--disk-encryption-set', $decision.DiskEncryptionSetId,
        '--output', 'json'
    )
    if (-not [string]::IsNullOrWhiteSpace($Zone)) {
        $arguments += @('--zone', $Zone)
    }
    if ($Tags -and $Tags.Count -gt 0) {
        $arguments += '--tags'
        foreach ($key in $Tags.Keys) {
            $arguments += "$key=$($Tags[$key])"
        }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null; Arguments = $arguments }
}

function Test-ConfirmedNotFoundLookup {
    param(
        [Parameter(Mandatory = $true)] [string] $Role,
        [Parameter(Mandatory = $true)] [string] $Classification
    )

    if ($Classification -eq 'Authorization' -or $Classification -eq 'Network' -or $Classification -eq 'Other') {
        return [pscustomobject]@{
            Confirmed = $false
            Reason    = "Pre-create lock recovery $Role lookup classified as '$Classification'. Authorization, network, and other errors block recovery."
        }
    }
    if ($Classification -ne 'NotFound') {
        return [pscustomobject]@{
            Confirmed = $false
            Reason    = "Pre-create lock recovery requires confirmed NotFound for $Role. Lookup is '$Classification'."
        }
    }
    return [pscustomobject]@{ Confirmed = $true; Reason = $null }
}

function Get-PreCreateLockRecoveryDecision {
    <#
        Narrow recovery for attach-and-inspect run 139523, which acquired
        the destination-VM lock and then failed before snapshot creation.
        This is not Prepared pre-submit recovery and does not weaken those
        checks. Authorization/network lookups block. Resources that exist
        block.
    #>
    param(
        [Parameter(Mandatory = $false)] [bool] $Requested = $false,
        [Parameter(Mandatory = $true)] [string] $ThisRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $LockOwnerRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $PhaseTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AttemptStateTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CopyStatusTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $GuestSubmittedTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RecordedSnapshotId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RecordedTempDiskId,
        [Parameter(Mandatory = $true)] [string] $SnapshotLookupClassification,
        [Parameter(Mandatory = $true)] [string] $TemporaryDiskLookupClassification,
        [Parameter(Mandatory = $true)] [string] $RunCommandLookupClassification
    )

    $allowedRunId = Get-ReviewedPreCreateLockRecoveryRunId
    if (-not $Requested) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'Pre-create lock recovery was not requested.' }
    }
    if ($ThisRunId -ne $allowedRunId) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-create lock recovery is reviewed only for migration run '$allowedRunId'. Supplied run '$ThisRunId' is refused."
        }
    }
    if ([string]::IsNullOrWhiteSpace($LockOwnerRunId) -or $LockOwnerRunId -ne $allowedRunId) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-create lock recovery requires the destination VM lock to be held by run '$allowedRunId'."
        }
    }
    if ($PhaseTag -cne 'LockHeld') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-create lock recovery requires Phase=LockHeld (lock acquired, snapshot never created). Phase is '$PhaseTag'."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($AttemptStateTag)) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Pre-create lock recovery requires the pre-creation state with no inspect attempt state. AttemptState '$AttemptStateTag' is not that state. Prepared pre-submit recovery is a separate path and is unchanged."
        }
    }
    if ($CopyStatusTag -ne 'InspectOnly') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Pre-create lock recovery is reviewed only for attach-and-inspect (CopyStatus=InspectOnly).'
        }
    }
    $submitted = Get-GuestSubmittedEvidenceDecision -Value $GuestSubmittedTag
    if (-not $submitted.Accepted) {
        return [pscustomobject]@{ Allowed = $false; Reason = $submitted.Reason }
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordedSnapshotId) -or -not [string]::IsNullOrWhiteSpace($RecordedTempDiskId)) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Pre-create lock recovery requires no recorded snapshot or temporary-disk resource ID. Those IDs mean creation already started.'
        }
    }

    $snapshotGone = Test-ConfirmedNotFoundLookup -Role 'snapshot' -Classification $SnapshotLookupClassification
    if (-not $snapshotGone.Confirmed) {
        return [pscustomobject]@{ Allowed = $false; Reason = $snapshotGone.Reason }
    }
    $tempGone = Test-ConfirmedNotFoundLookup -Role 'temporary disk' -Classification $TemporaryDiskLookupClassification
    if (-not $tempGone.Confirmed) {
        return [pscustomobject]@{ Allowed = $false; Reason = $tempGone.Reason }
    }
    $commandGone = Test-ConfirmedNotFoundLookup -Role 'Run Command' -Classification $RunCommandLookupClassification
    if (-not $commandGone.Confirmed) {
        return [pscustomobject]@{ Allowed = $false; Reason = $commandGone.Reason }
    }

    return [pscustomobject]@{ Allowed = $true; Reason = $null }
}

function Get-InspectSubmitDecision {
    <#
        The submit path may continue only from Prepared with an explicit
        GuestSubmitted=false. The exclusive If-Match write to Submitting
        is applied after this decision.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $GuestSubmittedTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AttemptStateTag,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $LockOwnerRunId,
        [Parameter(Mandatory = $true)] [string] $ThisRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CopyStatusTag
    )

    if ($CopyStatusTag -ne 'InspectOnly') {
        return [pscustomobject]@{ Allowed = $false; Reason = 'Guest submission is recorded only for attach-and-inspect (CopyStatus=InspectOnly).' }
    }
    $submitted = Get-GuestSubmittedEvidenceDecision -Value $GuestSubmittedTag
    if (-not $submitted.Accepted) {
        return [pscustomobject]@{ Allowed = $false; Reason = $submitted.Reason }
    }
    $transition = Get-InspectAttemptStateTransitionDecision -FromState $AttemptStateTag -ToState 'Submitting'
    if (-not $transition.Allowed) {
        return [pscustomobject]@{ Allowed = $false; Reason = $transition.Reason }
    }
    if ([string]::IsNullOrWhiteSpace($LockOwnerRunId) -or $LockOwnerRunId -ne $ThisRunId) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Guest submission requires the destination VM lock to be held by this run '$ThisRunId'."
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
        A reviewed Windows UniqueId is required to pick a managed disk
        from this pool. Azure managed-disk uniqueId is a different
        identity and is not used here.
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

function Test-AzureDataDiskAttachmentIdentity {
    <#
        Azure managed-disk identity only: exact resource ID and LUN in
        IMDS. This is not Windows guest-disk identity.
    #>
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedManagedDiskId,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    $imdsEntry = Get-ImdsDataDiskByResourceId -ImdsCompute $ImdsCompute -ExpectedManagedDiskId $ExpectedManagedDiskId
    if (-not $imdsEntry.Matches) {
        return [pscustomobject]@{ Matches = $false; Reason = "$Role Azure identity failed: $($imdsEntry.Reason)" }
    }
    $imdsLun = [int]$imdsEntry.Disk.lun
    if ($imdsLun -ne $ExpectedLun) {
        return [pscustomobject]@{ Matches = $false; Reason = "$Role IMDS LUN $imdsLun for '$ExpectedManagedDiskId' does not match mapped LUN $ExpectedLun." }
    }
    return [pscustomobject]@{ Matches = $true; Reason = $null }
}

function Get-ReviewedGuestUniqueIdDecision {
    <#
        Windows UniqueId is independently attested or later reviewed.
        Azure managed-disk uniqueId is a different identifier and never
        proves guest identity.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Role,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ReviewedGuestUniqueId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ArmUniqueId
    )

    if (-not [string]::IsNullOrWhiteSpace($ReviewedGuestUniqueId) -and -not [string]::IsNullOrWhiteSpace($ArmUniqueId) -and (Test-NormalizedUniqueIdEquals -Left $ReviewedGuestUniqueId -Right $ArmUniqueId)) {
        return [pscustomobject]@{
            Proven = $false
            Reason = "${Role}: Azure managed-disk uniqueId must not be treated as Windows UniqueId. Supply a reviewed guest UniqueId that is independent of ARM uniqueId."
        }
    }
    if ([string]::IsNullOrWhiteSpace($ReviewedGuestUniqueId)) {
        return [pscustomobject]@{
            Proven = $false
            Reason = "${Role}: no reviewed Windows UniqueId was supplied. Azure managed-disk uniqueId is not Windows UniqueId and is not used as guest identity. Inventory is required. Stop before disk-state changes or copying."
        }
    }
    return [pscustomobject]@{ Proven = $true; Reason = $null }
}

function Resolve-GuestDiskIdentity {
    <#
        Correlates an exact Azure managed-disk resource ID and LUN to one
        Windows disk by a reviewed guest UniqueId, then the caller proves
        the partition. Azure uniqueId is not Windows UniqueId. IMDS
        resourceDisk.size is not used: on DEV that value does not match
        the Windows temporary disk, and SCSI LUN 1 collides with Azure
        temporary storage. Duplicate SCSI LUNs are allowed when the
        reviewed UniqueId uniquely identifies the disk.
    #>
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDisks,
        [Parameter(Mandatory = $true)] [string] $ExpectedManagedDiskId,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExpectedUniqueId,
        [Parameter(Mandatory = $true)] [string] $Role,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ArmUniqueId = ''
    )

    $azure = Test-AzureDataDiskAttachmentIdentity -ImdsCompute $ImdsCompute -ExpectedManagedDiskId $ExpectedManagedDiskId -ExpectedLun $ExpectedLun -Role $Role
    if (-not $azure.Matches) {
        return [pscustomobject]@{ Resolved = $false; Disk = $null; Reason = $azure.Reason }
    }

    $pool = Select-NonOsGuestDisks -GuestDisks $GuestDisks
    if ($pool.Reason) {
        return [pscustomobject]@{ Resolved = $false; Disk = $null; Reason = "$Role identity failed: $($pool.Reason) Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)" }
    }

    $reviewed = Get-ReviewedGuestUniqueIdDecision -Role $Role -ReviewedGuestUniqueId $ExpectedUniqueId -ArmUniqueId $ArmUniqueId
    if (-not $reviewed.Proven) {
        return [pscustomobject]@{
            Resolved = $false
            Disk     = $null
            Reason   = "$($reviewed.Reason) Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)."
        }
    }

    $uniqueMatches = @($pool.Candidates | Where-Object { Test-NormalizedUniqueIdEquals -Left ([string]$_.UniqueId) -Right $ExpectedUniqueId })
    if ($uniqueMatches.Count -ne 1) {
        return [pscustomobject]@{
            Resolved = $false
            Disk     = $null
            Reason   = "${Role}: reviewed Windows UniqueId '$ExpectedUniqueId' resolved to $($uniqueMatches.Count) guest disk(s) among non-OS disks. Inventory: $(Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)."
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
    $supplied = if ($null -eq $SuppliedUnc) { '' } else { $SuppliedUnc.Trim() }
    if (Test-LimsAppMigLiteralToken -Value $supplied -Token 'not-used') {
        return [pscustomobject]@{
            Ready  = $false
            Skip   = $false
            Reason = "azureFilesUnc placeholder 'not-used' is not accepted for configure-app or activate-app. Supply the reviewed v2 UNC after AzureFilesUncReviewStatus is Passed."
        }
    }
    if ([string]::IsNullOrWhiteSpace($supplied)) {
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
    if (-not (Test-NormalizedUncEquals -Left $supplied -Right $AppV2.AzureFilesUnc)) {
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

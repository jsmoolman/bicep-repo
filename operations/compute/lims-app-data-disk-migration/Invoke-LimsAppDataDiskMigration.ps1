<#
.SYNOPSIS
    Control-plane plan / stage / cleanup for migrating existing LIMS APP
    data-disk contents onto the replacement APP VM.

.DESCRIPTION
    One reusable script, driven by the reviewed environment mapping in
    LimsAppDataDiskMigration.Mapping.ps1. DEV is the only enabled
    environment; the other four are present in the mapping so they can be
    onboarded without copying this script or the pipeline.

    plan (default, read-only): resolves and reports the source disk, source
    and destination VM IDs, destination data disk, region, Disk Encryption
    Set, and candidate temporary LUN. Fails closed if any identity,
    attachment, or encryption check differs from the mapping.

    attach-and-inspect: re-runs every plan check, requires the operator
    to record whether the capture is online or application writes were
    quiesced, takes the per-environment lock, snapshots only the mapped
    source data disk, creates a temporary disk from that snapshot, and
    attaches it only to APP v2 at the validated unused LUN. Does not
    require the stage/cleanup reparse gates. Guest inspection is a
    separate Managed Run Command step; this script leaves the disk
    attached for review.

    stage: same Azure snapshot/attach path as attach-and-inspect, then
    the pipeline submits guest Robocopy. Stage remains blocked until both
    Windows reparse validations are Passed. Guest Robocopy is a separate
    Managed Run Command step in the pipeline, not this script.

    cleanup: detaches and deletes only the temporary disk created by the
    selected run, after verifying its resource ID and attachment. Snapshot
    deletion is opt-in (default retain). Never touches the original source
    disk or the destination A: data disk. Does not start APP v2 services.
    The limsAppMigCopyCompleted tag is retained so configure-app can prove
    the mapped A: copy after cleanup.

    configure-app / activate-app: destination-only Azure identity and
    completed-copy checks for the post-copy guest configuration. Does not
    snapshot, attach, or change the stage/cleanup reparse gates.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('plan', 'attach-and-inspect', 'stage', 'cleanup', 'configure-app', 'activate-app')]
    [string] $Action = 'plan',

    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'tst', 'acc', 'preprd', 'prd')]
    [string] $EnvironmentName = 'dev',

    [Parameter(Mandatory = $false)]
    [string] $MigrationRunId = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('unspecified', 'online', 'writes-quiesced')]
    [string] $CaptureMode = 'unspecified',

    [Parameter(Mandatory = $false)]
    [bool] $DeleteSnapshot = $false,

    [Parameter(Mandatory = $false)]
    [ValidateSet('', 'Pending', 'Succeeded', 'Failed', 'InspectOnly')]
    [string] $CopyStatus = '',

    [Parameter(Mandatory = $false)]
    [bool] $PreSubmitRecovery = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:MappingPath = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1'
$script:SafetyPath = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1'
if (-not (Test-Path -LiteralPath $script:MappingPath)) {
    throw [System.InvalidOperationException]::new("Reviewed environment mapping file '$script:MappingPath' was not found.")
}
if (-not (Test-Path -LiteralPath $script:SafetyPath)) {
    throw [System.InvalidOperationException]::new("Safety function file '$script:SafetyPath' was not found.")
}
. $script:MappingPath
. $script:SafetyPath

function Assert-LimsAppMigControlFailure {
    param([Parameter(Mandatory = $true)] [string] $Message)
    throw [System.InvalidOperationException]::new($Message)
}

# =============================================================================
# PURE DECISION LOGIC
# =============================================================================

function Get-ResourceNameFromId {
    param([Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return '' }
    $parts = @($ResourceId.Trim().TrimEnd('/') -split '/')
    return $parts[-1]
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

function Get-ExpectedVmResourceId {
    param([Parameter(Mandatory = $true)] $Environment, [Parameter(Mandatory = $true)] [string] $VmName)
    return "/subscriptions/$($Environment.SubscriptionId)/resourceGroups/$($Environment.ResourceGroupName)/providers/Microsoft.Compute/virtualMachines/$VmName"
}

function Get-ExpectedDiskResourceId {
    param([Parameter(Mandatory = $true)] $Environment, [Parameter(Mandatory = $true)] [string] $DiskName)
    return "/subscriptions/$($Environment.SubscriptionId)/resourceGroups/$($Environment.ResourceGroupName)/providers/Microsoft.Compute/disks/$DiskName"
}

function Get-MigrationRunResourceNames {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId
    )
    $safeRunId = $MigrationRunId.Trim()
    return [pscustomobject]@{
        SnapshotName      = "$($Environment.SnapshotNamePrefix)-$safeRunId-snap"
        # Environment-scoped name: Azure refuses a second create, which is
        # the enforceable per-environment lock shared by stage and cleanup.
        TemporaryDiskName = "$($Environment.TemporaryDiskNamePrefix)-tmp"
    }
}

function Get-DataDiskAttachmentByLun {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $DataDisks,
        [Parameter(Mandatory = $true)] [int] $Lun
    )
    $lunMatches = @($DataDisks | Where-Object { [int]$_.lun -eq $Lun })
    if ($lunMatches.Count -eq 0) { return $null }
    if ($lunMatches.Count -gt 1) {
        return [pscustomobject]@{ Ambiguous = $true; Attachments = $lunMatches }
    }
    return $lunMatches[0]
}

function Test-DiskAttachmentMatchesMapping {
    <#
        Pure: the attachment at the expected LUN must exist, name the
        expected managed disk, and not be an ambiguous multi-disk LUN.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] $Attachment,
        [Parameter(Mandatory = $true)] [string] $ExpectedDiskName,
        [Parameter(Mandatory = $true)] [string] $ExpectedDiskResourceId,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun
    )

    if ($null -eq $Attachment) {
        return [pscustomobject]@{ Matches = $false; Reason = "No data disk is attached at LUN $ExpectedLun." }
    }
    $ambiguousProperty = $Attachment.PSObject.Properties['Ambiguous']
    if ($ambiguousProperty -and $ambiguousProperty.Value) {
        return [pscustomobject]@{ Matches = $false; Reason = "LUN $ExpectedLun has more than one attached data disk; refusing to guess." }
    }

    $attachedName = [string]$Attachment.name
    if ([string]::IsNullOrWhiteSpace($attachedName) -and $Attachment.managedDisk -and $Attachment.managedDisk.id) {
        $attachedName = Get-ResourceNameFromId -ResourceId ([string]$Attachment.managedDisk.id)
    }
    if ($attachedName -ne $ExpectedDiskName) {
        return [pscustomobject]@{ Matches = $false; Reason = "LUN $ExpectedLun is attached to disk '$attachedName', not the mapped disk '$ExpectedDiskName'." }
    }

    $attachedId = ''
    if ($Attachment.managedDisk -and $Attachment.managedDisk.id) {
        $attachedId = [string]$Attachment.managedDisk.id
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $attachedId -Right $ExpectedDiskResourceId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "LUN $ExpectedLun disk resource ID '$attachedId' does not match the mapped disk '$ExpectedDiskResourceId'." }
    }

    return [pscustomobject]@{ Matches = $true; Reason = $null }
}

function Get-OccupiedDataDiskLuns {
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $DataDisks)
    return @($DataDisks | ForEach-Object { [int]$_.lun })
}

function Select-CandidateTemporaryLun {
    <#
        Pure: use the mapped preferred LUN when it is free. The only
        allowed occupant is this run's own temporary disk (resume). Never
        silently pick a different LUN.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [int[]] $OccupiedLuns,
        [Parameter(Mandatory = $true)] [int] $PreferredLun,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $DiskNameAlreadyAtPreferredLun,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $ThisRunTemporaryDiskName
    )

    $occupied = @($OccupiedLuns)
    if ($occupied -notcontains $PreferredLun) {
        return [pscustomobject]@{ Accepted = $true; Lun = $PreferredLun; Reason = $null }
    }

    $alreadyOurs = -not [string]::IsNullOrWhiteSpace($ThisRunTemporaryDiskName) -and
        -not [string]::IsNullOrWhiteSpace($DiskNameAlreadyAtPreferredLun) -and
        ($DiskNameAlreadyAtPreferredLun -eq $ThisRunTemporaryDiskName)
    if ($alreadyOurs) {
        return [pscustomobject]@{ Accepted = $true; Lun = $PreferredLun; Reason = $null }
    }

    return [pscustomobject]@{
        Accepted = $false
        Lun      = $PreferredLun
        Reason   = "Preferred temporary LUN $PreferredLun is already occupied (disk '$DiskNameAlreadyAtPreferredLun'). Refusing to pick a different LUN."
    }
}

function Test-EncryptionMatchesMapping {
    <#
        Pure: both live DES IDs must be present, equal each other, and
        equal the reviewed DES name (last segment). When RequirePin is
        true (stage, and plan after it has reported the live IDs), the
        mapping's DiskEncryptionSetResourceId must also equal that live
        ID -- an empty pin is a mapping miss, not a skip.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $SourceDiskEncryptionSetId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $DestinationDiskEncryptionSetId,
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $false)] [bool] $RequirePin = $true
    )

    if ([string]::IsNullOrWhiteSpace($SourceDiskEncryptionSetId)) {
        return [pscustomobject]@{ Matches = $false; Reason = 'Source data disk has no Disk Encryption Set ID; refusing to snapshot an unencrypted-or-unreadable disk.' }
    }
    if ([string]::IsNullOrWhiteSpace($DestinationDiskEncryptionSetId)) {
        return [pscustomobject]@{ Matches = $false; Reason = 'Destination data disk has no Disk Encryption Set ID; refusing to proceed with an encryption mismatch.' }
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $SourceDiskEncryptionSetId -Right $DestinationDiskEncryptionSetId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Source Disk Encryption Set '$SourceDiskEncryptionSetId' does not equal destination Disk Encryption Set '$DestinationDiskEncryptionSetId'." }
    }

    $liveName = Get-ResourceNameFromId -ResourceId $SourceDiskEncryptionSetId
    if ($liveName -ne $Environment.DiskEncryptionSetName) {
        return [pscustomobject]@{ Matches = $false; Reason = "Live Disk Encryption Set name '$liveName' does not match the mapped name '$($Environment.DiskEncryptionSetName)'." }
    }

    if ($RequirePin -and [string]::IsNullOrWhiteSpace([string]$Environment.DiskEncryptionSetResourceId)) {
        return [pscustomobject]@{
            Matches = $false
            Reason  = "Environment mapping DiskEncryptionSetResourceId is empty. Live Disk Encryption Set is '$SourceDiskEncryptionSetId'. Record that ID in the reviewed mapping and rerun plan before staging."
        }
    }
    if (-not $RequirePin -and [string]::IsNullOrWhiteSpace([string]$Environment.DiskEncryptionSetResourceId)) {
        return [pscustomobject]@{ Matches = $true; Reason = $null }
    }
    if (-not (Test-NormalizedResourceIdEquals -Left $SourceDiskEncryptionSetId -Right $Environment.DiskEncryptionSetResourceId)) {
        return [pscustomobject]@{ Matches = $false; Reason = "Live Disk Encryption Set '$SourceDiskEncryptionSetId' does not match the mapped pin '$($Environment.DiskEncryptionSetResourceId)'." }
    }

    return [pscustomobject]@{ Matches = $true; Reason = $null }
}

function Get-TemporaryDiskOwnerRunId {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Disk)
    if ($null -eq $Disk -or -not $Disk.tags) { return '' }
    $property = $Disk.tags.PSObject.Properties | Where-Object { $_.Name -eq 'limsAppMigLockRunId' } | Select-Object -First 1
    if ($property) { return [string]$property.Value }
    return ''
}

function Get-CleanupTargetDecision {
    <#
        Pure: cleanup may delete only a disk whose name is this run's
        temporary disk, whose ID matches the recorded ID when one was
        recorded, and which is not the source or destination data disk.
        Snapshot deletion is a separate, explicit flag.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CandidateDiskName,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $CandidateDiskId,
        [Parameter(Mandatory = $true)] [string] $ExpectedTemporaryDiskName,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $RecordedTempDiskId,
        [Parameter(Mandatory = $true)] [string] $SourceDiskResourceId,
        [Parameter(Mandatory = $true)] [string] $DestinationDataDiskResourceId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $AttachedToVmId,
        [Parameter(Mandatory = $true)] [string] $DestinationVmId
    )

    if ([string]::IsNullOrWhiteSpace($CandidateDiskName) -and [string]::IsNullOrWhiteSpace($CandidateDiskId)) {
        return [pscustomobject]@{ Allowed = $true; DiskAlreadyGone = $true; Reason = $null }
    }
    if ([string]::IsNullOrWhiteSpace($RecordedTempDiskId) -or [string]::IsNullOrWhiteSpace($CandidateDiskId)) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = 'Cleanup requires the exact recorded temporary-disk resource ID. Name-only deletion is refused.' }
    }
    if ($CandidateDiskName -ne $ExpectedTemporaryDiskName) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = "Disk '$CandidateDiskName' is not this run's temporary disk '$ExpectedTemporaryDiskName'. Refusing to detach or delete it." }
    }
    if (Test-NormalizedResourceIdEquals -Left $CandidateDiskId -Right $SourceDiskResourceId) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = 'Candidate disk ID is the original source data disk. Cleanup never touches the original disk.' }
    }
    if (Test-NormalizedResourceIdEquals -Left $CandidateDiskId -Right $DestinationDataDiskResourceId) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = 'Candidate disk ID is the destination A: data disk. Cleanup never touches the destination volume.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordedTempDiskId) -and -not (Test-NormalizedResourceIdEquals -Left $CandidateDiskId -Right $RecordedTempDiskId)) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = "Live temporary disk ID '$CandidateDiskId' does not match the recorded ID '$RecordedTempDiskId' for this run." }
    }
    if (-not [string]::IsNullOrWhiteSpace($AttachedToVmId) -and -not (Test-NormalizedResourceIdEquals -Left $AttachedToVmId -Right $DestinationVmId)) {
        return [pscustomobject]@{ Allowed = $false; DiskAlreadyGone = $false; Reason = "Temporary disk is attached to '$AttachedToVmId', not the destination VM '$DestinationVmId'. Refusing to detach it from the wrong VM." }
    }

    return [pscustomobject]@{ Allowed = $true; DiskAlreadyGone = $false; Reason = $null }
}

function Assert-EnvironmentEnabledAndComplete {
    param([Parameter(Mandatory = $true)] $Environment)

    if (-not $Environment.Enabled) {
        Assert-LimsAppMigControlFailure "Environment '$($Environment.EnvironmentName)' is present in the reviewed mapping but is not enabled. Fill the reviewed values and set Enabled = `$true to onboard it; do not duplicate the pipeline or scripts."
    }

    $requiredStrings = @(
        'SubscriptionId', 'Location', 'ResourceGroupName',
        'SourceVmName', 'SourceDataDiskName',
        'DestinationVmName', 'DestinationComputerName', 'DestinationDataDiskName',
        'DestinationDriveLetter', 'DestinationVolumeLabel',
        'PreferredTemporaryDriveLetter', 'DiskEncryptionSetName',
        'SnapshotNamePrefix', 'TemporaryDiskNamePrefix',
        'DestinationAttestedGuestUniqueId', 'GuestCommandNamePrefix',
        'WindowsReparseValidationStatus', 'WindowsSymlinkValidationStatus'
    )
    foreach ($name in $requiredStrings) {
        $value = [string]$Environment.$name
        if ([string]::IsNullOrWhiteSpace($value)) {
            Assert-LimsAppMigControlFailure "Enabled environment '$($Environment.EnvironmentName)' is missing required mapping field '$name'."
        }
    }
    if ([int]$Environment.SourceDataDiskLun -lt 0 -or [int]$Environment.DestinationDataDiskLun -lt 0 -or [int]$Environment.PreferredTemporaryLun -lt 0) {
        Assert-LimsAppMigControlFailure "Enabled environment '$($Environment.EnvironmentName)' has an unmapped LUN (source, destination, or preferred temporary)."
    }
    if (-not $Environment.AppV2) {
        Assert-LimsAppMigControlFailure "Enabled environment '$($Environment.EnvironmentName)' is missing the AppV2 configuration mapping."
    }
    foreach ($name in @('JbossRunnerUserName', 'JbossServiceName', 'ApacheServiceName', 'ShibbolethServiceName', 'AzureFilesStartupTaskName', 'ConfigureGuestCommandPrefix', 'ActivateGuestCommandPrefix')) {
        if ([string]::IsNullOrWhiteSpace([string]$Environment.AppV2.$name)) {
            Assert-LimsAppMigControlFailure "Enabled environment '$($Environment.EnvironmentName)' is missing required AppV2 mapping field '$name'."
        }
    }
}

function Get-CaptureModeDecision {
    param([Parameter(Mandatory = $true)] [string] $CaptureMode)

    if ($CaptureMode -eq 'online' -or $CaptureMode -eq 'writes-quiesced') {
        return [pscustomobject]@{ Accepted = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Accepted = $false
        Reason   = "CaptureMode must be recorded as 'online' or 'writes-quiesced' before stage or attach-and-inspect. '$CaptureMode' is not an approved capture record."
    }
}

# =============================================================================
# ADAPTERS -- the only functions that invoke az. Mocked in Pester.
# =============================================================================

function Invoke-AzCliAdapter {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Arguments,
        [Parameter(Mandatory = $false)] [switch] $ExpectJson
    )

    $raw = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($raw | Out-String)
    if ($exitCode -ne 0) {
        Assert-LimsAppMigControlFailure "Azure CLI command 'az $($Arguments -join ' ')' failed (exit $exitCode): $text"
    }
    if ($ExpectJson) {
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    }
    return $text.Trim()
}

function Get-AzVmAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $VmName
    )
    return Invoke-AzCliAdapter -ExpectJson -Arguments @(
        'vm', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $VmName,
        '--output', 'json'
    )
}

function Get-AzDiskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName
    )
    return Invoke-AzCliAdapter -ExpectJson -Arguments @(
        'disk', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DiskName,
        '--output', 'json'
    )
}

function Invoke-AzCliLookupAdapter {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $raw = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($raw | Out-String)
    $classification = Get-AzureCliErrorClassification -ExitCode $exitCode -Text $text
    $resource = $null
    if ($classification -eq 'Found' -and -not [string]::IsNullOrWhiteSpace($text)) {
        $resource = $text | ConvertFrom-Json
    }
    return [pscustomobject]@{
        Classification = $classification
        Resource       = $resource
        Text           = $text
        ExitCode       = $exitCode
    }
}

function Get-AzDiskLookupAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName
    )
    return Invoke-AzCliLookupAdapter -Arguments @(
        'disk', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DiskName,
        '--output', 'json'
    )
}

function Get-AzSnapshotLookupAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SnapshotName
    )
    return Invoke-AzCliLookupAdapter -Arguments @(
        'snapshot', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $SnapshotName,
        '--output', 'json'
    )
}

function Get-AzRunCommandLookupAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RunCommandName
    )
    return Invoke-AzCliLookupAdapter -Arguments @(
        'vm', 'run-command', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--vm-name', $VmName,
        '--name', $RunCommandName,
        '--instance-view',
        '--output', 'json'
    )
}

function New-AzIncrementalSnapshotAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SnapshotName,
        [Parameter(Mandatory = $true)] [string] $SourceDiskId,
        [Parameter(Mandatory = $true)] [string] $Location,
        [Parameter(Mandatory = $true)] [string] $DiskEncryptionSetId
    )
    return Invoke-AzCliAdapter -ExpectJson -Arguments @(
        'snapshot', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $SnapshotName,
        '--source', $SourceDiskId,
        '--location', $Location,
        '--incremental', 'true',
        '--disk-encryption-set', $DiskEncryptionSetId,
        '--output', 'json'
    )
}

function New-AzDiskFromSnapshotAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName,
        [Parameter(Mandatory = $true)] [string] $SnapshotId,
        [Parameter(Mandatory = $true)] [string] $Location,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Zone,
        [Parameter(Mandatory = $false)] [hashtable] $Tags
    )
    $arguments = @(
        'disk', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DiskName,
        '--source', $SnapshotId,
        '--location', $Location,
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
    return Invoke-AzCliLookupAdapter -Arguments $arguments
}

function Add-AzVmDataDiskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $DiskName,
        [Parameter(Mandatory = $true)] [int] $Lun
    )
    return Invoke-AzCliAdapter -Arguments @(
        'vm', 'disk', 'attach',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--vm-name', $VmName,
        '--name', $DiskName,
        '--lun', ([string]$Lun),
        '--caching', 'None'
    )
}

function Remove-AzVmDataDiskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $DiskName
    )
    return Invoke-AzCliAdapter -Arguments @(
        'vm', 'disk', 'detach',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--vm-name', $VmName,
        '--name', $DiskName
    )
}

function Remove-AzDiskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName
    )
    return Invoke-AzCliAdapter -Arguments @(
        'disk', 'delete',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DiskName,
        '--yes'
    )
}

function Remove-AzSnapshotAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SnapshotName
    )
    return Invoke-AzCliAdapter -Arguments @(
        'snapshot', 'delete',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $SnapshotName,
        '--yes'
    )
}

function Set-AzResourceTagsMergeAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceId,
        [Parameter(Mandatory = $true)] [hashtable] $Tags
    )
    $arguments = @(
        'tag', 'update',
        '--resource-id', $ResourceId,
        '--operation', 'Merge',
        '--tags'
    )
    foreach ($key in $Tags.Keys) {
        $arguments += "$key=$($Tags[$key])"
    }
    return Invoke-AzCliAdapter -Arguments $arguments
}

function Remove-AzResourceTagsAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceId,
        [Parameter(Mandatory = $true)] [string[]] $TagKeys
    )
    $arguments = @(
        'tag', 'update',
        '--resource-id', $ResourceId,
        '--operation', 'Delete',
        '--tags'
    )
    $arguments += $TagKeys
    return Invoke-AzCliAdapter -Arguments $arguments
}

function Set-AzVmTagsIfMatchAdapter {
    <#
        Atomic destination-VM tag write. If-Match is required; disk
        create-or-update is not exclusive and is not used as a lock.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceId,
        [Parameter(Mandatory = $true)] [string] $IfMatch,
        [Parameter(Mandatory = $true)] [hashtable] $Tags
    )
    $body = (@{ tags = $Tags } | ConvertTo-Json -Compress -Depth 5)
    return Invoke-AzCliLookupAdapter -Arguments @(
        'rest',
        '--method', 'patch',
        '--uri', ($ResourceId + '?api-version=2024-07-01'),
        '--headers', "If-Match=$IfMatch",
        '--body', $body,
        '--output', 'json'
    )
}

function Remove-AzRunCommandAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RunCommandName
    )
    return Invoke-AzCliAdapter -Arguments @(
        'vm', 'run-command', 'delete',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--vm-name', $VmName,
        '--name', $RunCommandName,
        '--yes'
    )
}

function ConvertTo-TagHashtable {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Tags)

    $hash = @{}
    if ($null -eq $Tags) { return $hash }
    if ($Tags -is [hashtable]) {
        foreach ($key in $Tags.Keys) {
            $hash[[string]$key] = [string]$Tags[$key]
        }
        return $hash
    }
    foreach ($property in @($Tags.PSObject.Properties)) {
        $hash[[string]$property.Name] = [string]$property.Value
    }
    return $hash
}

function Get-ResourceEtag {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Resource)

    if ($null -eq $Resource) { return '' }
    foreach ($name in @('etag', 'Etag', 'eTag')) {
        $property = $Resource.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ''
}

function Test-LimsAppMigEnvFlag {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return ($value -eq 'true' -or $value -eq 'True' -or $value -eq '1')
}

function Invoke-LimsAppDataDiskMigrationAcquireEnvironmentLock {
    param(
        [Parameter(Mandatory = $true)] $Checks,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [ValidateSet('Stage', 'AttachAndInspect')] [string] $LockPurpose,
        [Parameter(Mandatory = $true)] $TagKeys,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $CopyStatus = ''
    )

    $etag = Get-ResourceEtag -Resource $Checks.DestinationVm
    if ([string]::IsNullOrWhiteSpace($etag)) {
        Assert-LimsAppMigControlFailure "Destination VM '$($Checks.DestinationVmId)' has no etag. Refusing to acquire the environment lock without If-Match."
    }
    $owner = Get-VmTagValue -Vm $Checks.DestinationVm -Key $TagKeys.RunId
    $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $owner -ThisRunId $MigrationRunId -Purpose $LockPurpose
    if (-not $lockDecision.Allowed) {
        Assert-LimsAppMigControlFailure $lockDecision.Reason
    }

    $merged = ConvertTo-TagHashtable -Tags $Checks.DestinationVm.tags
    $merged[$TagKeys.RunId] = $MigrationRunId
    $merged[$TagKeys.GuestSubmitted] = 'false'
    $merged[$TagKeys.Phase] = 'LockHeld'
    if ($CopyStatus) { $merged[$TagKeys.CopyStatus] = $CopyStatus }
    Write-OperatorLog "Acquiring the destination-VM environment lock for run '$MigrationRunId' with If-Match (disk create is not exclusive)."
    $apply = Set-AzVmTagsIfMatchAdapter -ResourceId $Checks.DestinationVmId -IfMatch $etag -Tags $merged
    $applyDecision = Get-AtomicLockApplyDecision -Classification $apply.Classification
    if (-not $applyDecision.Allowed) {
        Assert-LimsAppMigControlFailure $applyDecision.Reason
    }
}

# =============================================================================
# ORCHESTRATION
# =============================================================================

function Assert-VmIdentityMatchesMapping {
    param(
        [Parameter(Mandatory = $true)] $Vm,
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $ExpectedVmName,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    $expectedId = Get-ExpectedVmResourceId -Environment $Environment -VmName $ExpectedVmName
    if ($Vm.name -ne $ExpectedVmName) {
        Assert-LimsAppMigControlFailure "$Role VM name '$($Vm.name)' does not match the mapped name '$ExpectedVmName'."
    }
    if (-not (Test-NormalizedResourceIdEquals -Left ([string]$Vm.id) -Right $expectedId)) {
        Assert-LimsAppMigControlFailure "$Role VM resource ID '$($Vm.id)' does not match the mapped ID '$expectedId'."
    }
    if ([string]$Vm.location -ne $Environment.Location) {
        Assert-LimsAppMigControlFailure "$Role VM location '$($Vm.location)' does not match the mapped region '$($Environment.Location)'."
    }
}

function Assert-DiskIdentityMatchesMapping {
    param(
        [Parameter(Mandatory = $true)] $Disk,
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $ExpectedDiskName,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    $expectedId = Get-ExpectedDiskResourceId -Environment $Environment -DiskName $ExpectedDiskName
    if ($Disk.name -ne $ExpectedDiskName) {
        Assert-LimsAppMigControlFailure "$Role disk name '$($Disk.name)' does not match the mapped name '$ExpectedDiskName'."
    }
    if (-not (Test-NormalizedResourceIdEquals -Left ([string]$Disk.id) -Right $expectedId)) {
        Assert-LimsAppMigControlFailure "$Role disk resource ID '$($Disk.id)' does not match the mapped ID '$expectedId'."
    }
    if ([string]$Disk.location -ne $Environment.Location) {
        Assert-LimsAppMigControlFailure "$Role disk location '$($Disk.location)' does not match the mapped region '$($Environment.Location)'."
    }
}

function Get-VmZoneDecision {
    <#
        Pure: read VM.zones only after confirming the property exists.
        Omitted, null, or empty means regional (no --zone). A single
        canonical Azure zone is preserved. Multiple or malformed values
        are rejected before any write.
    #>
    param([Parameter(Mandatory = $true)] $Vm)

    $zonesProperty = $Vm.PSObject.Properties['zones']
    if ($null -eq $zonesProperty) {
        return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
    }

    $raw = $zonesProperty.Value
    if ($null -eq $raw) {
        return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
    }

    if ($raw -is [string] -or $raw -is [ValueType]) {
        $text = [string]$raw
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
        }
        return Resolve-SingleVmZoneValue -Value $raw
    }

    $items = @($raw)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
    }
    if ($items.Count -gt 1) {
        $shown = ($items | ForEach-Object { [string]$_ }) -join ', '
        return [pscustomobject]@{
            Accepted = $false
            Regional = $false
            Zone     = ''
            Reason   = "Destination VM reports more than one availability zone ($shown). Refusing to guess which zone to use for the temporary disk."
        }
    }
    return Resolve-SingleVmZoneValue -Value $items[0]
}

function Resolve-SingleVmZoneValue {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Value)

    if ($null -eq $Value) {
        return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return [pscustomobject]@{
            Accepted = $false
            Regional = $false
            Zone     = ''
            Reason   = 'Destination VM zone value is nested or structured rather than a single zone string. Refusing to create a temporary disk.'
        }
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ Accepted = $true; Regional = $true; Zone = ''; Reason = $null }
    }
    if ($text.Trim() -ne $text) {
        return [pscustomobject]@{
            Accepted = $false
            Regional = $false
            Zone     = ''
            Reason   = "Destination VM zone '$text' is malformed (leading or trailing whitespace). Refusing to create a temporary disk."
        }
    }
    if ($text -notmatch '^[1-9][0-9]*$') {
        return [pscustomobject]@{
            Accepted = $false
            Regional = $false
            Zone     = ''
            Reason   = "Destination VM zone '$text' is not a canonical Azure availability zone. Refusing to create a temporary disk."
        }
    }
    return [pscustomobject]@{ Accepted = $true; Regional = $false; Zone = $text; Reason = $null }
}

function Get-DiskEncryptionSetIdFromDisk {
    param([Parameter(Mandatory = $true)] $Disk)
    if ($Disk.encryption -and $Disk.encryption.diskEncryptionSetId) {
        return [string]$Disk.encryption.diskEncryptionSetId
    }
    return ''
}

function Get-VmTagValue {
    param(
        [Parameter(Mandatory = $true)] $Vm,
        [Parameter(Mandatory = $true)] [string] $Key
    )
    if (-not $Vm.tags) { return '' }
    $tags = $Vm.tags
    $property = $tags.PSObject.Properties | Where-Object { $_.Name -eq $Key } | Select-Object -First 1
    if ($property) { return [string]$property.Value }
    return ''
}

function Invoke-LimsAppDataDiskMigrationPlanChecks {
    <#
        Shared identity / attachment / encryption / LUN resolution used by
        plan (report only) and stage (before any mutation).
    #>
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $ThisRunTemporaryDiskName,
        [Parameter(Mandatory = $false)] [bool] $RequireEncryptionPin = $true
    )

    $sourceVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.SourceVmName
    $destinationVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName
    Assert-VmIdentityMatchesMapping -Vm $sourceVm -Environment $Environment -ExpectedVmName $Environment.SourceVmName -Role 'Source'
    Assert-VmIdentityMatchesMapping -Vm $destinationVm -Environment $Environment -ExpectedVmName $Environment.DestinationVmName -Role 'Destination'

    $sourceDisks = @()
    if ($sourceVm.storageProfile -and $sourceVm.storageProfile.dataDisks) {
        $sourceDisks = @($sourceVm.storageProfile.dataDisks)
    }
    $destinationDisks = @()
    if ($destinationVm.storageProfile -and $destinationVm.storageProfile.dataDisks) {
        $destinationDisks = @($destinationVm.storageProfile.dataDisks)
    }

    $sourceAttachment = Get-DataDiskAttachmentByLun -DataDisks $sourceDisks -Lun ([int]$Environment.SourceDataDiskLun)
    $sourceAttachmentCheck = Test-DiskAttachmentMatchesMapping -Attachment $sourceAttachment -ExpectedDiskName $Environment.SourceDataDiskName -ExpectedDiskResourceId (Get-ExpectedDiskResourceId -Environment $Environment -DiskName $Environment.SourceDataDiskName) -ExpectedLun ([int]$Environment.SourceDataDiskLun)
    if (-not $sourceAttachmentCheck.Matches) {
        Assert-LimsAppMigControlFailure "Source attachment check failed: $($sourceAttachmentCheck.Reason)"
    }

    $destinationAttachment = Get-DataDiskAttachmentByLun -DataDisks $destinationDisks -Lun ([int]$Environment.DestinationDataDiskLun)
    $destinationAttachmentCheck = Test-DiskAttachmentMatchesMapping -Attachment $destinationAttachment -ExpectedDiskName $Environment.DestinationDataDiskName -ExpectedDiskResourceId (Get-ExpectedDiskResourceId -Environment $Environment -DiskName $Environment.DestinationDataDiskName) -ExpectedLun ([int]$Environment.DestinationDataDiskLun)
    if (-not $destinationAttachmentCheck.Matches) {
        Assert-LimsAppMigControlFailure "Destination attachment check failed: $($destinationAttachmentCheck.Reason)"
    }

    $sourceDisk = Get-AzDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $Environment.SourceDataDiskName
    $destinationDisk = Get-AzDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $Environment.DestinationDataDiskName
    Assert-DiskIdentityMatchesMapping -Disk $sourceDisk -Environment $Environment -ExpectedDiskName $Environment.SourceDataDiskName -Role 'Source'
    Assert-DiskIdentityMatchesMapping -Disk $destinationDisk -Environment $Environment -ExpectedDiskName $Environment.DestinationDataDiskName -Role 'Destination'

    $sourceDes = Get-DiskEncryptionSetIdFromDisk -Disk $sourceDisk
    $destinationDes = Get-DiskEncryptionSetIdFromDisk -Disk $destinationDisk
    $encryptionCheck = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId $sourceDes -DestinationDiskEncryptionSetId $destinationDes -Environment $Environment -RequirePin $RequireEncryptionPin
    if (-not $encryptionCheck.Matches) {
        Assert-LimsAppMigControlFailure "Encryption check failed: $($encryptionCheck.Reason)"
    }

    $occupiedLuns = Get-OccupiedDataDiskLuns -DataDisks $destinationDisks
    $diskAtPreferred = Get-DataDiskAttachmentByLun -DataDisks $destinationDisks -Lun ([int]$Environment.PreferredTemporaryLun)
    $nameAtPreferred = $null
    $preferredIsAmbiguous = $false
    if ($diskAtPreferred) {
        $preferredAmbiguousProperty = $diskAtPreferred.PSObject.Properties['Ambiguous']
        $preferredIsAmbiguous = [bool]($preferredAmbiguousProperty -and $preferredAmbiguousProperty.Value)
    }
    if ($diskAtPreferred -and -not $preferredIsAmbiguous) {
        $nameAtPreferred = [string]$diskAtPreferred.name
        if ([string]::IsNullOrWhiteSpace($nameAtPreferred) -and $diskAtPreferred.managedDisk) {
            $nameAtPreferred = Get-ResourceNameFromId -ResourceId ([string]$diskAtPreferred.managedDisk.id)
        }
    }
    $lunSelection = Select-CandidateTemporaryLun -OccupiedLuns $occupiedLuns -PreferredLun ([int]$Environment.PreferredTemporaryLun) -DiskNameAlreadyAtPreferredLun $nameAtPreferred -ThisRunTemporaryDiskName $ThisRunTemporaryDiskName
    if (-not $lunSelection.Accepted) {
        Assert-LimsAppMigControlFailure $lunSelection.Reason
    }

    $zoneDecision = Get-VmZoneDecision -Vm $destinationVm
    if (-not $zoneDecision.Accepted) {
        Assert-LimsAppMigControlFailure $zoneDecision.Reason
    }

    return [pscustomobject]@{
        SourceVm                  = $sourceVm
        DestinationVm             = $destinationVm
        SourceDisk                = $sourceDisk
        DestinationDisk           = $destinationDisk
        SourceVmId                = [string]$sourceVm.id
        DestinationVmId           = [string]$destinationVm.id
        SourceDiskId              = [string]$sourceDisk.id
        DestinationDiskId         = [string]$destinationDisk.id
        Location                  = $Environment.Location
        Zone                      = $zoneDecision.Zone
        DiskEncryptionSetId       = $sourceDes
        CandidateTemporaryLun          = [int]$lunSelection.Lun
        OccupiedLuns                   = $occupiedLuns
        DestinationDataDisks           = $destinationDisks
        DestinationDiskUniqueId        = Get-DiskUniqueIdFromResource -Disk $destinationDisk
        SourceDiskUniqueId             = Get-DiskUniqueIdFromResource -Disk $sourceDisk
    }
}

function Write-OperatorLog {
    <#
        Operator-facing lines for the pipeline log. Must not use the
        success stream: the script entry point discards structured
        return values with Out-Null.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Message)
    Write-Host $Message
}

function Write-LimsAppDataDiskMigrationPlanSummary {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] $Checks
    )

    $occupied = @($Checks.OccupiedLuns)
    $candidate = [int]$Checks.CandidateTemporaryLun
    if ($occupied -contains $candidate) {
        $lunAvailability = "available on APP v2 for this run (LUN $candidate is occupied only by this run's own temporary disk)"
    }
    else {
        $lunAvailability = "available on APP v2 (LUN $candidate is not occupied)"
    }

    Write-OperatorLog '===== LIMS APP data-disk migration: PLAN ====='
    Write-OperatorLog "Environment                 : $($Environment.EnvironmentName) (enabled=$($Environment.Enabled))"
    Write-OperatorLog "Subscription                : $($Environment.SubscriptionId)"
    Write-OperatorLog "Region                      : $($Checks.Location)"
    Write-OperatorLog "Legacy APP VM               : $($Checks.SourceVmId)"
    Write-OperatorLog "Source data disk            : $($Checks.SourceDiskId) (LUN $($Environment.SourceDataDiskLun), name $($Environment.SourceDataDiskName))"
    Write-OperatorLog "APP v2 VM                   : $($Checks.DestinationVmId)"
    Write-OperatorLog "Destination data disk       : $($Checks.DestinationDiskId) (LUN $($Environment.DestinationDataDiskLun))"
    Write-OperatorLog "Expected guest volume       : $($Environment.DestinationDriveLetter): labeled '$($Environment.DestinationVolumeLabel)' (expected guest values; plan verified Azure disk identity and LUN attachment only)"
    Write-OperatorLog "Verified Disk Encryption Set: $($Checks.DiskEncryptionSetId)"
    Write-OperatorLog "Candidate temporary LUN     : $candidate ($lunAvailability)"
    Write-OperatorLog "Preferred temp drive letter : $($Environment.PreferredTemporaryDriveLetter): (expected guest value; not verified by plan)"
    Write-OperatorLog "Exclude relative paths      : $($Environment.ExcludeRelativePaths -join ', ')"
    Write-OperatorLog 'Original source disk and destination A: are not modified by plan.'
    Write-OperatorLog '=============================================='
}

function Write-PipelineVariable {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value
    )
    $safe = Test-LimsAppMigPipelineSafeValue -Name $Name -Value $Value
    if (-not $safe.Accepted) {
        Assert-LimsAppMigControlFailure $safe.Reason
    }
    Write-OperatorLog "##vso[task.setvariable variable=$Name]$Value"
}

function Assert-LookupFoundOrGone {
    param(
        [Parameter(Mandatory = $true)] $Lookup,
        [Parameter(Mandatory = $true)] [string] $Role
    )
    if ($Lookup.Classification -eq 'Found' -or $Lookup.Classification -eq 'NotFound') {
        return
    }
    Assert-LimsAppMigControlFailure "$Role lookup classified as '$($Lookup.Classification)' (not a confirmed Found or NotFound). Refusing to treat this as missing. $($Lookup.Text)"
}

function Get-DiskUniqueIdFromResource {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Disk)
    if ($null -eq $Disk) { return '' }
    if ($Disk.PSObject.Properties['uniqueId'] -and $Disk.uniqueId) { return [string]$Disk.uniqueId }
    if ($Disk.PSObject.Properties['uniqueID'] -and $Disk.uniqueID) { return [string]$Disk.uniqueID }
    return ''
}

function Get-CreationSourceId {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Resource)
    if ($null -eq $Resource) { return '' }
    if ($Resource.creationData -and $Resource.creationData.sourceResourceId) {
        return [string]$Resource.creationData.sourceResourceId
    }
    return ''
}

function Get-RunCommandExecutionState {
    param([Parameter(Mandatory = $false)] [AllowNull()] $Resource)
    if ($null -eq $Resource) { return '' }
    if ($Resource.instanceView -and $Resource.instanceView.executionState) {
        return [string]$Resource.instanceView.executionState
    }
    if ($Resource.executionState) { return [string]$Resource.executionState }
    return ''
}

function Invoke-LimsAppDataDiskMigrationPlan {
    param([Parameter(Mandatory = $true)] $Environment)

    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -RequireEncryptionPin $true
    Write-LimsAppDataDiskMigrationPlanSummary -Environment $Environment -Checks $checks
    Write-PipelineVariable -Name 'limsAppMigSubscriptionId' -Value $Environment.SubscriptionId
    Write-PipelineVariable -Name 'limsAppMigResourceGroupName' -Value $Environment.ResourceGroupName
    Write-PipelineVariable -Name 'limsAppMigDestinationVmName' -Value $Environment.DestinationVmName
    Write-PipelineVariable -Name 'limsAppMigDestinationComputerName' -Value $Environment.DestinationComputerName
    Write-PipelineVariable -Name 'limsAppMigTemporaryLun' -Value ([string]$checks.CandidateTemporaryLun)
    Write-PipelineVariable -Name 'limsAppMigDiskEncryptionSetId' -Value $checks.DiskEncryptionSetId
    Write-PipelineVariable -Name 'limsAppMigSourceVmId' -Value $checks.SourceVmId
    Write-PipelineVariable -Name 'limsAppMigDestinationVmId' -Value $checks.DestinationVmId
    Write-PipelineVariable -Name 'limsAppMigSourceDiskId' -Value $checks.SourceDiskId
    Write-PipelineVariable -Name 'limsAppMigDestinationDiskId' -Value $checks.DestinationDiskId
    return $checks
}

function Invoke-LimsAppDataDiskMigrationAcquireSnapshotAndAttach {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $CaptureMode,
        [Parameter(Mandatory = $true)] [ValidateSet('Stage', 'AttachAndInspect')] [string] $LockPurpose,
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $CopyStatus,
        [Parameter(Mandatory = $true)] [string] $OperatorTitle
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }
    $captureDecision = Get-CaptureModeDecision -CaptureMode $CaptureMode
    if (-not $captureDecision.Accepted) {
        Assert-LimsAppMigControlFailure $captureDecision.Reason
    }

    $names = Get-MigrationRunResourceNames -Environment $Environment -MigrationRunId $MigrationRunId
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $guestCommandName = Get-LimsAppDataDiskMigrationRunCommandName -Environment $Environment -MigrationRunId $MigrationRunId
    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -ThisRunTemporaryDiskName $names.TemporaryDiskName

    if ([string]::IsNullOrWhiteSpace($checks.DestinationDiskUniqueId)) {
        Assert-LimsAppMigControlFailure "Destination disk '$($checks.DestinationDiskId)' has no ARM uniqueId. Guest identity cannot be proven. Evidence needed: Microsoft.Compute/disks uniqueId."
    }
    if (-not (Test-NormalizedUniqueIdEquals -Left $checks.DestinationDiskUniqueId -Right $Environment.DestinationAttestedGuestUniqueId)) {
        Assert-LimsAppMigControlFailure "Destination ARM uniqueId '$($checks.DestinationDiskUniqueId)' does not match the attested guest UniqueId '$($Environment.DestinationAttestedGuestUniqueId)'."
    }

    Invoke-LimsAppDataDiskMigrationAcquireEnvironmentLock -Checks $checks -MigrationRunId $MigrationRunId -LockPurpose $LockPurpose -TagKeys $tagKeys -CopyStatus $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })

    $tempLookup = Get-AzDiskLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    Assert-LookupFoundOrGone -Lookup $tempLookup -Role 'Temporary disk'

    $snapshot = $null
    $tempDisk = $null

    if ($tempLookup.Classification -eq 'Found') {
        $tempDisk = $tempLookup.Resource
        $owner = Get-TemporaryDiskOwnerRunId -Disk $tempDisk
        if ([string]::IsNullOrWhiteSpace($owner)) {
            Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' exists without limsAppMigLockRunId. Refusing to reuse or steal the environment lock. Evidence needed: lock-owner tag set at create."
        }
        $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $owner -ThisRunId $MigrationRunId -Purpose $LockPurpose
        if (-not $lockDecision.Allowed) {
            Assert-LimsAppMigControlFailure $lockDecision.Reason
        }
        Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' already holds the environment lock for run '$owner'. Overlapping migration attempts are refused even with the same run ID. Wait for the in-flight attempt, then run cleanup after the guest command is Found and terminal."
    }
    else {
        $snapshotLookup = Get-AzSnapshotLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
        Assert-LookupFoundOrGone -Lookup $snapshotLookup -Role 'Snapshot'
        $snapshot = $snapshotLookup.Resource
        if ($snapshotLookup.Classification -eq 'Found') {
            if (-not (Test-NormalizedResourceIdEquals -Left (Get-CreationSourceId -Resource $snapshot) -Right $checks.SourceDiskId)) {
                Assert-LimsAppMigControlFailure "Existing snapshot '$($snapshot.id)' was created from '$(Get-CreationSourceId -Resource $snapshot)', not the original source disk '$($checks.SourceDiskId)'."
            }
            Write-OperatorLog "Reusing incremental snapshot '$($snapshot.id)' from this run."
        }
        else {
            Write-OperatorLog "Creating incremental snapshot '$($names.SnapshotName)' of source disk '$($checks.SourceDiskId)' (capture mode: $CaptureMode). Legacy APP is not modified."
            $snapshot = New-AzIncrementalSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName -SourceDiskId $checks.SourceDiskId -Location $checks.Location -DiskEncryptionSetId $checks.DiskEncryptionSetId
        }

        Write-OperatorLog "Creating temporary disk '$($names.TemporaryDiskName)' from snapshot '$($snapshot.id)' after the destination-VM lock is held."
        $createResult = New-AzDiskFromSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName -SnapshotId ([string]$snapshot.id) -Location $checks.Location -Zone $checks.Zone -Tags @{
            limsAppMigLockRunId  = $MigrationRunId
            limsAppMigSnapshotId = [string]$snapshot.id
        }
        if ($createResult.Classification -eq 'AlreadyExists') {
            $conflictLookup = Get-AzDiskLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
            Assert-LookupFoundOrGone -Lookup $conflictLookup -Role 'Temporary disk after create conflict'
            if ($conflictLookup.Classification -ne 'Found') {
                Assert-LimsAppMigControlFailure "Temporary disk create reported AlreadyExists but lookup is '$($conflictLookup.Classification)'. Refusing to continue without a proven lock owner."
            }
            $tempDisk = $conflictLookup.Resource
            $owner = Get-TemporaryDiskOwnerRunId -Disk $tempDisk
            if ([string]::IsNullOrWhiteSpace($owner)) {
                Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' exists without limsAppMigLockRunId after a create conflict. Refusing to steal the lock."
            }
            $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $owner -ThisRunId $MigrationRunId -Purpose $LockPurpose
            if (-not $lockDecision.Allowed) {
                Assert-LimsAppMigControlFailure $lockDecision.Reason
            }
            Assert-LimsAppMigControlFailure "Temporary disk create collided with '$($tempDisk.id)' owned by run '$owner'. Overlapping migration attempts are refused even with the same run ID. Wait for the in-flight attempt, then run cleanup after the guest command is Found and terminal."
        }
        elseif ($createResult.Classification -eq 'Found') {
            $tempDisk = $createResult.Resource
        }
        else {
            Assert-LimsAppMigControlFailure "Temporary disk create classified as '$($createResult.Classification)'. $($createResult.Text)"
        }
    }

    $tempUniqueId = Get-DiskUniqueIdFromResource -Disk $tempDisk
    if ([string]::IsNullOrWhiteSpace($tempUniqueId)) {
        Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' has no ARM uniqueId. Refusing to attach or change guest disk state. Collect a read-only guest disk inventory only after ARM uniqueId is present; binding is ARM uniqueId matching Get-Disk UniqueId. Evidence needed: Microsoft.Compute/disks uniqueId."
    }

    $attachedAlready = $false
    foreach ($attached in @($checks.DestinationDataDisks)) {
        $attachedId = ''
        if ($attached.managedDisk -and $attached.managedDisk.id) { $attachedId = [string]$attached.managedDisk.id }
        if (Test-NormalizedResourceIdEquals -Left $attachedId -Right ([string]$tempDisk.id)) {
            if ([int]$attached.lun -ne [int]$checks.CandidateTemporaryLun) {
                Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' is attached at LUN $($attached.lun), not the validated LUN $($checks.CandidateTemporaryLun)."
            }
            $attachedAlready = $true
        }
    }
    if (-not $attachedAlready) {
        Write-OperatorLog "Attaching temporary disk '$($names.TemporaryDiskName)' to '$($Environment.DestinationVmName)' at LUN $($checks.CandidateTemporaryLun) only. Legacy APP and both SQL VMs are outside every VM write."
        Add-AzVmDataDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -DiskName $names.TemporaryDiskName -Lun ([int]$checks.CandidateTemporaryLun)
    }

    $effectiveCopyStatus = $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })
    $recordTags = @{
        $tagKeys.RunId            = $MigrationRunId
        $tagKeys.SnapshotId       = [string]$snapshot.id
        $tagKeys.TempDiskId       = [string]$tempDisk.id
        $tagKeys.TempDiskUniqueId = $tempUniqueId
        $tagKeys.DestDiskUniqueId = $checks.DestinationDiskUniqueId
        $tagKeys.CaptureMode      = $CaptureMode
        $tagKeys.CopyStatus       = $effectiveCopyStatus
        $tagKeys.TemporaryLun     = [string]$checks.CandidateTemporaryLun
        $tagKeys.GuestCommand     = $guestCommandName
        $tagKeys.Phase            = $Phase
    }
    if ($effectiveCopyStatus -eq 'InspectOnly') {
        $recordTags[$tagKeys.GuestSubmitted] = 'false'
        $recordTags[$tagKeys.AttemptState] = 'Prepared'
    }
    Set-AzResourceTagsMergeAdapter -ResourceId $checks.DestinationVmId -Tags $recordTags

    Write-OperatorLog "===== LIMS APP data-disk migration: $OperatorTitle ====="
    Write-OperatorLog "Migration run ID            : $MigrationRunId"
    Write-OperatorLog "Capture mode                : $CaptureMode"
    Write-OperatorLog "Snapshot                    : $($snapshot.id)"
    Write-OperatorLog "Temporary disk              : $($tempDisk.id)"
    Write-OperatorLog "Attached to                 : $($checks.DestinationVmId) at LUN $($checks.CandidateTemporaryLun)"
    Write-OperatorLog "Copy status                 : $effectiveCopyStatus"
    Write-OperatorLog 'Legacy APP VM/disk          : read-only (snapshot source only)'
    Write-OperatorLog 'SQL VMs and Azure Files     : out of scope'
    Write-OperatorLog '======================================================='

    Write-PipelineVariable -Name 'limsAppMigSubscriptionId' -Value $Environment.SubscriptionId
    Write-PipelineVariable -Name 'limsAppMigResourceGroupName' -Value $Environment.ResourceGroupName
    Write-PipelineVariable -Name 'limsAppMigDestinationVmName' -Value $Environment.DestinationVmName
    Write-PipelineVariable -Name 'limsAppMigTemporaryLun' -Value ([string]$checks.CandidateTemporaryLun)
    Write-PipelineVariable -Name 'limsAppMigTemporaryDiskName' -Value $names.TemporaryDiskName
    Write-PipelineVariable -Name 'limsAppMigTemporaryDiskId' -Value ([string]$tempDisk.id)
    Write-PipelineVariable -Name 'limsAppMigTemporaryDiskUniqueId' -Value $tempUniqueId
    Write-PipelineVariable -Name 'limsAppMigDestinationDiskId' -Value $checks.DestinationDiskId
    Write-PipelineVariable -Name 'limsAppMigDestinationDiskUniqueId' -Value $checks.DestinationDiskUniqueId
    Write-PipelineVariable -Name 'limsAppMigSnapshotId' -Value ([string]$snapshot.id)
    Write-PipelineVariable -Name 'limsAppMigMigrationRunId' -Value $MigrationRunId
    Write-PipelineVariable -Name 'limsAppMigGuestCommandName' -Value $guestCommandName
    Write-PipelineVariable -Name 'limsAppMigEnvironmentName' -Value $Environment.EnvironmentName
    Write-PipelineVariable -Name 'limsAppMigCaptureMode' -Value $CaptureMode

    return [pscustomobject]@{
        Checks            = $checks
        SnapshotId        = [string]$snapshot.id
        TemporaryDiskId   = [string]$tempDisk.id
        TemporaryDiskName = $names.TemporaryDiskName
        TemporaryLun      = [int]$checks.CandidateTemporaryLun
        Phase             = $Phase
        Resumed           = $false
    }
}

function Invoke-LimsAppDataDiskMigrationAttachAndInspect {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $CaptureMode
    )

    return Invoke-LimsAppDataDiskMigrationAcquireSnapshotAndAttach -Environment $Environment -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -LockPurpose 'AttachAndInspect' -Phase 'InspectAttached' -CopyStatus 'InspectOnly' -OperatorTitle 'ATTACH-AND-INSPECT (Azure)'
}

function Invoke-LimsAppDataDiskMigrationStage {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $CaptureMode,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $CopyStatus
    )

    $gate = Test-LimsAppMigStageCleanupAllowed -Environment $Environment
    if (-not $gate.Allowed) {
        Assert-LimsAppMigControlFailure $gate.Reason
    }

    $effectiveCopyStatus = $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })
    return Invoke-LimsAppDataDiskMigrationAcquireSnapshotAndAttach -Environment $Environment -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -LockPurpose 'Stage' -Phase 'GuestPending' -CopyStatus $effectiveCopyStatus -OperatorTitle 'STAGE (Azure)'
}

function Invoke-LimsAppDataDiskMigrationExclusiveAttemptTransition {
    param(
        [Parameter(Mandatory = $true)] $DestinationVm,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [ValidateSet('Submitting', 'Recovering')] [string] $ToState
    )

    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $etag = Get-ResourceEtag -Resource $DestinationVm
    if ([string]::IsNullOrWhiteSpace($etag)) {
        Assert-LimsAppMigControlFailure "Destination VM '$($DestinationVm.id)' has no etag. Refusing the '$ToState' transition without If-Match."
    }

    $owner = Get-VmTagValue -Vm $DestinationVm -Key $tagKeys.RunId
    $submitted = Get-VmTagValue -Vm $DestinationVm -Key $tagKeys.GuestSubmitted
    $attemptState = Get-VmTagValue -Vm $DestinationVm -Key $tagKeys.AttemptState
    $copyStatus = Get-VmTagValue -Vm $DestinationVm -Key $tagKeys.CopyStatus
    if ($ToState -eq 'Submitting') {
        $gate = Get-InspectSubmitDecision -GuestSubmittedTag $submitted -AttemptStateTag $attemptState -LockOwnerRunId $owner -ThisRunId $MigrationRunId -CopyStatusTag $copyStatus
        if (-not $gate.Allowed) {
            Assert-LimsAppMigControlFailure $gate.Reason
        }
    }
    else {
        $evidence = Get-GuestSubmittedEvidenceDecision -Value $submitted
        if (-not $evidence.Accepted) {
            Assert-LimsAppMigControlFailure $evidence.Reason
        }
        $transition = Get-InspectAttemptStateTransitionDecision -FromState $attemptState -ToState $ToState
        if (-not $transition.Allowed) {
            Assert-LimsAppMigControlFailure $transition.Reason
        }
        if ([string]::IsNullOrWhiteSpace($owner) -or $owner -ne $MigrationRunId) {
            Assert-LimsAppMigControlFailure "Inspect recovery transition requires the destination VM lock to be held by this run '$MigrationRunId'."
        }
    }

    $merged = ConvertTo-TagHashtable -Tags $DestinationVm.tags
    $merged[$tagKeys.AttemptState] = $ToState
    if ($ToState -eq 'Submitting') {
        $merged[$tagKeys.GuestSubmitted] = 'true'
    }
    Write-OperatorLog "Transitioning inspect attempt '$MigrationRunId' Prepared -> $ToState with If-Match."
    $apply = Set-AzVmTagsIfMatchAdapter -ResourceId ([string]$DestinationVm.id) -IfMatch $etag -Tags $merged
    $applyDecision = Get-AtomicLockApplyDecision -Classification $apply.Classification
    if (-not $applyDecision.Allowed) {
        Assert-LimsAppMigControlFailure $applyDecision.Reason
    }
}

function Invoke-LimsAppDataDiskMigrationMarkGuestSubmitted {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }

    $destinationVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName
    Assert-VmIdentityMatchesMapping -Vm $destinationVm -Environment $Environment -ExpectedVmName $Environment.DestinationVmName -Role 'Destination'
    Invoke-LimsAppDataDiskMigrationExclusiveAttemptTransition -DestinationVm $destinationVm -MigrationRunId $MigrationRunId -ToState 'Submitting'
    Write-OperatorLog "Recorded guest submission for run '$MigrationRunId' on '$($destinationVm.id)' before creating the Run Command."
}

function Invoke-LimsAppDataDiskMigrationRecordCopyStatus {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $CopyStatus
    )

    $destinationVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $existingLock = Get-VmTagValue -Vm $destinationVm -Key $tagKeys.RunId
    if ($existingLock -ne $MigrationRunId) {
        Assert-LimsAppMigControlFailure "Refusing to record copy status '$CopyStatus' because destination lock run '$existingLock' is not this run '$MigrationRunId'."
    }
    $tags = @{ $tagKeys.CopyStatus = $CopyStatus }
    if ($CopyStatus -eq 'Succeeded') { $tags[$tagKeys.CopyCompleted] = 'Succeeded' }
    Set-AzResourceTagsMergeAdapter -ResourceId ([string]$destinationVm.id) -Tags $tags
    Write-Output "Recorded copy status '$CopyStatus' on '$($destinationVm.id)' for run '$MigrationRunId'."
}

function Invoke-LimsAppDataDiskMigrationCleanup {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [bool] $DeleteSnapshot,
        [Parameter(Mandatory = $false)] [bool] $PreSubmitRecovery = $false
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }

    $names = Get-MigrationRunResourceNames -Environment $Environment -MigrationRunId $MigrationRunId
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $guestCommandName = Get-LimsAppDataDiskMigrationRunCommandName -Environment $Environment -MigrationRunId $MigrationRunId
    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -ThisRunTemporaryDiskName $names.TemporaryDiskName

    $recordedRunId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.RunId
    $recordedTempDiskId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.TempDiskId
    $recordedSnapshotId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.SnapshotId
    $recordedCopyStatus = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.CopyStatus
    $recordedGuestSubmitted = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.GuestSubmitted
    $recordedAttemptState = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.AttemptState

    $commandLookup = Get-AzRunCommandLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -RunCommandName $guestCommandName
    $commandDecision = Get-GuestCommandCleanupDecision -LookupClassification $commandLookup.Classification -ExecutionState (Get-RunCommandExecutionState -Resource $commandLookup.Resource)
    $preSubmitDecision = Get-PreSubmitRecoveryDecision -Requested $PreSubmitRecovery -GuestSubmittedTag $recordedGuestSubmitted -AttemptStateTag $recordedAttemptState -LookupClassification $commandLookup.Classification -LockOwnerRunId $recordedRunId -ThisRunId $MigrationRunId -CopyStatusTag $recordedCopyStatus
    if (-not $commandDecision.Allowed -and -not $preSubmitDecision.Allowed) {
        if ($PreSubmitRecovery) {
            Assert-LimsAppMigControlFailure $preSubmitDecision.Reason
        }
        Assert-LimsAppMigControlFailure $commandDecision.Reason
    }

    if ($preSubmitDecision.Allowed) {
        $freshDestinationVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName
        Assert-VmIdentityMatchesMapping -Vm $freshDestinationVm -Environment $Environment -ExpectedVmName $Environment.DestinationVmName -Role 'Destination'
        Invoke-LimsAppDataDiskMigrationExclusiveAttemptTransition -DestinationVm $freshDestinationVm -MigrationRunId $MigrationRunId -ToState 'Recovering'
    }
    else {
        $gate = Test-LimsAppMigStageCleanupAllowed -Environment $Environment
        if (-not $gate.Allowed) {
            Assert-LimsAppMigControlFailure $gate.Reason
        }
    }

    $tempLookup = Get-AzDiskLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    Assert-LookupFoundOrGone -Lookup $tempLookup -Role 'Temporary disk'
    $snapshotLookup = Get-AzSnapshotLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
    Assert-LookupFoundOrGone -Lookup $snapshotLookup -Role 'Snapshot'

    $diskAlreadyGone = $tempLookup.Classification -eq 'NotFound'
    if (-not $diskAlreadyGone) {
        $tempDisk = $tempLookup.Resource
        $owner = Get-TemporaryDiskOwnerRunId -Disk $tempDisk
        if ([string]::IsNullOrWhiteSpace($owner) -and [string]::IsNullOrWhiteSpace($recordedRunId)) {
            Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' has no lock-owner tag and the destination VM has no recorded run ID. Name-only deletion is refused. Evidence needed: limsAppMigLockRunId on the disk or limsAppMigLockRunId/limsAppMigTempDiskId on the destination VM."
        }
        $effectiveOwner = $owner
        if ([string]::IsNullOrWhiteSpace($effectiveOwner)) { $effectiveOwner = $recordedRunId }
        $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $effectiveOwner -ThisRunId $MigrationRunId -Purpose 'Cleanup'
        if (-not $lockDecision.Allowed) {
            Assert-LimsAppMigControlFailure $lockDecision.Reason
        }
        if ([string]::IsNullOrWhiteSpace($recordedTempDiskId)) {
            if (-not ($preSubmitDecision.Allowed -and $owner -eq $MigrationRunId)) {
                Assert-LimsAppMigControlFailure "No recorded temporary disk resource ID for run '$MigrationRunId'. Cleanup will not delete by name alone. Evidence needed: destination VM tag limsAppMigTempDiskId matching this disk's ID."
            }
            $recordedTempDiskId = [string]$tempDisk.id
        }
        if ($snapshotLookup.Classification -ne 'Found') {
            Assert-LimsAppMigControlFailure "Cannot prove temporary-disk -> snapshot -> source lineage because snapshot lookup is '$($snapshotLookup.Classification)'. Cleanup retains the temporary disk."
        }
        $snapshot = $snapshotLookup.Resource
        $lineage = Get-TemporaryDiskLineageDecision -TemporaryDiskId ([string]$tempDisk.id) -TemporaryDiskSourceId (Get-CreationSourceId -Resource $tempDisk) -SnapshotId ([string]$snapshot.id) -SnapshotSourceId (Get-CreationSourceId -Resource $snapshot) -OriginalSourceDiskId $checks.SourceDiskId -RecordedTemporaryDiskId $recordedTempDiskId -RecordedSnapshotId $recordedSnapshotId
        if (-not $lineage.Matches) {
            Assert-LimsAppMigControlFailure $lineage.Reason
        }

        $attachedToVmId = ''
        foreach ($attached in @($checks.DestinationDataDisks)) {
            $attachedId = ''
            if ($attached.managedDisk -and $attached.managedDisk.id) { $attachedId = [string]$attached.managedDisk.id }
            if (Test-NormalizedResourceIdEquals -Left $attachedId -Right ([string]$tempDisk.id)) {
                $attachedToVmId = $checks.DestinationVmId
            }
        }
        if ($tempDisk.managedBy) { $attachedToVmId = [string]$tempDisk.managedBy }

        $target = Get-CleanupTargetDecision -CandidateDiskName $names.TemporaryDiskName -CandidateDiskId ([string]$tempDisk.id) -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId $recordedTempDiskId -SourceDiskResourceId $checks.SourceDiskId -DestinationDataDiskResourceId $checks.DestinationDiskId -AttachedToVmId $attachedToVmId -DestinationVmId $checks.DestinationVmId
        if (-not $target.Allowed) {
            Assert-LimsAppMigControlFailure $target.Reason
        }

        if (-not [string]::IsNullOrWhiteSpace($attachedToVmId)) {
            Write-Output "Detaching temporary disk '$($tempDisk.id)' from '$($Environment.DestinationVmName)'."
            Remove-AzVmDataDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -DiskName $names.TemporaryDiskName
        }
        Write-Output "Deleting temporary disk '$($tempDisk.id)'."
        Remove-AzDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    }
    else {
        Write-Output "Temporary disk '$($names.TemporaryDiskName)' confirmed NotFound; destination-VM lock will be released after the same ownership checks."
    }

    $snapshotDeleted = $false
    if ($DeleteSnapshot) {
        if ($snapshotLookup.Classification -eq 'Found') {
            $snapshot = $snapshotLookup.Resource
            if ([string]::IsNullOrWhiteSpace($recordedSnapshotId) -or -not (Test-NormalizedResourceIdEquals -Left ([string]$snapshot.id) -Right $recordedSnapshotId)) {
                Assert-LimsAppMigControlFailure "Refusing to delete snapshot '$($snapshot.id)' without a recorded snapshot ID that exactly matches. DeleteSnapshot is opt-in and still requires positive identity."
            }
            if (-not (Test-NormalizedResourceIdEquals -Left (Get-CreationSourceId -Resource $snapshot) -Right $checks.SourceDiskId)) {
                Assert-LimsAppMigControlFailure "Snapshot '$($snapshot.id)' is not from the original source disk. Refusing to delete it."
            }
            Write-Output "Deleting snapshot '$($snapshot.id)' because DeleteSnapshot was explicitly requested."
            Remove-AzSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
            $snapshotDeleted = $true
        }
        else {
            Write-Output "Snapshot '$($names.SnapshotName)' confirmed NotFound."
            $snapshotDeleted = $true
        }
    }
    else {
        if ($snapshotLookup.Classification -eq 'Found') {
            Write-Output "Retaining snapshot '$($snapshotLookup.Resource.id)' (DeleteSnapshot is false)."
        }
        else {
            Write-Output "No snapshot to retain (lookup $($snapshotLookup.Classification))."
        }
    }

    if ($commandLookup.Classification -eq 'Found') {
        Write-Output "Deleting inspect/guest Run Command '$guestCommandName' after temporary-disk cleanup succeeded."
        Remove-AzRunCommandAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -RunCommandName $guestCommandName
    }

    if ([string]::IsNullOrWhiteSpace($recordedRunId) -or $recordedRunId -eq $MigrationRunId) {
        Remove-AzResourceTagsAdapter -ResourceId $checks.DestinationVmId -TagKeys @(
            $tagKeys.RunId, $tagKeys.SnapshotId, $tagKeys.TempDiskId, $tagKeys.TempDiskUniqueId,
            $tagKeys.DestDiskUniqueId, $tagKeys.CaptureMode, $tagKeys.CopyStatus,
            $tagKeys.TemporaryLun, $tagKeys.GuestCommand, $tagKeys.GuestSubmitted, $tagKeys.AttemptState, $tagKeys.Phase
        )
        # limsAppMigCopyCompleted is retained so configure-app can prove
        # the mapped A: copy after the temporary-disk lock is released.
    }

    Write-Output '===== LIMS APP data-disk migration: CLEANUP ====='
    Write-Output "Migration run ID            : $MigrationRunId"
    Write-Output "Guest command state         : $($commandDecision.State)"
    Write-Output "Temporary disk removed      : $(-not $diskAlreadyGone)"
    Write-Output "Snapshot deleted            : $snapshotDeleted"
    Write-Output 'Original source disk        : preserved'
    Write-Output "Destination $($Environment.DestinationDriveLetter): volume     : preserved"
    Write-Output 'APP v2 services             : left stopped pending JDBC/UNC/Apache/Shibboleth review'
    Write-Output '================================================='
}

function Invoke-LimsAppDataDiskMigrationConfigure {
    <#
        Read-only Azure checks for configure-app / activate-app. Does not
        snapshot, attach, or touch the legacy APP or SQL VMs. Stage and
        cleanup reparse gates are not required and are not changed.
    #>
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [ValidateSet('Register', 'Activate')] [string] $Phase
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }

    $destinationVm = Get-AzVmAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName
    Assert-VmIdentityMatchesMapping -Vm $destinationVm -Environment $Environment -ExpectedVmName $Environment.DestinationVmName -Role 'Destination'
    $destinationDisk = Get-AzDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $Environment.DestinationDataDiskName
    Assert-DiskIdentityMatchesMapping -Disk $destinationDisk -Environment $Environment -ExpectedDiskName $Environment.DestinationDataDiskName -Role 'Destination'
    $destUnique = Get-DiskUniqueIdFromResource -Disk $destinationDisk
    if (-not (Test-NormalizedUniqueIdEquals -Left $destUnique -Right $Environment.DestinationAttestedGuestUniqueId)) {
        Assert-LimsAppMigControlFailure "Destination ARM uniqueId '$destUnique' does not match the attested guest UniqueId '$($Environment.DestinationAttestedGuestUniqueId)'."
    }

    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $copyCompleted = Get-VmTagValue -Vm $destinationVm -Key $tagKeys.CopyCompleted
    $copyStatus = Get-VmTagValue -Vm $destinationVm -Key $tagKeys.CopyStatus
    $copyCheck = Test-CopyCompletedForConfigure -CopyCompletedTag $copyCompleted -CopyStatusTag $copyStatus
    if (-not $copyCheck.Allowed) {
        Assert-LimsAppMigControlFailure $copyCheck.Reason
    }

    $guestCommandName = Get-LimsAppV2GuestCommandName -Environment $Environment -MigrationRunId $MigrationRunId -Phase $Phase
    Write-PipelineVariable -Name 'limsAppMigSubscriptionId' -Value $Environment.SubscriptionId
    Write-PipelineVariable -Name 'limsAppMigResourceGroupName' -Value $Environment.ResourceGroupName
    Write-PipelineVariable -Name 'limsAppMigDestinationVmName' -Value $Environment.DestinationVmName
    Write-PipelineVariable -Name 'limsAppMigDestinationDiskId' -Value ([string]$destinationDisk.id)
    Write-PipelineVariable -Name 'limsAppMigDestinationDiskUniqueId' -Value $destUnique
    Write-PipelineVariable -Name 'limsAppMigGuestCommandName' -Value $guestCommandName
    Write-PipelineVariable -Name 'limsAppMigEnvironmentName' -Value $Environment.EnvironmentName
    Write-PipelineVariable -Name 'limsAppMigConfigurePhase' -Value $Phase
    Write-PipelineVariable -Name 'limsAppMigMigrationRunId' -Value $MigrationRunId

    Write-Output "===== LIMS APP v2 configuration: $Phase (Azure) ====="
    Write-Output "Destination VM              : $($destinationVm.id)"
    Write-Output "Destination A: disk         : $($destinationDisk.id)"
    Write-Output "Copy completed              : proven"
    Write-Output "Guest command               : $guestCommandName"
    Write-Output 'Legacy APP and SQL VMs      : not targeted'
    Write-Output 'Stage/cleanup safety gates  : unchanged'
    Write-Output '==================================================='

    return [pscustomobject]@{
        DestinationVmId = [string]$destinationVm.id
        DestinationDiskId = [string]$destinationDisk.id
        Phase           = $Phase
        GuestCommandName = $guestCommandName
    }
}

function Invoke-LimsAppDataDiskMigration {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $true)] [string] $EnvironmentName,
        [Parameter(Mandatory = $false)] [string] $MigrationRunId = '',
        [Parameter(Mandatory = $false)] [string] $CaptureMode = 'unspecified',
        [Parameter(Mandatory = $false)] [bool] $DeleteSnapshot = $false,
        [Parameter(Mandatory = $false)] [string] $CopyStatus = '',
        [Parameter(Mandatory = $false)] [bool] $PreSubmitRecovery = $false
    )

    if ($env:LIMS_APP_MIG_ACTION) { $Action = $env:LIMS_APP_MIG_ACTION }
    if ($env:LIMS_APP_MIG_ENVIRONMENT) { $EnvironmentName = $env:LIMS_APP_MIG_ENVIRONMENT }
    $suppliedRunId = $MigrationRunId
    if ($null -ne $env:LIMS_APP_MIG_RUN_ID) { $suppliedRunId = $env:LIMS_APP_MIG_RUN_ID }
    $buildId = ''
    if ($env:LIMS_APP_MIG_BUILD_ID) { $buildId = $env:LIMS_APP_MIG_BUILD_ID }
    elseif ($env:BUILD_BUILDID) { $buildId = $env:BUILD_BUILDID }
    if ($env:LIMS_APP_MIG_CAPTURE_MODE) { $CaptureMode = $env:LIMS_APP_MIG_CAPTURE_MODE }
    if ($env:LIMS_APP_MIG_COPY_STATUS) { $CopyStatus = $env:LIMS_APP_MIG_COPY_STATUS }
    if ($env:LIMS_APP_MIG_DELETE_SNAPSHOT) {
        $MigrationDeleteSnapshot = $env:LIMS_APP_MIG_DELETE_SNAPSHOT
        if ($MigrationDeleteSnapshot -eq 'true' -or $MigrationDeleteSnapshot -eq 'True' -or $MigrationDeleteSnapshot -eq '1') {
            $DeleteSnapshot = $true
        }
        elseif ($MigrationDeleteSnapshot -eq 'false' -or $MigrationDeleteSnapshot -eq 'False' -or $MigrationDeleteSnapshot -eq '0') {
            $DeleteSnapshot = $false
        }
    }
    if (Test-LimsAppMigEnvFlag -Name 'LIMS_APP_MIG_PRE_SUBMIT_RECOVERY') {
        $PreSubmitRecovery = $true
    }

    $environment = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName $EnvironmentName
    Assert-EnvironmentEnabledAndComplete -Environment $environment

    if ($Action -ne 'plan' -or -not [string]::IsNullOrWhiteSpace($suppliedRunId)) {
        $resolved = Resolve-LimsAppMigPipelineRunId -Action $Action -SuppliedRunId $suppliedRunId -BuildId $buildId
        if (-not $resolved.Accepted) {
            Assert-LimsAppMigControlFailure $resolved.Reason
        }
        if ($resolved.RunId) { $MigrationRunId = $resolved.RunId }
        else { $MigrationRunId = '' }
    }

    switch ($Action) {
        'plan' {
            return Invoke-LimsAppDataDiskMigrationPlan -Environment $environment
        }
        'attach-and-inspect' {
            if (Test-LimsAppMigEnvFlag -Name 'LIMS_APP_MIG_MARK_GUEST_SUBMITTED') {
                return Invoke-LimsAppDataDiskMigrationMarkGuestSubmitted -Environment $environment -MigrationRunId $MigrationRunId
            }
            return Invoke-LimsAppDataDiskMigrationAttachAndInspect -Environment $environment -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode
        }
        'stage' {
            if ($CopyStatus -eq 'Succeeded' -or $CopyStatus -eq 'Failed') {
                return Invoke-LimsAppDataDiskMigrationRecordCopyStatus -Environment $environment -MigrationRunId $MigrationRunId -CopyStatus $CopyStatus
            }
            return Invoke-LimsAppDataDiskMigrationStage -Environment $environment -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -CopyStatus $CopyStatus
        }
        'cleanup' {
            return Invoke-LimsAppDataDiskMigrationCleanup -Environment $environment -MigrationRunId $MigrationRunId -DeleteSnapshot $DeleteSnapshot -PreSubmitRecovery $PreSubmitRecovery
        }
        'configure-app' {
            return Invoke-LimsAppDataDiskMigrationConfigure -Environment $environment -MigrationRunId $MigrationRunId -Phase 'Register'
        }
        'activate-app' {
            return Invoke-LimsAppDataDiskMigrationConfigure -Environment $environment -MigrationRunId $MigrationRunId -Phase 'Activate'
        }
        default {
            Assert-LimsAppMigControlFailure "Unsupported action '$Action'."
        }
    }
}

function Invoke-LimsAppDataDiskMigrationEntry {
    <#
        Script entry point used by the pipeline. Structured return values
        stay on the success stream for callers/tests; the entry discards
        them so they do not become CLI output. Operator-facing lines go
        through Write-OperatorLog / Write-Host.
    #>
    param(
        [Parameter(Mandatory = $false)] [string] $Action = 'plan',
        [Parameter(Mandatory = $false)] [string] $EnvironmentName = 'dev',
        [Parameter(Mandatory = $false)] [string] $MigrationRunId = '',
        [Parameter(Mandatory = $false)] [string] $CaptureMode = 'unspecified',
        [Parameter(Mandatory = $false)] [bool] $DeleteSnapshot = $false,
        [Parameter(Mandatory = $false)] [string] $CopyStatus = '',
        [Parameter(Mandatory = $false)] [bool] $PreSubmitRecovery = $false
    )

    Invoke-LimsAppDataDiskMigration -Action $Action -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -DeleteSnapshot $DeleteSnapshot -CopyStatus $CopyStatus -PreSubmitRecovery $PreSubmitRecovery | Out-Null
}

if ($env:LIMS_APP_MIG_CONTROL_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-LimsAppDataDiskMigrationEntry -Action $Action -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -DeleteSnapshot $DeleteSnapshot -CopyStatus $CopyStatus -PreSubmitRecovery $PreSubmitRecovery
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

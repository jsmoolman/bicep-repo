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

    stage: re-runs every plan check, requires the operator to record
    whether the capture is online or application writes were quiesced,
    takes a destination-VM lock, creates an incremental snapshot of the
    source disk, creates a temporary disk from that snapshot, and attaches
    it only to the destination APP v2 VM at the validated unused LUN.
    Records resource IDs on the destination VM as tags so a failed run can
    be inspected or resumed. Guest Robocopy is a separate Managed Run
    Command step in the pipeline, not this script.

    cleanup: detaches and deletes only the temporary disk created by the
    selected run, after verifying its resource ID and attachment. Snapshot
    deletion is opt-in (default retain). Never touches the original source
    disk or the destination A: data disk. Does not start APP v2 services.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('plan', 'stage', 'cleanup')]
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
    [ValidateSet('', 'Pending', 'Succeeded', 'Failed')]
    [string] $CopyStatus = ''
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
        'WindowsReparseValidationStatus'
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
}

function Get-CaptureModeDecision {
    param([Parameter(Mandatory = $true)] [string] $CaptureMode)

    if ($CaptureMode -eq 'online' -or $CaptureMode -eq 'writes-quiesced') {
        return [pscustomobject]@{ Accepted = $true; Reason = $null }
    }
    return [pscustomobject]@{
        Accepted = $false
        Reason   = "CaptureMode must be recorded as 'online' or 'writes-quiesced' before stage. '$CaptureMode' is not an approved capture record."
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

function Get-VmZoneOrEmpty {
    param([Parameter(Mandatory = $true)] $Vm)
    if ($Vm.zones -and @($Vm.zones).Count -gt 0) {
        return [string](@($Vm.zones)[0])
    }
    return ''
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
        Zone                      = Get-VmZoneOrEmpty -Vm $destinationVm
        DiskEncryptionSetId       = $sourceDes
        CandidateTemporaryLun          = [int]$lunSelection.Lun
        OccupiedLuns                   = $occupiedLuns
        DestinationDataDisks           = $destinationDisks
        DestinationDiskUniqueId        = Get-DiskUniqueIdFromResource -Disk $destinationDisk
        SourceDiskUniqueId             = Get-DiskUniqueIdFromResource -Disk $sourceDisk
    }
}

function Write-LimsAppDataDiskMigrationPlanSummary {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] $Checks
    )

    Write-Output '===== LIMS APP data-disk migration: PLAN ====='
    Write-Output "Environment                 : $($Environment.EnvironmentName) (enabled=$($Environment.Enabled))"
    Write-Output "Region                      : $($Checks.Location)"
    Write-Output "Source VM                   : $($Checks.SourceVmId)"
    Write-Output "Source data disk            : $($Checks.SourceDiskId) (LUN $($Environment.SourceDataDiskLun), name $($Environment.SourceDataDiskName))"
    Write-Output "Destination VM              : $($Checks.DestinationVmId)"
    Write-Output "Destination computer        : $($Environment.DestinationComputerName)"
    Write-Output "Destination data disk       : $($Checks.DestinationDiskId) (LUN $($Environment.DestinationDataDiskLun), letter $($Environment.DestinationDriveLetter):, label $($Environment.DestinationVolumeLabel))"
    Write-Output "Disk Encryption Set         : $($Checks.DiskEncryptionSetId)"
    Write-Output "Candidate temporary LUN     : $($Checks.CandidateTemporaryLun) (must be unused on APP v2 except this run's own temp disk)"
    Write-Output "Preferred temp drive letter : $($Environment.PreferredTemporaryDriveLetter): (guest picks an unused letter if occupied)"
    Write-Output "Exclude relative paths      : $($Environment.ExcludeRelativePaths -join ', ')"
    Write-Output 'Original source disk and destination A: are not modified by plan.'
    Write-Output '=============================================='
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
    Write-Output "##vso[task.setvariable variable=$Name]$Value"
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

    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -RequireEncryptionPin $false
    Write-LimsAppDataDiskMigrationPlanSummary -Environment $Environment -Checks $checks
    $pinCheck = Test-EncryptionMatchesMapping -SourceDiskEncryptionSetId $checks.DiskEncryptionSetId -DestinationDiskEncryptionSetId $checks.DiskEncryptionSetId -Environment $Environment -RequirePin $true
    if (-not $pinCheck.Matches) {
        Assert-LimsAppMigControlFailure $pinCheck.Reason
    }
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

function Invoke-LimsAppDataDiskMigrationStage {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $CaptureMode,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $CopyStatus
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }
    $gate = Test-LimsAppMigStageCleanupAllowed -Environment $Environment
    if (-not $gate.Allowed) {
        Assert-LimsAppMigControlFailure $gate.Reason
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

    $tempLookup = Get-AzDiskLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    Assert-LookupFoundOrGone -Lookup $tempLookup -Role 'Temporary disk'

    $resume = $false
    $snapshot = $null
    $tempDisk = $null

    if ($tempLookup.Classification -eq 'Found') {
        $tempDisk = $tempLookup.Resource
        $owner = Get-TemporaryDiskOwnerRunId -Disk $tempDisk
        if ([string]::IsNullOrWhiteSpace($owner)) {
            Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' exists without limsAppMigLockRunId. Refusing to reuse or steal the environment lock. Evidence needed: lock-owner tag set at create."
        }
        $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $owner -ThisRunId $MigrationRunId
        if (-not $lockDecision.Allowed) {
            Assert-LimsAppMigControlFailure $lockDecision.Reason
        }
        $snapshotLookup = Get-AzSnapshotLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
        Assert-LookupFoundOrGone -Lookup $snapshotLookup -Role 'Snapshot'
        if ($snapshotLookup.Classification -ne 'Found') {
            Assert-LimsAppMigControlFailure "Same-ID retry found the environment lock disk but snapshot '$($names.SnapshotName)' lookup is '$($snapshotLookup.Classification)'. Refusing to recreate from an unproven snapshot."
        }
        $snapshot = $snapshotLookup.Resource
        $lineage = Get-TemporaryDiskLineageDecision -TemporaryDiskId ([string]$tempDisk.id) -TemporaryDiskSourceId (Get-CreationSourceId -Resource $tempDisk) -SnapshotId ([string]$snapshot.id) -SnapshotSourceId (Get-CreationSourceId -Resource $snapshot) -OriginalSourceDiskId $checks.SourceDiskId -RecordedTemporaryDiskId ([string]$tempDisk.id) -RecordedSnapshotId ([string]$snapshot.id)
        if (-not $lineage.Matches) {
            Assert-LimsAppMigControlFailure $lineage.Reason
        }
        $resume = $true
        Write-Output "Reusing temporary disk '$($tempDisk.id)' (environment lock, same-ID retry)."
    }
    else {
        $snapshotLookup = Get-AzSnapshotLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
        Assert-LookupFoundOrGone -Lookup $snapshotLookup -Role 'Snapshot'
        $snapshot = $snapshotLookup.Resource
        if ($snapshotLookup.Classification -eq 'Found') {
            if (-not (Test-NormalizedResourceIdEquals -Left (Get-CreationSourceId -Resource $snapshot) -Right $checks.SourceDiskId)) {
                Assert-LimsAppMigControlFailure "Existing snapshot '$($snapshot.id)' was created from '$(Get-CreationSourceId -Resource $snapshot)', not the original source disk '$($checks.SourceDiskId)'."
            }
            Write-Output "Reusing incremental snapshot '$($snapshot.id)' from this run."
        }
        else {
            Write-Output "Creating incremental snapshot '$($names.SnapshotName)' of source disk '$($checks.SourceDiskId)' (capture mode: $CaptureMode). Legacy APP is not modified."
            $snapshot = New-AzIncrementalSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName -SourceDiskId $checks.SourceDiskId -Location $checks.Location -DiskEncryptionSetId $checks.DiskEncryptionSetId
        }

        Write-Output "Creating temporary disk '$($names.TemporaryDiskName)' from snapshot '$($snapshot.id)' (this create is the per-environment lock)."
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
            $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $owner -ThisRunId $MigrationRunId
            if (-not $lockDecision.Allowed) {
                Assert-LimsAppMigControlFailure $lockDecision.Reason
            }
            $lineage = Get-TemporaryDiskLineageDecision -TemporaryDiskId ([string]$tempDisk.id) -TemporaryDiskSourceId (Get-CreationSourceId -Resource $tempDisk) -SnapshotId ([string]$snapshot.id) -SnapshotSourceId (Get-CreationSourceId -Resource $snapshot) -OriginalSourceDiskId $checks.SourceDiskId -RecordedTemporaryDiskId ([string]$tempDisk.id) -RecordedSnapshotId ([string]$snapshot.id)
            if (-not $lineage.Matches) {
                Assert-LimsAppMigControlFailure $lineage.Reason
            }
            $resume = $true
            Write-Output "Create collided; reusing temporary disk '$($tempDisk.id)' for same-ID retry."
        }
        elseif ($createResult.Classification -eq 'Found') {
            $tempDisk = $createResult.Resource
        }
        else {
            Assert-LimsAppMigControlFailure "Temporary disk create classified as '$($createResult.Classification)'. $($createResult.Text)"
        }
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
        Write-Output "Attaching temporary disk '$($names.TemporaryDiskName)' to '$($Environment.DestinationVmName)' at LUN $($checks.CandidateTemporaryLun) only."
        Add-AzVmDataDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -DiskName $names.TemporaryDiskName -Lun ([int]$checks.CandidateTemporaryLun)
    }

    $tempUniqueId = Get-DiskUniqueIdFromResource -Disk $tempDisk
    if ([string]::IsNullOrWhiteSpace($tempUniqueId)) {
        Assert-LimsAppMigControlFailure "Temporary disk '$($tempDisk.id)' has no ARM uniqueId. Guest identity cannot be proven. Evidence needed: Microsoft.Compute/disks uniqueId."
    }
    Set-AzResourceTagsMergeAdapter -ResourceId $checks.DestinationVmId -Tags @{
        $tagKeys.RunId            = $MigrationRunId
        $tagKeys.SnapshotId       = [string]$snapshot.id
        $tagKeys.TempDiskId       = [string]$tempDisk.id
        $tagKeys.TempDiskUniqueId = $tempUniqueId
        $tagKeys.DestDiskUniqueId = $checks.DestinationDiskUniqueId
        $tagKeys.CaptureMode      = $CaptureMode
        $tagKeys.CopyStatus       = $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })
        $tagKeys.TemporaryLun     = [string]$checks.CandidateTemporaryLun
        $tagKeys.GuestCommand     = $guestCommandName
    }

    Write-Output '===== LIMS APP data-disk migration: STAGE (Azure) ====='
    Write-Output "Migration run ID            : $MigrationRunId"
    Write-Output "Capture mode                : $CaptureMode"
    Write-Output "Snapshot                    : $($snapshot.id)"
    Write-Output "Temporary disk              : $($tempDisk.id)"
    Write-Output "Attached to                 : $($checks.DestinationVmId) at LUN $($checks.CandidateTemporaryLun)"
    Write-Output "Copy status                 : $(if ($CopyStatus) { $CopyStatus } else { 'Pending (guest copy is the next pipeline step)' })"
    Write-Output 'Legacy APP VM/disk          : read-only (snapshot source only)'
    Write-Output 'SQL VMs and Azure Files     : out of scope'
    Write-Output '======================================================='

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
        Resumed           = $resume
    }
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
    Set-AzResourceTagsMergeAdapter -ResourceId ([string]$destinationVm.id) -Tags @{ $tagKeys.CopyStatus = $CopyStatus }
    Write-Output "Recorded copy status '$CopyStatus' on '$($destinationVm.id)' for run '$MigrationRunId'."
}

function Invoke-LimsAppDataDiskMigrationCleanup {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [bool] $DeleteSnapshot
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigControlFailure $runIdCheck.Reason
    }
    $gate = Test-LimsAppMigStageCleanupAllowed -Environment $Environment
    if (-not $gate.Allowed) {
        Assert-LimsAppMigControlFailure $gate.Reason
    }

    $names = Get-MigrationRunResourceNames -Environment $Environment -MigrationRunId $MigrationRunId
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $guestCommandName = Get-LimsAppDataDiskMigrationRunCommandName -Environment $Environment -MigrationRunId $MigrationRunId
    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -ThisRunTemporaryDiskName $names.TemporaryDiskName

    $recordedRunId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.RunId
    $recordedTempDiskId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.TempDiskId
    $recordedSnapshotId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.SnapshotId

    $commandLookup = Get-AzRunCommandLookupAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -RunCommandName $guestCommandName
    $commandDecision = Get-GuestCommandCleanupDecision -LookupClassification $commandLookup.Classification -ExecutionState (Get-RunCommandExecutionState -Resource $commandLookup.Resource)
    if (-not $commandDecision.Allowed) {
        Assert-LimsAppMigControlFailure $commandDecision.Reason
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
        $lockDecision = Get-MigrationLockAcquireDecision -ExistingLockRunId $effectiveOwner -ThisRunId $MigrationRunId
        if (-not $lockDecision.Allowed) {
            Assert-LimsAppMigControlFailure $lockDecision.Reason
        }
        if ([string]::IsNullOrWhiteSpace($recordedTempDiskId)) {
            Assert-LimsAppMigControlFailure "No recorded temporary disk resource ID for run '$MigrationRunId'. Cleanup will not delete by name alone. Evidence needed: destination VM tag limsAppMigTempDiskId matching this disk's ID."
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
        Write-Output "Temporary disk '$($names.TemporaryDiskName)' confirmed NotFound; lock is already released."
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

    if ([string]::IsNullOrWhiteSpace($recordedRunId) -or $recordedRunId -eq $MigrationRunId) {
        Remove-AzResourceTagsAdapter -ResourceId $checks.DestinationVmId -TagKeys @(
            $tagKeys.RunId, $tagKeys.SnapshotId, $tagKeys.TempDiskId, $tagKeys.TempDiskUniqueId,
            $tagKeys.DestDiskUniqueId, $tagKeys.CaptureMode, $tagKeys.CopyStatus,
            $tagKeys.TemporaryLun, $tagKeys.GuestCommand
        )
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

function Invoke-LimsAppDataDiskMigration {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $true)] [string] $EnvironmentName,
        [Parameter(Mandatory = $false)] [string] $MigrationRunId = '',
        [Parameter(Mandatory = $false)] [string] $CaptureMode = 'unspecified',
        [Parameter(Mandatory = $false)] [bool] $DeleteSnapshot = $false,
        [Parameter(Mandatory = $false)] [string] $CopyStatus = ''
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
        'stage' {
            if ($CopyStatus -eq 'Succeeded' -or $CopyStatus -eq 'Failed') {
                return Invoke-LimsAppDataDiskMigrationRecordCopyStatus -Environment $environment -MigrationRunId $MigrationRunId -CopyStatus $CopyStatus
            }
            return Invoke-LimsAppDataDiskMigrationStage -Environment $environment -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -CopyStatus $CopyStatus
        }
        'cleanup' {
            return Invoke-LimsAppDataDiskMigrationCleanup -Environment $environment -MigrationRunId $MigrationRunId -DeleteSnapshot $DeleteSnapshot
        }
        default {
            Assert-LimsAppMigControlFailure "Unsupported action '$Action'."
        }
    }
}

if ($env:LIMS_APP_MIG_CONTROL_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-LimsAppDataDiskMigration -Action $Action -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -CaptureMode $CaptureMode -DeleteSnapshot $DeleteSnapshot -CopyStatus $CopyStatus | Out-Null
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

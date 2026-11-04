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
if (-not (Test-Path -LiteralPath $script:MappingPath)) {
    throw [System.InvalidOperationException]::new("Reviewed environment mapping file '$script:MappingPath' was not found.")
}
. $script:MappingPath

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
        TemporaryDiskName = "$($Environment.TemporaryDiskNamePrefix)-$safeRunId-tmp"
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

function Get-ConcurrentMigrationLockDecision {
    <#
        Pure: stage may proceed when the destination has no lock, or the
        lock belongs to this run (resume). Any other in-progress run fails.
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExistingLockRunId,
        [Parameter(Mandatory = $true)] [string] $ThisRunId,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $ExistingTempDiskId
    )

    if ([string]::IsNullOrWhiteSpace($ExistingLockRunId)) {
        return [pscustomobject]@{ Allowed = $true; Resume = $false; Reason = $null }
    }
    if ($ExistingLockRunId -eq $ThisRunId) {
        return [pscustomobject]@{ Allowed = $true; Resume = $true; Reason = $null }
    }

    $diskNote = 'no temporary disk ID recorded'
    if (-not [string]::IsNullOrWhiteSpace($ExistingTempDiskId)) {
        $diskNote = "temporary disk '$ExistingTempDiskId'"
    }
    return [pscustomobject]@{
        Allowed = $false
        Resume  = $false
        Reason  = "Destination VM is locked by migration run '$ExistingLockRunId' ($diskNote). Refusing to start a concurrent run '$ThisRunId'. Run cleanup for the in-progress run first."
    }
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
        'SnapshotNamePrefix', 'TemporaryDiskNamePrefix'
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

function Test-AzDiskExistsAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $DiskName
    )
    $raw = & az disk show --subscription $SubscriptionId --resource-group $ResourceGroupName --name $DiskName --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($raw | Out-String)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Test-AzSnapshotExistsAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SnapshotName
    )
    $raw = & az snapshot show --subscription $SubscriptionId --resource-group $ResourceGroupName --name $SnapshotName --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($raw | Out-String)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
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
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Zone
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
    return Invoke-AzCliAdapter -ExpectJson -Arguments $arguments
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
        CandidateTemporaryLun     = [int]$lunSelection.Lun
        OccupiedLuns              = $occupiedLuns
        DestinationDataDisks      = $destinationDisks
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
    Write-Output "##vso[task.setvariable variable=$Name]$Value"
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

    if ([string]::IsNullOrWhiteSpace($MigrationRunId)) {
        Assert-LimsAppMigControlFailure 'MigrationRunId is required for stage (use the pipeline Build.BuildId).'
    }
    $captureDecision = Get-CaptureModeDecision -CaptureMode $CaptureMode
    if (-not $captureDecision.Accepted) {
        Assert-LimsAppMigControlFailure $captureDecision.Reason
    }

    $names = Get-MigrationRunResourceNames -Environment $Environment -MigrationRunId $MigrationRunId
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -ThisRunTemporaryDiskName $names.TemporaryDiskName

    $existingLock = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.RunId
    $existingTempDiskId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.TempDiskId
    $lockDecision = Get-ConcurrentMigrationLockDecision -ExistingLockRunId $existingLock -ThisRunId $MigrationRunId -ExistingTempDiskId $existingTempDiskId
    if (-not $lockDecision.Allowed) {
        Assert-LimsAppMigControlFailure $lockDecision.Reason
    }

    Set-AzResourceTagsMergeAdapter -ResourceId $checks.DestinationVmId -Tags @{
        $tagKeys.RunId        = $MigrationRunId
        $tagKeys.CaptureMode  = $CaptureMode
        $tagKeys.CopyStatus   = $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })
        $tagKeys.TemporaryLun = [string]$checks.CandidateTemporaryLun
    }

    $snapshot = Test-AzSnapshotExistsAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
    if ($snapshot) {
        $snapshotSource = ''
        if ($snapshot.creationData -and $snapshot.creationData.sourceResourceId) {
            $snapshotSource = [string]$snapshot.creationData.sourceResourceId
        }
        if (-not (Test-NormalizedResourceIdEquals -Left $snapshotSource -Right $checks.SourceDiskId)) {
            Assert-LimsAppMigControlFailure "Existing snapshot '$($names.SnapshotName)' was created from '$snapshotSource', not the mapped source disk '$($checks.SourceDiskId)'. Refusing to reuse it."
        }
        Write-Output "Reusing incremental snapshot '$($snapshot.id)' from this run."
    }
    else {
        Write-Output "Creating incremental snapshot '$($names.SnapshotName)' of source disk '$($checks.SourceDiskId)' (capture mode: $CaptureMode)."
        $snapshot = New-AzIncrementalSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName -SourceDiskId $checks.SourceDiskId -Location $checks.Location -DiskEncryptionSetId $checks.DiskEncryptionSetId
    }

    $tempDisk = Test-AzDiskExistsAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    if ($tempDisk) {
        $tempSource = ''
        if ($tempDisk.creationData -and $tempDisk.creationData.sourceResourceId) {
            $tempSource = [string]$tempDisk.creationData.sourceResourceId
        }
        if (-not (Test-NormalizedResourceIdEquals -Left $tempSource -Right ([string]$snapshot.id))) {
            Assert-LimsAppMigControlFailure "Existing temporary disk '$($names.TemporaryDiskName)' was created from '$tempSource', not this run's snapshot '$($snapshot.id)'. Refusing to reuse it."
        }
        Write-Output "Reusing temporary disk '$($tempDisk.id)' from this run."
    }
    else {
        Write-Output "Creating temporary disk '$($names.TemporaryDiskName)' from snapshot '$($snapshot.id)'."
        $tempDisk = New-AzDiskFromSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName -SnapshotId ([string]$snapshot.id) -Location $checks.Location -Zone $checks.Zone
    }

    $attachedAlready = $false
    foreach ($attached in @($checks.DestinationDataDisks)) {
        $attachedName = [string]$attached.name
        if ([string]::IsNullOrWhiteSpace($attachedName) -and $attached.managedDisk) {
            $attachedName = Get-ResourceNameFromId -ResourceId ([string]$attached.managedDisk.id)
        }
        if ($attachedName -eq $names.TemporaryDiskName) {
            if ([int]$attached.lun -ne [int]$checks.CandidateTemporaryLun) {
                Assert-LimsAppMigControlFailure "Temporary disk '$($names.TemporaryDiskName)' is attached at LUN $($attached.lun), not the validated LUN $($checks.CandidateTemporaryLun)."
            }
            $attachedAlready = $true
        }
    }
    if (-not $attachedAlready) {
        Write-Output "Attaching temporary disk '$($names.TemporaryDiskName)' to '$($Environment.DestinationVmName)' at LUN $($checks.CandidateTemporaryLun)."
        Add-AzVmDataDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -DiskName $names.TemporaryDiskName -Lun ([int]$checks.CandidateTemporaryLun)
    }

    Set-AzResourceTagsMergeAdapter -ResourceId $checks.DestinationVmId -Tags @{
        $tagKeys.RunId        = $MigrationRunId
        $tagKeys.SnapshotId   = [string]$snapshot.id
        $tagKeys.TempDiskId   = [string]$tempDisk.id
        $tagKeys.CaptureMode  = $CaptureMode
        $tagKeys.CopyStatus   = $(if ($CopyStatus) { $CopyStatus } else { 'Pending' })
        $tagKeys.TemporaryLun = [string]$checks.CandidateTemporaryLun
    }

    Write-Output '===== LIMS APP data-disk migration: STAGE (Azure) ====='
    Write-Output "Migration run ID            : $MigrationRunId"
    Write-Output "Capture mode                : $CaptureMode"
    Write-Output "Snapshot                    : $($snapshot.id)"
    Write-Output "Temporary disk              : $($tempDisk.id)"
    Write-Output "Attached to                 : $($checks.DestinationVmId) at LUN $($checks.CandidateTemporaryLun)"
    Write-Output "Copy status                 : $(if ($CopyStatus) { $CopyStatus } else { 'Pending (guest copy is the next pipeline step)' })"
    Write-Output 'Original source disk and destination A: were not modified.'
    Write-Output '======================================================='

    Write-PipelineVariable -Name 'limsAppMigSubscriptionId' -Value $Environment.SubscriptionId
    Write-PipelineVariable -Name 'limsAppMigResourceGroupName' -Value $Environment.ResourceGroupName
    Write-PipelineVariable -Name 'limsAppMigDestinationVmName' -Value $Environment.DestinationVmName
    Write-PipelineVariable -Name 'limsAppMigDestinationComputerName' -Value $Environment.DestinationComputerName
    Write-PipelineVariable -Name 'limsAppMigTemporaryLun' -Value ([string]$checks.CandidateTemporaryLun)
    Write-PipelineVariable -Name 'limsAppMigTemporaryDiskName' -Value $names.TemporaryDiskName
    Write-PipelineVariable -Name 'limsAppMigTemporaryDiskId' -Value ([string]$tempDisk.id)
    Write-PipelineVariable -Name 'limsAppMigSnapshotId' -Value ([string]$snapshot.id)
    Write-PipelineVariable -Name 'limsAppMigDiskEncryptionSetId' -Value $checks.DiskEncryptionSetId
    Write-PipelineVariable -Name 'limsAppMigMigrationRunId' -Value $MigrationRunId
    Write-PipelineVariable -Name 'limsAppMigCaptureMode' -Value $CaptureMode

    return [pscustomobject]@{
        Checks            = $checks
        SnapshotId        = [string]$snapshot.id
        TemporaryDiskId   = [string]$tempDisk.id
        TemporaryDiskName = $names.TemporaryDiskName
        TemporaryLun      = [int]$checks.CandidateTemporaryLun
        Resumed           = [bool]$lockDecision.Resume
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

    if ([string]::IsNullOrWhiteSpace($MigrationRunId)) {
        Assert-LimsAppMigControlFailure 'MigrationRunId is required for cleanup (the run that created the temporary disk).'
    }

    $names = Get-MigrationRunResourceNames -Environment $Environment -MigrationRunId $MigrationRunId
    $tagKeys = Get-LimsAppDataDiskMigrationLockTagKeys
    $checks = Invoke-LimsAppDataDiskMigrationPlanChecks -Environment $Environment -ThisRunTemporaryDiskName $names.TemporaryDiskName

    $recordedRunId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.RunId
    $recordedTempDiskId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.TempDiskId
    $recordedSnapshotId = Get-VmTagValue -Vm $checks.DestinationVm -Key $tagKeys.SnapshotId

    if (-not [string]::IsNullOrWhiteSpace($recordedRunId) -and $recordedRunId -ne $MigrationRunId) {
        Assert-LimsAppMigControlFailure "Destination VM lock belongs to run '$recordedRunId', not the selected run '$MigrationRunId'. Refusing to clean up another run's resources."
    }

    $tempDisk = Test-AzDiskExistsAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    $candidateName = $names.TemporaryDiskName
    $candidateId = ''
    $attachedToVmId = ''
    if ($tempDisk) {
        $candidateId = [string]$tempDisk.id
        foreach ($attached in @($checks.DestinationDataDisks)) {
            $attachedName = [string]$attached.name
            if ([string]::IsNullOrWhiteSpace($attachedName) -and $attached.managedDisk) {
                $attachedName = Get-ResourceNameFromId -ResourceId ([string]$attached.managedDisk.id)
            }
            if ($attachedName -eq $names.TemporaryDiskName) {
                $attachedToVmId = $checks.DestinationVmId
            }
        }
        if ($tempDisk.managedBy) {
            $attachedToVmId = [string]$tempDisk.managedBy
        }
    }
    else {
        $candidateName = ''
        $candidateId = ''
    }

    $decision = Get-CleanupTargetDecision -CandidateDiskName $candidateName -CandidateDiskId $candidateId -ExpectedTemporaryDiskName $names.TemporaryDiskName -RecordedTempDiskId $recordedTempDiskId -SourceDiskResourceId $checks.SourceDiskId -DestinationDataDiskResourceId $checks.DestinationDiskId -AttachedToVmId $attachedToVmId -DestinationVmId $checks.DestinationVmId
    if (-not $decision.Allowed) {
        Assert-LimsAppMigControlFailure $decision.Reason
    }

    if (-not $decision.DiskAlreadyGone) {
        if (-not [string]::IsNullOrWhiteSpace($attachedToVmId)) {
            Write-Output "Detaching temporary disk '$($names.TemporaryDiskName)' from '$($Environment.DestinationVmName)'."
            Remove-AzVmDataDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -VmName $Environment.DestinationVmName -DiskName $names.TemporaryDiskName
        }
        Write-Output "Deleting temporary disk '$candidateId'."
        Remove-AzDiskAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -DiskName $names.TemporaryDiskName
    }
    else {
        Write-Output "Temporary disk '$($names.TemporaryDiskName)' is already gone; continuing lock/tag cleanup for run '$MigrationRunId'."
    }

    $snapshotDeleted = $false
    $snapshot = Test-AzSnapshotExistsAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
    if ($DeleteSnapshot) {
        if ($snapshot) {
            if (-not [string]::IsNullOrWhiteSpace($recordedSnapshotId) -and -not (Test-NormalizedResourceIdEquals -Left ([string]$snapshot.id) -Right $recordedSnapshotId)) {
                Assert-LimsAppMigControlFailure "Snapshot '$($snapshot.id)' does not match the recorded snapshot '$recordedSnapshotId'. Refusing to delete it."
            }
            Write-Output "Deleting snapshot '$($snapshot.id)' because DeleteSnapshot was explicitly requested."
            Remove-AzSnapshotAdapter -SubscriptionId $Environment.SubscriptionId -ResourceGroupName $Environment.ResourceGroupName -SnapshotName $names.SnapshotName
            $snapshotDeleted = $true
        }
        else {
            Write-Output "Snapshot '$($names.SnapshotName)' is already gone."
            $snapshotDeleted = $true
        }
    }
    else {
        if ($snapshot) {
            Write-Output "Retaining snapshot '$($snapshot.id)' (DeleteSnapshot is false). Record an explicit retention decision before deleting it."
        }
        else {
            Write-Output "No snapshot named '$($names.SnapshotName)' is present; nothing to retain."
        }
    }

    if ([string]::IsNullOrWhiteSpace($recordedRunId) -or $recordedRunId -eq $MigrationRunId) {
        Remove-AzResourceTagsAdapter -ResourceId $checks.DestinationVmId -TagKeys @(
            $tagKeys.RunId, $tagKeys.SnapshotId, $tagKeys.TempDiskId,
            $tagKeys.CaptureMode, $tagKeys.CopyStatus, $tagKeys.TemporaryLun
        )
    }

    Write-Output '===== LIMS APP data-disk migration: CLEANUP ====='
    Write-Output "Migration run ID            : $MigrationRunId"
    Write-Output "Temporary disk removed      : $(-not $decision.DiskAlreadyGone)"
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

    $environment = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName $EnvironmentName
    Assert-EnvironmentEnabledAndComplete -Environment $environment

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

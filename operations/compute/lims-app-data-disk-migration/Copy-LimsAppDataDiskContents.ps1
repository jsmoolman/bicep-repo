<#
.SYNOPSIS
    Guest-side copy of existing LIMS APP data-disk contents onto the
    replacement APP VM's A: volume.

.DESCRIPTION
    Delivered via Managed Run Command on APP v2 only. Identifies the
    destination A: disk by the attested UniqueId plus ARM resource ID and
    partition, and the snapshot-derived disk by ARM uniqueId matching
    Get-Disk UniqueId among non-OS disks. IMDS resourceDisk.size is not
    used. Dumps a read-only guest disk inventory and stops before Set-Disk
    or copy when that binding cannot be proven.

    Independently re-verifies destination identity (computer name + IMDS)
    against the reviewed environment mapping, then re-verifies the source
    (temporary) and destination (A:) volumes before any copy. When
    CollectInventoryOnly is true, prints the snapshot-derived disk Azure
    ID, LUN, and ARM UniqueId beside the Windows inventory (Write-Host,
    visible in Run Command even if identity match fails) and stops
    before any disk mutation or Robocopy.

    Copies with Robocopy /COPY:DAT /DCOPY:DAT /XJ (data, attributes,
    timestamps; never ACLs; never following reparse points). Includes
    temp and all other local application content. Explicitly excludes
    lv89\sdmshome. Applies v2 service permissions later -- not here.

    Writes the full Robocopy log on APP v2 and a compact summary to
    stdout. Interprets the Robocopy exit code, then runs a second
    list-only comparison. Fails on copy errors or unexplained
    differences. Does not start APP v2 services.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'tst', 'acc', 'preprd', 'prd')]
    [string] $EnvironmentName = 'dev',

    [Parameter(Mandatory = $false)]
    [string] $MigrationRunId = '',

    [Parameter(Mandatory = $false)]
    [int] $ExpectedTemporaryLun = -1,

    [Parameter(Mandatory = $false)]
    [string] $ExpectedTemporaryDiskName = '',

    [Parameter(Mandatory = $false)]
    [string] $ExpectedTemporaryDiskResourceId = '',

    [Parameter(Mandatory = $false)]
    [string] $ExpectedDestinationDiskResourceId = '',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $ExpectedTemporaryDiskUniqueId = '',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $ExpectedDestinationDiskUniqueId = '',

    [Parameter(Mandatory = $false)]
    [string] $CaptureMode = 'unspecified',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $CollectInventoryOnly = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# <LIMS_APP_MIG_MAPPING_INJECT>
# <LIMS_APP_MIG_SAFETY_INJECT>

function Import-LimsAppDataDiskMigrationMapping {
    if (-not (Get-Command Get-LimsAppDataDiskMigrationEnvironmentMapping -ErrorAction SilentlyContinue)) {
        $adjacent = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1'
        if (Test-Path -LiteralPath $adjacent) {
            . $adjacent
        }
        else {
            throw [System.InvalidOperationException]::new('The reviewed environment mapping was not loaded. Submit this script together with LimsAppDataDiskMigration.Mapping.ps1 (the pipeline concatenates them at the mapping-inject marker).')
        }
    }
    if (-not (Get-Command Resolve-GuestDiskIdentity -ErrorAction SilentlyContinue)) {
        $safety = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1'
        if (Test-Path -LiteralPath $safety) {
            . $safety
        }
        else {
            throw [System.InvalidOperationException]::new('Safety functions were not loaded. Submit this script together with LimsAppDataDiskMigration.Safety.ps1.')
        }
    }
}

function Assert-LimsAppMigCopyFailure {
    param([Parameter(Mandatory = $true)] [string] $Message)
    throw [System.InvalidOperationException]::new($Message)
}

function Write-GuestInspectLine {
    <#
        Host-visible inspect lines. Write-Output inside a function whose
        caller pipes to Out-Null is discarded; Run Command must still
        show the inventory when identity match fails.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Message)
    Write-Host $Message
}

function Write-GuestInspectEvidence {
    param(
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedTemporaryDiskResourceId = '',
        [Parameter(Mandatory = $false)] [int] $ExpectedTemporaryLun = -1,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedTemporaryDiskUniqueId = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedDestinationDiskResourceId = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedDestinationDiskUniqueId = '',
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $GuestDisks,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $MatchStatus = 'Pending',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $MatchDetail = ''
    )

    Write-GuestInspectLine '===== LIMS APP data-disk migration: ATTACH-AND-INSPECT (read-only) ====='
    Write-GuestInspectLine "Snapshot-derived disk Azure ID : $ExpectedTemporaryDiskResourceId"
    Write-GuestInspectLine "Snapshot-derived disk LUN      : $ExpectedTemporaryLun"
    Write-GuestInspectLine "Snapshot-derived ARM UniqueId  : $ExpectedTemporaryDiskUniqueId"
    Write-GuestInspectLine "Destination A: Azure ID        : $ExpectedDestinationDiskResourceId"
    Write-GuestInspectLine "Destination A: attested UniqueId: $ExpectedDestinationDiskUniqueId"
    Write-GuestInspectLine 'Windows disk inventory:'
    Write-GuestInspectLine (Format-GuestDiskInventoryEvidence -GuestDisks $GuestDisks)
    Write-GuestInspectLine "Identity match                 : $MatchStatus"
    if (-not [string]::IsNullOrWhiteSpace($MatchDetail)) {
        Write-GuestInspectLine $MatchDetail
    }
    Write-GuestInspectLine 'Disk left attached for review. No Set-Disk, Set-Partition, Initialize-Disk, Format-Volume, Robocopy, or Azure Files access.'
    Write-GuestInspectLine '=========================================================================='
}

# =============================================================================
# PURE DECISION LOGIC
# =============================================================================

function Test-VolumeRequiresInitializationOrFormat {
    <#
        Pure: any missing partition, RAW partition style, or missing/
        RAW/unknown filesystem means Windows would need Initialize-Disk
        or Format-Volume -- this script must fail instead of doing that.
    #>
    param(
        [Parameter(Mandatory = $true)] [bool] $HasPartition,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $PartitionStyle,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $FileSystem
    )

    if (-not $HasPartition) { return $true }
    if ([string]::IsNullOrWhiteSpace($PartitionStyle) -or $PartitionStyle -eq 'RAW') { return $true }
    if ([string]::IsNullOrWhiteSpace($FileSystem) -or $FileSystem -eq 'RAW' -or $FileSystem -eq 'Unknown') { return $true }
    return $false
}

function Select-UnusedDriveLetter {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $OccupiedLetters,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ReservedLetters,
        [Parameter(Mandatory = $true)] [string] $PreferredLetter
    )

    $blocked = @{}
    foreach ($letter in @($OccupiedLetters + $ReservedLetters)) {
        if (-not [string]::IsNullOrWhiteSpace($letter)) {
            $blocked[$letter.Trim().TrimEnd(':').ToUpperInvariant()] = $true
        }
    }

    $preferred = $PreferredLetter.Trim().TrimEnd(':').ToUpperInvariant()
    if ($preferred -and -not $blocked.ContainsKey($preferred)) {
        return [pscustomobject]@{ Accepted = $true; Letter = $preferred; Reason = $null }
    }

    foreach ($candidate in @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'P', 'Q', 'R', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F', 'E', 'B')) {
        if (-not $blocked.ContainsKey($candidate)) {
            return [pscustomobject]@{ Accepted = $true; Letter = $candidate; Reason = $null }
        }
    }

    return [pscustomobject]@{ Accepted = $false; Letter = $null; Reason = 'No unused drive letter remains after excluding A, C, D and every currently occupied letter.' }
}

function Test-DestinationCapacitySufficient {
    param(
        [Parameter(Mandatory = $true)] [int64] $RequiredBytes,
        [Parameter(Mandatory = $true)] [int64] $DestinationFreeBytes
    )
    return [bool]($DestinationFreeBytes -ge $RequiredBytes)
}

function Get-RobocopyCopyExitCodeClassification {
    <#
        Robocopy 0-3: copied / extra files or dirs, no error.
        4-7: mismatches. 8+: copy errors. This migration treats mismatches
        and errors as failure -- unexplained differences must not pass.
    #>
    param([Parameter(Mandatory = $true)] [int] $ExitCode)
    if ($ExitCode -lt 0) { return 'Failed' }
    if ($ExitCode -le 3) { return 'Succeeded' }
    return 'Failed'
}

function Get-RobocopyVerifyExitCodeClassification {
    <#
        After a successful copy, a list-only rerun must report 0 (nothing
        left to copy). Any extra, mismatched, or failed files are
        unexplained differences.
    #>
    param([Parameter(Mandatory = $true)] [int] $ExitCode)
    if ($ExitCode -eq 0) { return 'Identical' }
    return 'DifferencesRemain'
}

function Join-WindowsPath {
    <#
        Pure string join using Windows backslashes. Join-Path is not used
        because PowerShell 5.1 resolves the provider path and throws
        DriveNotFoundException for a drive letter that is not present on
        the machine running unit tests (and is unnecessary here).
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $BasePath,
        [Parameter(Mandatory = $true)] [string] $ChildPath
    )
    $baseTrim = $BasePath.TrimEnd('\', '/')
    $childTrim = $ChildPath.TrimStart('\', '/').Replace('/', '\')
    return "$baseTrim\$childTrim"
}

function New-RobocopyArgumentList {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationRoot,
        [Parameter(Mandatory = $true)] [string] $LogPath,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExcludeRelativePaths,
        [Parameter(Mandatory = $false)] [switch] $ListOnly
    )

    $arguments = @(
        $SourceRoot,
        $DestinationRoot,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/XJ',
        '/R:2',
        '/W:5',
        '/NP',
        '/TEE',
        "/LOG:$LogPath"
    )
    if ($ListOnly) {
        $arguments += '/L'
    }
    $excludeDirs = @()
    foreach ($relative in @($ExcludeRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($relative)) {
            $excludeDirs += (Join-WindowsPath -BasePath $SourceRoot -ChildPath $relative)
        }
    }
    if ($excludeDirs.Count -gt 0) {
        $arguments += '/XD'
        $arguments += $excludeDirs
    }
    return $arguments
}

# =============================================================================
# ADAPTERS
# =============================================================================

function Get-ActualComputerNameAdapter {
    return $env:COMPUTERNAME
}

function New-NoProxyWebSessionAdapter {
    $proxy = New-Object System.Net.WebProxy
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $webSession.Proxy = $proxy
    return $webSession
}

function Get-ImdsComputeMetadataAdapter {
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json'
    try {
        return Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -WebSession (New-NoProxyWebSessionAdapter) -TimeoutSec 15
    }
    catch {
        Assert-LimsAppMigCopyFailure "Unable to query the Azure Instance Metadata Service (IMDS) compute document: $($_.Exception.Message)"
    }
}

function Get-DisksAdapter {
    return @(Get-Disk)
}

function Get-GuestDiskInventoryAdapter {
    $disks = @(Get-DisksAdapter)
    $diskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive)
    $diskDrivesByIndex = @{}
    foreach ($dd in $diskDrives) { $diskDrivesByIndex[[int]$dd.Index] = $dd }
    $result = @()
    foreach ($disk in $disks) {
        $dd = $null
        if ($diskDrivesByIndex.ContainsKey([int]$disk.Number)) { $dd = $diskDrivesByIndex[[int]$disk.Number] }
        $result += [pscustomobject]@{
            Number          = [int]$disk.Number
            UniqueId        = [string]$disk.UniqueId
            IsBoot          = [bool]$disk.IsBoot
            IsSystem        = [bool]$disk.IsSystem
            IsOffline       = [bool]$disk.IsOffline
            IsReadOnly      = [bool]$disk.IsReadOnly
            PartitionStyle  = [string]$disk.PartitionStyle
            SizeBytes       = [int64]$disk.Size
            ScsiLogicalUnit = if ($dd) { [int]$dd.SCSILogicalUnit } else { -1 }
            Location        = [string]$disk.Location
        }
    }
    return $result
}

function Get-GuestPartitionInventoryAdapter {
    return @(Get-Partition | ForEach-Object {
            [pscustomobject]@{
                DiskNumber      = [int]$_.DiskNumber
                PartitionNumber = [int]$_.PartitionNumber
                DriveLetter     = if ($_.DriveLetter) { [string]$_.DriveLetter } else { '' }
                IsSystem        = [bool]$_.IsSystem
                IsBoot          = [bool]$_.IsBoot
            }
        })
}

function Get-LogicalDiskDriveTypeAdapter {
    param([Parameter(Mandatory = $true)] [string] $DriveLetter)
    $letter = $DriveLetter.Trim().TrimEnd(':')
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction SilentlyContinue
    if ($disk) { return [int]$disk.DriveType }
    return $null
}

function Test-PathIsReparsePointAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-PathTargetAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSObject.Properties['Target'] -and $item.Target) {
        return [string](@($item.Target)[0])
    }
    return ''
}

function Get-ChildEntriesAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
}

function Get-ReparseRelativePathsUnderRoot {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExcludeRelativePaths
    )

    $exclude = @{}
    foreach ($rel in @($ExcludeRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($rel)) {
            $exclude[$rel.Trim().TrimStart('\').ToLowerInvariant()] = $true
        }
    }

    $found = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $current = [string]$queue.Dequeue()
        foreach ($entry in @(Get-ChildEntriesAdapter -Path $current)) {
            $full = [string]$entry.FullName
            $relative = ConvertTo-RelativeWindowsPath -Root $Root -FullPath $full
            $isReparse = [bool]($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            $excludeHit = $exclude.ContainsKey($relative.ToLowerInvariant())
            if ($isReparse) {
                $found += $relative
                continue
            }
            if ($excludeHit) { continue }
            if ($entry.PSIsContainer) { $queue.Enqueue($full) }
        }
    }
    return $found
}

function Get-PartitionsAdapter {
    param([Parameter(Mandatory = $true)] [int] $DiskNumber)
    return @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
}

function Get-VolumeAdapter {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $DriveLetter,
        [Parameter(Mandatory = $false)] [AllowNull()] [int] $DiskNumber
    )
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        return Get-Volume -DriveLetter $DriveLetter.Trim().TrimEnd(':') -ErrorAction Stop
    }
    $partitions = Get-PartitionsAdapter -DiskNumber $DiskNumber
    foreach ($partition in $partitions) {
        if ($partition.DriveLetter) {
            return Get-Volume -DriveLetter $partition.DriveLetter -ErrorAction SilentlyContinue
        }
        $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.UniqueId -and $partition.AccessPaths -contains $_.Path })
        if ($vols.Count -eq 1) { return $vols[0] }
    }
    $byDisk = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue)
    if ($byDisk.Count -ge 1) { return $byDisk[0] }
    return $null
}

function Set-DiskOnlineWritableAdapter {
    param([Parameter(Mandatory = $true)] [int] $DiskNumber)
    Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop
}

function Set-PartitionDriveLetterAdapter {
    param(
        [Parameter(Mandatory = $true)] [int] $DiskNumber,
        [Parameter(Mandatory = $true)] [int] $PartitionNumber,
        [Parameter(Mandatory = $true)] [string] $DriveLetter
    )
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -NewDriveLetter $DriveLetter.Trim().TrimEnd(':') -ErrorAction Stop
}

function Get-OccupiedDriveLettersAdapter {
    $letters = @()
    foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue)) {
        if ($volume.DriveLetter) {
            $letters += ([string]$volume.DriveLetter).ToUpperInvariant()
        }
    }
    return $letters
}

function Test-PathExistsAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    return [bool](Test-Path -LiteralPath $Path)
}

function New-DirectoryAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-PathExistsAdapter -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-RobocopyAdapter {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    return [int]$process.ExitCode
}

# =============================================================================
# ORCHESTRATION
# =============================================================================

function Assert-CopyTargetIdentity {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $CallerEnvironmentName,
        [Parameter(Mandatory = $true)] [int] $CallerTemporaryLun,
        [Parameter(Mandatory = $true)] [string] $CallerTemporaryDiskName
    )

    if ($CallerEnvironmentName -ne $Environment.EnvironmentName) {
        Assert-LimsAppMigCopyFailure "Caller environment '$CallerEnvironmentName' does not match the mapping environment '$($Environment.EnvironmentName)'."
    }
    if (-not $Environment.Enabled) {
        Assert-LimsAppMigCopyFailure "Environment '$($Environment.EnvironmentName)' is not enabled in the reviewed mapping."
    }
    if ($CallerTemporaryLun -ne [int]$Environment.PreferredTemporaryLun) {
        Assert-LimsAppMigCopyFailure "Caller temporary LUN $CallerTemporaryLun does not match the mapped preferred temporary LUN $($Environment.PreferredTemporaryLun)."
    }
    $expectedTempName = "$($Environment.TemporaryDiskNamePrefix)-tmp"
    if ($CallerTemporaryDiskName -ne $expectedTempName) {
        Assert-LimsAppMigCopyFailure "Caller temporary disk name '$CallerTemporaryDiskName' does not match the environment lock disk '$expectedTempName'."
    }

    $actualComputerName = Get-ActualComputerNameAdapter
    if ($actualComputerName -ne $Environment.DestinationComputerName) {
        Assert-LimsAppMigCopyFailure "Guest computer name '$actualComputerName' does not match the mapped destination '$($Environment.DestinationComputerName)'. Refusing to proceed."
    }

    $imdsCompute = Get-ImdsComputeMetadataAdapter
    if ([string]::IsNullOrWhiteSpace([string]$imdsCompute.subscriptionId) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.resourceGroupName) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.name)) {
        Assert-LimsAppMigCopyFailure 'IMDS returned incomplete compute identity metadata (missing subscriptionId, resourceGroupName, or name).'
    }
    if ([string]$imdsCompute.subscriptionId -ne $Environment.SubscriptionId) {
        Assert-LimsAppMigCopyFailure "IMDS subscription ID '$($imdsCompute.subscriptionId)' does not match the mapped destination '$($Environment.SubscriptionId)'."
    }
    if ([string]$imdsCompute.resourceGroupName -ne $Environment.ResourceGroupName) {
        Assert-LimsAppMigCopyFailure "IMDS resource group '$($imdsCompute.resourceGroupName)' does not match the mapped destination '$($Environment.ResourceGroupName)'."
    }
    if ([string]$imdsCompute.name -ne $Environment.DestinationVmName) {
        Assert-LimsAppMigCopyFailure "IMDS VM name '$($imdsCompute.name)' does not match the mapped destination '$($Environment.DestinationVmName)'."
    }

    return $imdsCompute
}

function Assert-ResolvedDiskIdentities {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedTemporaryDiskResourceId,
        [Parameter(Mandatory = $true)] [int] $ExpectedTemporaryLun,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $ExpectedTemporaryDiskUniqueId,
        [Parameter(Mandatory = $true)] [string] $ExpectedDestinationDiskResourceId,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $ExpectedDestinationDiskUniqueId
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedTemporaryDiskResourceId) -or [string]::IsNullOrWhiteSpace($ExpectedDestinationDiskResourceId)) {
        Assert-LimsAppMigCopyFailure 'Guest copy requires the exact Azure managed-disk resource IDs for the temporary snapshot disk and the destination A: disk. Name, LUN, letter, or label alone is insufficient.'
    }

    $guestDisks = @(Get-GuestDiskInventoryAdapter)
    $partitions = @(Get-GuestPartitionInventoryAdapter)

    $destUnique = $ExpectedDestinationDiskUniqueId
    if ([string]::IsNullOrWhiteSpace($destUnique)) { $destUnique = $Environment.DestinationAttestedGuestUniqueId }
    $dest = Resolve-GuestDiskIdentity -ImdsCompute $ImdsCompute -GuestDisks $guestDisks -ExpectedManagedDiskId $ExpectedDestinationDiskResourceId -ExpectedLun ([int]$Environment.DestinationDataDiskLun) -ExpectedUniqueId $destUnique -Role 'Destination A:'
    if (-not $dest.Resolved) {
        Assert-LimsAppMigCopyFailure $dest.Reason
    }

    $volume = Get-VolumeAdapter -DriveLetter $Environment.DestinationDriveLetter
    $label = $null
    if ($volume) { $label = [string]$volume.FileSystemLabel }
    $letterProof = Test-DriveLetterOnResolvedDisk -DriveLetter $Environment.DestinationDriveLetter -ExpectedDiskNumber ([int]$dest.Disk.Number) -Partitions $partitions -ExpectedLabel $Environment.DestinationVolumeLabel -VolumeLabel $label -Role 'Destination A:'
    if (-not $letterProof.Matches) {
        Assert-LimsAppMigCopyFailure $letterProof.Reason
    }

    $temp = Resolve-GuestDiskIdentity -ImdsCompute $ImdsCompute -GuestDisks $guestDisks -ExpectedManagedDiskId $ExpectedTemporaryDiskResourceId -ExpectedLun $ExpectedTemporaryLun -ExpectedUniqueId $ExpectedTemporaryDiskUniqueId -Role 'Temporary snapshot disk'
    if (-not $temp.Resolved) {
        Assert-LimsAppMigCopyFailure $temp.Reason
    }

    return [pscustomobject]@{
        DestinationDisk      = $dest.Disk
        DestinationPartition = $letterProof.Partition
        DestinationVolume    = $volume
        TemporaryDisk        = $temp.Disk
    }
}

function Assert-GuestDiskStillMatches {
    param(
        [Parameter(Mandatory = $true)] $Disk,
        [Parameter(Mandatory = $true)] [string] $Role
    )
    if ([string]::IsNullOrWhiteSpace([string]$Disk.UniqueId)) {
        Assert-LimsAppMigCopyFailure "$Role Windows disk $($Disk.Number) has an empty UniqueId. Refusing to change disk state."
    }
    $live = @(Get-GuestDiskInventoryAdapter | Where-Object {
            $_.Number -eq $Disk.Number -and (Test-NormalizedUniqueIdEquals -Left ([string]$_.UniqueId) -Right ([string]$Disk.UniqueId))
        })
    if ($live.Count -ne 1) {
        Assert-LimsAppMigCopyFailure "$Role UniqueId '$($Disk.UniqueId)' is no longer uniquely Windows disk $($Disk.Number). Refusing to change disk state. Evidence needed: Get-Disk UniqueId still matching the resolved managed disk."
    }
    return $live[0]
}

function Set-TemporarySnapshotVolumePresented {
    param(
        [Parameter(Mandatory = $true)] $Disk,
        [Parameter(Mandatory = $true)] $Environment
    )

    $Disk = Assert-GuestDiskStillMatches -Disk $Disk -Role 'Temporary snapshot disk'
    if ($Disk.IsOffline -or $Disk.IsReadOnly) {
        Set-DiskOnlineWritableAdapter -DiskNumber ([int]$Disk.Number)
        $Disk = Assert-GuestDiskStillMatches -Disk $Disk -Role 'Temporary snapshot disk after Set-Disk'
    }

    $partitions = @(Get-PartitionsAdapter -DiskNumber ([int]$Disk.Number) | Where-Object { -not $_.IsSystem -and -not $_.IsBoot })
    $hasPartition = $partitions.Count -gt 0
    $fileSystem = $null
    $volume = $null
    if ($hasPartition) {
        $volume = Get-VolumeAdapter -DiskNumber ([int]$Disk.Number)
        if ($volume) { $fileSystem = [string]$volume.FileSystem }
    }

    if (Test-VolumeRequiresInitializationOrFormat -HasPartition $hasPartition -PartitionStyle ([string]$Disk.PartitionStyle) -FileSystem $fileSystem) {
        Assert-LimsAppMigCopyFailure "Temporary snapshot disk Number $($Disk.Number) has no existing usable volume (partitionStyle='$($Disk.PartitionStyle)', fileSystem='$fileSystem'). Refusing to Initialize-Disk or Format-Volume."
    }

    $occupied = @(Get-OccupiedDriveLettersAdapter)
    $letter = $null
    if ($volume -and $volume.DriveLetter) {
        $letter = ([string]$volume.DriveLetter).ToUpperInvariant()
        if ($Environment.ReservedDriveLetters -contains $letter) {
            Assert-LimsAppMigCopyFailure "Temporary snapshot volume already has reserved drive letter ${letter}:. Refusing to use $($Environment.DestinationDriveLetter):/C:/D: as the source."
        }
    }
    else {
        $selection = Select-UnusedDriveLetter -OccupiedLetters $occupied -ReservedLetters @($Environment.ReservedDriveLetters) -PreferredLetter $Environment.PreferredTemporaryDriveLetter
        if (-not $selection.Accepted) {
            Assert-LimsAppMigCopyFailure $selection.Reason
        }
        $dataPartition = $partitions | Select-Object -First 1
        $null = Assert-GuestDiskStillMatches -Disk $Disk -Role 'Temporary snapshot disk before Set-Partition'
        Set-PartitionDriveLetterAdapter -DiskNumber ([int]$Disk.Number) -PartitionNumber ([int]$dataPartition.PartitionNumber) -DriveLetter $selection.Letter
        $letter = $selection.Letter
        $volume = Get-VolumeAdapter -DriveLetter $letter
    }

    return [pscustomobject]@{
        DriveLetter = $letter
        Volume      = $volume
        DiskNumber  = [int]$Disk.Number
    }
}

function Get-CopyByteRequirement {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExcludeRelativePaths
    )

    $exclude = @{}
    foreach ($rel in @($ExcludeRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($rel)) {
            $exclude[$rel.Trim().TrimStart('\').ToLowerInvariant()] = $true
        }
    }

    $total = [int64]0
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($SourceRoot)
    while ($queue.Count -gt 0) {
        $current = [string]$queue.Dequeue()
        foreach ($entry in @(Get-ChildEntriesAdapter -Path $current)) {
            $full = [string]$entry.FullName
            $relative = ConvertTo-RelativeWindowsPath -Root $SourceRoot -FullPath $full
            if ($exclude.ContainsKey($relative.ToLowerInvariant())) { continue }
            $isReparse = [bool]($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparse) { continue }
            if ($entry.PSIsContainer) {
                $queue.Enqueue($full)
            }
            else {
                $length = [int64]0
                if ($entry.PSObject.Properties['Length'] -and $null -ne $entry.Length) {
                    $length = [int64]$entry.Length
                }
                $total += $length
            }
        }
    }
    return $total
}

function Write-LimsAppDataDiskCopySummary {
    param([Parameter(Mandatory = $true)] $Summary)

    Write-Output '===== LIMS APP data-disk migration: GUEST COPY ====='
    Write-Output "Migration run ID     : $($Summary.MigrationRunId)"
    Write-Output "Capture mode         : $($Summary.CaptureMode)"
    Write-Output "Source volume        : $($Summary.SourceRoot)"
    Write-Output "Destination volume   : $($Summary.DestinationRoot)"
    Write-Output "Exclude              : $($Summary.ExcludeRelativePaths -join ', ')"
    Write-Output "Robocopy log         : $($Summary.LogPath)"
    Write-Output "Preview exit code    : $($Summary.PreviewExitCode) ($($Summary.PreviewClassification))"
    Write-Output "Copy exit code       : $($Summary.CopyExitCode) ($($Summary.CopyClassification))"
    Write-Output "Verify exit code     : $($Summary.VerifyExitCode) ($($Summary.VerifyClassification))"
    Write-Output "Required bytes       : $($Summary.RequiredBytes)"
    Write-Output "Destination free     : $($Summary.DestinationFreeBytes)"
    Write-Output 'APP v2 services      : left stopped pending JDBC/UNC/Apache/Shibboleth review'
    Write-Output '===================================================='
}

function Assert-CopyRootsAndReparsePolicy {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationRoot,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExcludeRelativePaths
    )

    foreach ($root in @($SourceRoot, $DestinationRoot)) {
        $driveType = Get-LogicalDiskDriveTypeAdapter -DriveLetter $root.Substring(0, 1)
        $isReparse = Test-PathIsReparsePointAdapter -Path $root
        $target = Get-PathTargetAdapter -Path $root
        $local = Test-CopyRootIsLocalVolume -RootPath $root -RootTarget $target -DriveType $driveType -IsReparsePoint $isReparse
        if (-not $local.Local) {
            Assert-LimsAppMigCopyFailure $local.Reason
        }
    }

    $sourceReparse = @(Get-ReparseRelativePathsUnderRoot -Root $SourceRoot -ExcludeRelativePaths $ExcludeRelativePaths)
    $destReparse = @(Get-ReparseRelativePathsUnderRoot -Root $DestinationRoot -ExcludeRelativePaths $ExcludeRelativePaths)
    $policy = Test-ReparsePointPolicy -SourceReparseRelativePaths $sourceReparse -DestinationReparseRelativePaths $destReparse -ExcludeRelativePaths $ExcludeRelativePaths
    if (-not $policy.Accepted) {
        Assert-LimsAppMigCopyFailure $policy.Reason
    }
}

function Invoke-LimsAppDataDiskContentsCopy {
    param(
        [Parameter(Mandatory = $true)] [string] $EnvironmentName,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [int] $ExpectedTemporaryLun,
        [Parameter(Mandatory = $true)] [string] $ExpectedTemporaryDiskName,
        [Parameter(Mandatory = $false)] [string] $ExpectedTemporaryDiskResourceId = '',
        [Parameter(Mandatory = $false)] [string] $ExpectedDestinationDiskResourceId = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedTemporaryDiskUniqueId = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $ExpectedDestinationDiskUniqueId = '',
        [Parameter(Mandatory = $false)] [string] $CaptureMode = 'unspecified',
        [Parameter(Mandatory = $false)] [switch] $CollectInventoryOnly
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) {
        Assert-LimsAppMigCopyFailure $runIdCheck.Reason
    }

    Import-LimsAppDataDiskMigrationMapping
    $environment = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName $EnvironmentName

    if ([string]::IsNullOrWhiteSpace($ExpectedDestinationDiskResourceId)) {
        $ExpectedDestinationDiskResourceId = "/subscriptions/$($environment.SubscriptionId)/resourceGroups/$($environment.ResourceGroupName)/providers/Microsoft.Compute/disks/$($environment.DestinationDataDiskName)"
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedDestinationDiskUniqueId)) {
        $ExpectedDestinationDiskUniqueId = $environment.DestinationAttestedGuestUniqueId
    }

    try {
        $imdsCompute = Assert-CopyTargetIdentity -Environment $environment -CallerEnvironmentName $EnvironmentName -CallerTemporaryLun $ExpectedTemporaryLun -CallerTemporaryDiskName $ExpectedTemporaryDiskName
    }
    catch {
        Write-GuestInspectEvidence -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -GuestDisks @(Get-GuestDiskInventoryAdapter) -MatchStatus 'FAILED' -MatchDetail $_.Exception.Message
        throw
    }

    $inventory = @(Get-GuestDiskInventoryAdapter)
    Write-GuestInspectEvidence -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -GuestDisks $inventory -MatchStatus 'Pending' -MatchDetail 'Binding is ARM uniqueId / attested UniqueId matching Get-Disk UniqueId among non-OS disks. IMDS resourceDisk.size is not used (DEV size discrepancy / LUN 1 collision).'

    try {
        $identities = Assert-ResolvedDiskIdentities -Environment $environment -ImdsCompute $imdsCompute -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId
    }
    catch {
        Write-GuestInspectEvidence -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -GuestDisks @(Get-GuestDiskInventoryAdapter) -MatchStatus 'FAILED' -MatchDetail $_.Exception.Message
        throw
    }

    if ($CollectInventoryOnly) {
        $destinationUniqueId = [string]$identities.DestinationDisk.UniqueId
        $aColonMatches = Test-NormalizedUniqueIdEquals -Left $destinationUniqueId -Right $environment.DestinationAttestedGuestUniqueId
        $matchDetail = "Destination A: Windows disk $($identities.DestinationDisk.Number) UniqueId='$destinationUniqueId' is bound to '$ExpectedDestinationDiskResourceId'. Temporary snapshot Windows disk $($identities.TemporaryDisk.Number) UniqueId='$($identities.TemporaryDisk.UniqueId)' is bound to '$ExpectedTemporaryDiskResourceId'."
        if (-not $aColonMatches) {
            Write-GuestInspectEvidence -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -GuestDisks @(Get-GuestDiskInventoryAdapter) -MatchStatus 'FAILED' -MatchDetail "A: UniqueId '$destinationUniqueId' does not resolve to the attested value '$($environment.DestinationAttestedGuestUniqueId)'."
            Assert-LimsAppMigCopyFailure "A: UniqueId '$destinationUniqueId' does not resolve to the attested value '$($environment.DestinationAttestedGuestUniqueId)'."
        }
        Write-GuestInspectEvidence -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -GuestDisks @(Get-GuestDiskInventoryAdapter) -MatchStatus 'PASSED' -MatchDetail "$matchDetail A: resolves to $($environment.DestinationAttestedGuestUniqueId). CollectInventoryOnly: stopping before Set-Disk, Set-Partition, or Robocopy."
        return [pscustomobject]@{
            Status            = 'InventoryOnly'
            DestinationDisk   = $identities.DestinationDisk
            TemporaryDisk     = $identities.TemporaryDisk
            DestinationVolume = $identities.DestinationVolume
        }
    }

    $presented = Set-TemporarySnapshotVolumePresented -Disk $identities.TemporaryDisk -Environment $environment

    $identities = Assert-ResolvedDiskIdentities -Environment $environment -ImdsCompute $imdsCompute -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId
    $sourceLetterProof = Test-DriveLetterOnResolvedDisk -DriveLetter $presented.DriveLetter -ExpectedDiskNumber ([int]$identities.TemporaryDisk.Number) -Partitions @(Get-GuestPartitionInventoryAdapter) -ExpectedLabel $null -VolumeLabel $null -Role 'Temporary snapshot volume'
    if (-not $sourceLetterProof.Matches) {
        Assert-LimsAppMigCopyFailure $sourceLetterProof.Reason
    }

    $sourceRoot = "$($presented.DriveLetter):\"
    $destinationRoot = "$($environment.DestinationDriveLetter):\"
    if (-not (Test-PathExistsAdapter -Path $sourceRoot)) {
        Assert-LimsAppMigCopyFailure "Presented source volume '$sourceRoot' is not reachable."
    }
    if (-not (Test-PathExistsAdapter -Path $destinationRoot)) {
        Assert-LimsAppMigCopyFailure "Destination volume '$destinationRoot' is not reachable."
    }

    Assert-CopyRootsAndReparsePolicy -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -ExcludeRelativePaths @($environment.ExcludeRelativePaths)

    $logDirectory = $environment.RobocopyLogDirectory
    New-DirectoryAdapter -Path $logDirectory
    $logPath = Join-WindowsPath -BasePath $logDirectory -ChildPath "robocopy-$MigrationRunId.log"

    $requiredBytes = Get-CopyByteRequirement -SourceRoot $sourceRoot -ExcludeRelativePaths @($environment.ExcludeRelativePaths)
    $destinationFree = [int64]$identities.DestinationVolume.SizeRemaining
    if (-not (Test-DestinationCapacitySufficient -RequiredBytes $requiredBytes -DestinationFreeBytes $destinationFree)) {
        Assert-LimsAppMigCopyFailure "Destination $($environment.DestinationDriveLetter): has $destinationFree bytes free, which is less than the $requiredBytes bytes required (after excluding $($environment.ExcludeRelativePaths -join ', ')). Refusing to copy."
    }

    $previewArgs = New-RobocopyArgumentList -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -LogPath $logPath -ExcludeRelativePaths @($environment.ExcludeRelativePaths) -ListOnly
    $previewExit = Invoke-RobocopyAdapter -Arguments $previewArgs
    $previewClass = Get-RobocopyCopyExitCodeClassification -ExitCode $previewExit
    if ($previewClass -ne 'Succeeded') {
        Assert-LimsAppMigCopyFailure "Robocopy preview failed with exit code $previewExit. Full log: $logPath"
    }

    $identities = Assert-ResolvedDiskIdentities -Environment $environment -ImdsCompute $imdsCompute -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId
    $sourceLetterProof = Test-DriveLetterOnResolvedDisk -DriveLetter $presented.DriveLetter -ExpectedDiskNumber ([int]$identities.TemporaryDisk.Number) -Partitions @(Get-GuestPartitionInventoryAdapter) -ExpectedLabel $null -VolumeLabel $null -Role 'Temporary snapshot volume'
    if (-not $sourceLetterProof.Matches) {
        Assert-LimsAppMigCopyFailure $sourceLetterProof.Reason
    }
    Assert-CopyRootsAndReparsePolicy -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -ExcludeRelativePaths @($environment.ExcludeRelativePaths)

    $copyArgs = New-RobocopyArgumentList -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -LogPath $logPath -ExcludeRelativePaths @($environment.ExcludeRelativePaths)
    $copyExit = Invoke-RobocopyAdapter -Arguments $copyArgs
    $copyClass = Get-RobocopyCopyExitCodeClassification -ExitCode $copyExit
    if ($copyClass -ne 'Succeeded') {
        Assert-LimsAppMigCopyFailure "Robocopy copy failed with exit code $copyExit. Full log: $logPath"
    }

    $verifyLogPath = Join-WindowsPath -BasePath $logDirectory -ChildPath "robocopy-$MigrationRunId.verify.log"
    $verifyArgs = New-RobocopyArgumentList -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -LogPath $verifyLogPath -ExcludeRelativePaths @($environment.ExcludeRelativePaths) -ListOnly
    $verifyExit = Invoke-RobocopyAdapter -Arguments $verifyArgs
    $verifyClass = Get-RobocopyVerifyExitCodeClassification -ExitCode $verifyExit
    if ($verifyClass -ne 'Identical') {
        Assert-LimsAppMigCopyFailure "Second Robocopy comparison reported unexplained differences (exit code $verifyExit, classification $verifyClass). Full verify log: $verifyLogPath"
    }

    $summary = [pscustomobject]@{
        MigrationRunId          = $MigrationRunId
        CaptureMode             = $CaptureMode
        SourceRoot              = $sourceRoot
        DestinationRoot         = $destinationRoot
        ExcludeRelativePaths    = @($environment.ExcludeRelativePaths)
        LogPath                 = $logPath
        PreviewExitCode         = $previewExit
        PreviewClassification   = $previewClass
        CopyExitCode            = $copyExit
        CopyClassification      = $copyClass
        VerifyExitCode          = $verifyExit
        VerifyClassification    = $verifyClass
        RequiredBytes           = $requiredBytes
        DestinationFreeBytes    = $destinationFree
        Status                  = 'Succeeded'
    }
    Write-LimsAppDataDiskCopySummary -Summary $summary
    return $summary
}

if ($env:LIMS_APP_MIG_COPY_DOT_SOURCE_ONLY -ne '1') {
    try {
        $inspectOnly = Test-CollectInventoryOnlyFlag -Value $CollectInventoryOnly
        Invoke-LimsAppDataDiskContentsCopy -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskName $ExpectedTemporaryDiskName -ExpectedTemporaryDiskResourceId $ExpectedTemporaryDiskResourceId -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedTemporaryDiskUniqueId $ExpectedTemporaryDiskUniqueId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -CaptureMode $CaptureMode -CollectInventoryOnly:$inspectOnly | Out-Null
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

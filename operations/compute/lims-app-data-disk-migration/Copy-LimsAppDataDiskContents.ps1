<#
.SYNOPSIS
    Guest-side copy of existing LIMS APP data-disk contents onto the
    replacement APP VM's A: volume.

.DESCRIPTION
    Delivered via Managed Run Command on APP v2 only. Identifies the
    temporary snapshot disk by the verified Azure LUN/name attachment,
    presents its existing volume under an unused drive letter, and fails
    closed if Windows would require initialization or formatting.

    Independently re-verifies destination identity (computer name + IMDS)
    against the reviewed environment mapping, then re-verifies the source
    (temporary) and destination (A:) volumes before any copy.

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
    [string] $CaptureMode = 'unspecified'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# <LIMS_APP_MIG_MAPPING_INJECT>

function Import-LimsAppDataDiskMigrationMapping {
    if (Get-Command Get-LimsAppDataDiskMigrationEnvironmentMapping -ErrorAction SilentlyContinue) {
        return
    }
    $adjacent = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1'
    if (Test-Path -LiteralPath $adjacent) {
        . $adjacent
        return
    }
    throw [System.InvalidOperationException]::new('The reviewed environment mapping was not loaded. Submit this script together with LimsAppDataDiskMigration.Mapping.ps1 (the pipeline concatenates them at the mapping-inject marker).')
}

function Assert-LimsAppMigCopyFailure {
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

function Get-ImdsDataDiskByNameAndLun {
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedDiskName,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun
    )

    if (-not $ImdsCompute.storageProfile -or -not $ImdsCompute.storageProfile.dataDisks) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = 'IMDS compute document has no storageProfile.dataDisks.' }
    }

    $diskMatches = @()
    foreach ($disk in @($ImdsCompute.storageProfile.dataDisks)) {
        $name = [string]$disk.name
        if ([string]::IsNullOrWhiteSpace($name) -and $disk.managedDisk -and $disk.managedDisk.id) {
            $name = Get-ResourceNameFromId -ResourceId ([string]$disk.managedDisk.id)
        }
        $lun = [int]$disk.lun
        if ($name -eq $ExpectedDiskName -and $lun -eq $ExpectedLun) {
            $diskMatches += $disk
        }
    }

    if ($diskMatches.Count -eq 0) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = "IMDS has no data disk named '$ExpectedDiskName' at LUN $ExpectedLun." }
    }
    if ($diskMatches.Count -gt 1) {
        return [pscustomobject]@{ Matches = $false; Disk = $null; Reason = "IMDS reports more than one data disk named '$ExpectedDiskName' at LUN $ExpectedLun." }
    }
    return [pscustomobject]@{ Matches = $true; Disk = $diskMatches[0]; Reason = $null }
}

function Test-DiskLocationMatchesLun {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Location,
        [Parameter(Mandatory = $true)] [int] $ExpectedLun
    )
    if ([string]::IsNullOrWhiteSpace($Location)) { return $false }
    return [bool]($Location -match ("LUN\s+$ExpectedLun(?:\D|$)"))
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

function Get-ItemSizeBytesAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item.PSIsContainer) {
        $sum = [int64]0
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_.PSIsContainer) { $sum += [int64]$_.Length }
        }
        return $sum
    }
    return [int64]$item.Length
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
    if ($CallerTemporaryDiskName -notlike "$($Environment.TemporaryDiskNamePrefix)-*-tmp") {
        Assert-LimsAppMigCopyFailure "Caller temporary disk name '$CallerTemporaryDiskName' does not match the mapped prefix '$($Environment.TemporaryDiskNamePrefix)'."
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

function Resolve-TemporaryDiskNumber {
    param(
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedTemporaryDiskName,
        [Parameter(Mandatory = $true)] [int] $ExpectedTemporaryLun
    )

    $imdsDisk = Get-ImdsDataDiskByNameAndLun -ImdsCompute $ImdsCompute -ExpectedDiskName $ExpectedTemporaryDiskName -ExpectedLun $ExpectedTemporaryLun
    if (-not $imdsDisk.Matches) {
        Assert-LimsAppMigCopyFailure $imdsDisk.Reason
    }

    $candidates = @()
    foreach ($disk in @(Get-DisksAdapter)) {
        if ($disk.IsBoot -or $disk.IsSystem) { continue }
        if (Test-DiskLocationMatchesLun -Location ([string]$disk.Location) -ExpectedLun $ExpectedTemporaryLun) {
            $candidates += $disk
        }
    }
    if ($candidates.Count -eq 0) {
        Assert-LimsAppMigCopyFailure "No guest disk reports Location LUN $ExpectedTemporaryLun. Refusing to guess the temporary snapshot disk."
    }
    if ($candidates.Count -gt 1) {
        Assert-LimsAppMigCopyFailure "More than one guest disk reports Location LUN $ExpectedTemporaryLun. Refusing to guess."
    }
    return $candidates[0]
}

function Assert-DestinationVolumeMatchesMapping {
    param([Parameter(Mandatory = $true)] $Environment, [Parameter(Mandatory = $true)] $ImdsCompute)

    $imdsDest = Get-ImdsDataDiskByNameAndLun -ImdsCompute $ImdsCompute -ExpectedDiskName $Environment.DestinationDataDiskName -ExpectedLun ([int]$Environment.DestinationDataDiskLun)
    if (-not $imdsDest.Matches) {
        Assert-LimsAppMigCopyFailure "Destination volume mapping failed: $($imdsDest.Reason)"
    }

    $volume = Get-VolumeAdapter -DriveLetter $Environment.DestinationDriveLetter
    if ($null -eq $volume) {
        Assert-LimsAppMigCopyFailure "Destination volume $($Environment.DestinationDriveLetter): was not found."
    }
    if ([string]$volume.FileSystemLabel -ne $Environment.DestinationVolumeLabel) {
        Assert-LimsAppMigCopyFailure "Destination volume $($Environment.DestinationDriveLetter): label '$($volume.FileSystemLabel)' does not match '$($Environment.DestinationVolumeLabel)'."
    }
    return $volume
}

function Set-TemporarySnapshotVolumePresented {
    param(
        [Parameter(Mandatory = $true)] $Disk,
        [Parameter(Mandatory = $true)] $Environment
    )

    if ($Disk.IsOffline -or $Disk.IsReadOnly) {
        Set-DiskOnlineWritableAdapter -DiskNumber ([int]$Disk.Number)
        $refreshed = @(Get-DisksAdapter | Where-Object { $_.Number -eq $Disk.Number })
        if ($refreshed.Count -eq 1) { $Disk = $refreshed[0] }
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

    $total = Get-ItemSizeBytesAdapter -Path $SourceRoot
    foreach ($relative in @($ExcludeRelativePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($relative)) {
            $excludedPath = Join-WindowsPath -BasePath $SourceRoot -ChildPath $relative
            $total -= Get-ItemSizeBytesAdapter -Path $excludedPath
        }
    }
    if ($total -lt 0) { $total = [int64]0 }
    return [int64]$total
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

function Invoke-LimsAppDataDiskContentsCopy {
    param(
        [Parameter(Mandatory = $true)] [string] $EnvironmentName,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [int] $ExpectedTemporaryLun,
        [Parameter(Mandatory = $true)] [string] $ExpectedTemporaryDiskName,
        [Parameter(Mandatory = $false)] [string] $CaptureMode = 'unspecified'
    )

    if ([string]::IsNullOrWhiteSpace($MigrationRunId)) {
        Assert-LimsAppMigCopyFailure 'MigrationRunId is required.'
    }

    Import-LimsAppDataDiskMigrationMapping
    $environment = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName $EnvironmentName
    $imdsCompute = Assert-CopyTargetIdentity -Environment $environment -CallerEnvironmentName $EnvironmentName -CallerTemporaryLun $ExpectedTemporaryLun -CallerTemporaryDiskName $ExpectedTemporaryDiskName

    $destinationVolume = Assert-DestinationVolumeMatchesMapping -Environment $environment -ImdsCompute $imdsCompute
    $tempDisk = Resolve-TemporaryDiskNumber -ImdsCompute $imdsCompute -ExpectedTemporaryDiskName $ExpectedTemporaryDiskName -ExpectedTemporaryLun $ExpectedTemporaryLun
    $presented = Set-TemporarySnapshotVolumePresented -Disk $tempDisk -Environment $environment

    $sourceRoot = "$($presented.DriveLetter):\"
    $destinationRoot = "$($environment.DestinationDriveLetter):\"
    if (-not (Test-PathExistsAdapter -Path $sourceRoot)) {
        Assert-LimsAppMigCopyFailure "Presented source volume '$sourceRoot' is not reachable."
    }
    if (-not (Test-PathExistsAdapter -Path $destinationRoot)) {
        Assert-LimsAppMigCopyFailure "Destination volume '$destinationRoot' is not reachable."
    }

    $logDirectory = $environment.RobocopyLogDirectory
    New-DirectoryAdapter -Path $logDirectory
    $logPath = Join-Path $logDirectory "robocopy-$MigrationRunId.log"

    $requiredBytes = Get-CopyByteRequirement -SourceRoot $sourceRoot -ExcludeRelativePaths @($environment.ExcludeRelativePaths)
    $destinationFree = [int64]$destinationVolume.SizeRemaining
    if (-not (Test-DestinationCapacitySufficient -RequiredBytes $requiredBytes -DestinationFreeBytes $destinationFree)) {
        Assert-LimsAppMigCopyFailure "Destination $($environment.DestinationDriveLetter): has $destinationFree bytes free, which is less than the $requiredBytes bytes required (after excluding $($environment.ExcludeRelativePaths -join ', ')). Refusing to copy."
    }

    $previewArgs = New-RobocopyArgumentList -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -LogPath $logPath -ExcludeRelativePaths @($environment.ExcludeRelativePaths) -ListOnly
    $previewExit = Invoke-RobocopyAdapter -Arguments $previewArgs
    $previewClass = Get-RobocopyCopyExitCodeClassification -ExitCode $previewExit
    if ($previewClass -ne 'Succeeded') {
        Assert-LimsAppMigCopyFailure "Robocopy preview failed with exit code $previewExit. Full log: $logPath"
    }

    $copyArgs = New-RobocopyArgumentList -SourceRoot $sourceRoot -DestinationRoot $destinationRoot -LogPath $logPath -ExcludeRelativePaths @($environment.ExcludeRelativePaths)
    $copyExit = Invoke-RobocopyAdapter -Arguments $copyArgs
    $copyClass = Get-RobocopyCopyExitCodeClassification -ExitCode $copyExit
    if ($copyClass -ne 'Succeeded') {
        Assert-LimsAppMigCopyFailure "Robocopy copy failed with exit code $copyExit. Full log: $logPath"
    }

    $verifyLogPath = Join-Path $logDirectory "robocopy-$MigrationRunId.verify.log"
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
        Invoke-LimsAppDataDiskContentsCopy -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -ExpectedTemporaryLun $ExpectedTemporaryLun -ExpectedTemporaryDiskName $ExpectedTemporaryDiskName -CaptureMode $CaptureMode | Out-Null
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

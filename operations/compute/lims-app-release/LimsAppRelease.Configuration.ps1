<#
    Retained APP release decisions: destination-disk identity, account,
    service, Azure Files link, and scheduled-task checks.

    No snapshot, temporary disk, lock, Robocopy, or copy-completion
    decision lives here. Get-LimsAppReleaseExecutionDecision refuses
    every release action. A snapshot-copy completion marker is not
    authorization.
#>

Set-StrictMode -Version Latest

function Get-LimsAppReleaseExecutionDecision {
    <#
        Capture, deployment, configuration, and activation stay refused
        until release prerequisites and exact-target checks exist.
    #>
    param([Parameter(Mandatory = $true)] [string] $Action)

    $supported = @('status', 'capture', 'deploy', 'configure', 'activate')
    if ($supported -notcontains $Action) {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = "Unsupported LIMS APP release action '$Action'. Capture, deployment, configuration, and activation are unavailable."
        }
    }
    return [pscustomobject]@{
        Allowed = $false
        Reason  = "LIMS APP release action '$Action' is unavailable until release prerequisites and exact-target checks are implemented. A snapshot-copy completion marker is not authorization. No Azure change, guest command, or service change is performed."
    }
}

function Test-LimsAppLiteralToken {
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Token
    )
    if ($null -eq $Value) { return $false }
    return $Value.Trim() -ceq $Token
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
    if (Test-LimsAppLiteralToken -Value $supplied -Token 'not-used') {
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

<#
.SYNOPSIS
    Post-copy configuration of the replacement LIMS APP v2 VM.

.DESCRIPTION
    Managed Run Command on the mapped destination APP VM only. Verifies
    the completed copy and the mapped A: volume, then either registers
    local account / services / Azure Files task (Register) or runs the
    separate activation check (Activate).

    Secrets arrive only as Managed Run Command protected parameters.
    This script never writes those values to stdout, files, or logs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'tst', 'acc', 'preprd', 'prd')]
    [string] $EnvironmentName = 'dev',

    [Parameter(Mandatory = $false)]
    [string] $MigrationRunId = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Register', 'Activate')]
    [string] $ConfigurePhase = 'Register',

    [Parameter(Mandatory = $false)]
    [string] $ExpectedDestinationDiskResourceId = '',

    [Parameter(Mandatory = $false)]
    [string] $ExpectedDestinationDiskUniqueId = '',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $AzureFilesUnc = '',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $JbossRunnerPassword = '',

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string] $AzureFilesAccessKey = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# <LIMS_APP_MIG_MAPPING_INJECT>
# <LIMS_APP_MIG_SAFETY_INJECT>

function Import-LimsAppDataDiskMigrationMapping {
    if (-not (Get-Command Get-LimsAppDataDiskMigrationEnvironmentMapping -ErrorAction SilentlyContinue)) {
        $adjacent = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1'
        if (Test-Path -LiteralPath $adjacent) { . $adjacent }
        else { throw [System.InvalidOperationException]::new('The reviewed environment mapping was not loaded.') }
    }
    if (-not (Get-Command Resolve-GuestDiskIdentity -ErrorAction SilentlyContinue)) {
        $safety = Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1'
        if (Test-Path -LiteralPath $safety) { . $safety }
        else { throw [System.InvalidOperationException]::new('Safety functions were not loaded.') }
    }
}

function Assert-LimsAppV2ConfigFailure {
    param([Parameter(Mandatory = $true)] [string] $Message)
    throw [System.InvalidOperationException]::new($Message)
}

function Get-ActualComputerNameAdapter { return $env:COMPUTERNAME }

function Get-ImdsComputeMetadataAdapter {
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json'
    try {
        return Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -TimeoutSec 15
    }
    catch {
        Assert-LimsAppV2ConfigFailure "Unable to query IMDS compute metadata: $($_.Exception.Message)"
    }
}

function Get-DisksAdapter { return @(Get-Disk) }

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
            SizeBytes       = [int64]$disk.Size
            ScsiLogicalUnit = if ($dd) { [int]$dd.SCSILogicalUnit } else { -1 }
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
            }
        })
}

function Get-VolumeAdapter {
    param([Parameter(Mandatory = $true)] [string] $DriveLetter)
    $letter = $DriveLetter.Trim().TrimEnd(':')
    return Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
}

function Test-PathExistsAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    return (Test-Path -LiteralPath $Path)
}

function Get-ItemAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Item -LiteralPath $Path -Force
}

function New-DirectorySymbolicLinkAdapter {
    param([Parameter(Mandatory = $true)] [string] $LinkPath, [Parameter(Mandatory = $true)] [string] $Target)
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
}

function Get-LocalUserAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    return Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
}

function New-LocalUserAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name, [Parameter(Mandatory = $true)] [securestring] $Password)
    New-LocalUser -Name $Name -Password $Password -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
}

function Set-LocalUserPasswordAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name, [Parameter(Mandatory = $true)] [securestring] $Password)
    Set-LocalUser -Name $Name -Password $Password
}

function Grant-ServiceLogonRightAdapter {
    param([Parameter(Mandatory = $true)] [string] $AccountName)
    $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ('lims-app-v2-secedit-' + [guid]::NewGuid().ToString('N') + '.inf')
    $db = Join-Path ([System.IO.Path]::GetTempPath()) ('lims-app-v2-secedit-' + [guid]::NewGuid().ToString('N') + '.sdb')
    try {
        $export = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/export', '/cfg', $cfg) -Wait -PassThru -WindowStyle Hidden
        if ([int]$export.ExitCode -ne 0) {
            Assert-LimsAppV2ConfigFailure "secedit export failed with exit code $($export.ExitCode). Log on as a service was not granted."
        }
        $content = Get-Content -LiteralPath $cfg -Encoding unicode
        $account = $AccountName
        $updated = $false
        $newLines = foreach ($line in $content) {
            if ($line -match '^SeServiceLogonRight\s*=') {
                if ($line -notmatch [regex]::Escape($account)) {
                    if ($line.Trim().EndsWith('=')) { $line = "$line $account" }
                    else { $line = "$line,$account" }
                }
                $updated = $true
            }
            $line
        }
        if (-not $updated) { $newLines += "SeServiceLogonRight = $account" }
        Set-Content -LiteralPath $cfg -Value $newLines -Encoding unicode
        $configure = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/configure', '/db', $db, '/cfg', $cfg, '/areas', 'USER_RIGHTS') -Wait -PassThru -WindowStyle Hidden
        if ([int]$configure.ExitCode -ne 0) {
            Assert-LimsAppV2ConfigFailure "secedit configure failed with exit code $($configure.ExitCode). Log on as a service was not granted."
        }
    }
    finally {
        Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue
    }
}

function Grant-DirectoryModifyAclAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $AccountName)
    $acl = Get-Acl -LiteralPath $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($AccountName, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-ServiceAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Invoke-ProcessAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $Arguments
    )
    $redacted = @($Arguments | ForEach-Object {
            if ($_ -like 'password=*' -or $_ -like '/pass:*') { 'password=<redacted>' } else { $_ }
        })
    $argLine = $redacted -join ' '
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Command = "$FilePath $argLine" }
}

function Set-ServiceStartupTypeAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name, [Parameter(Mandatory = $true)] [string] $StartupType)
    Set-Service -Name $Name -StartupType $StartupType
}

function Stop-ServiceAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Start-ServiceAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    Start-Service -Name $Name
}

function Get-ScheduledTaskAdapter {
    param([Parameter(Mandatory = $true)] [string] $TaskName)
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Get-LocalAccountSidAdapter {
    param([Parameter(Mandatory = $true)] [string] $SamAccountName)
    $user = Get-LocalUser -Name $SamAccountName -ErrorAction SilentlyContinue
    if (-not $user) { return '' }
    return [string]$user.SID.Value
}

function Resolve-AccountSidAdapter {
    param([Parameter(Mandatory = $true)] [string] $QualifiedName)
    try {
        $account = New-Object System.Security.Principal.NTAccount($QualifiedName)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return ''
    }
}

function Resolve-ScheduledTaskRunAsUser {
    param([Parameter(Mandatory = $true)] [string] $UserName)
    $sam = Get-ScheduledTaskSamAccountName -UserName $UserName
    $expectedSid = Get-LocalAccountSidAdapter -SamAccountName $sam
    $candidate = "$(Get-ActualComputerNameAdapter)\$sam"
    $resolvedSid = Resolve-AccountSidAdapter -QualifiedName $candidate
    $check = Test-ScheduledTaskUserResolution -SamAccountName $sam -Candidate $candidate -ExpectedSid $expectedSid -ResolvedSid $resolvedSid
    if (-not $check.Accepted) { Assert-LimsAppV2ConfigFailure $check.Reason }
    return $candidate
}

function Register-ScheduledTaskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $TaskName,
        [Parameter(Mandatory = $true)] [string] $UserName,
        [Parameter(Mandatory = $true)] [string] $Password,
        [Parameter(Mandatory = $true)] [string] $Command,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $Arguments = '',
        [Parameter(Mandatory = $true)] [bool] $Disabled
    )
    $resolvedUser = Resolve-ScheduledTaskRunAsUser -UserName $UserName
    $action = New-ScheduledTaskAction -Execute $Command -Argument $Arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    if ($Disabled) {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Disable
    }
    else {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    }
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    # User parameter set only: -User/-Password/-RunLevel. Do not mix -Principal.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User $resolvedUser -Password $Password -RunLevel Highest -Force | Out-Null
}

function Enable-ScheduledTaskAdapter {
    param([Parameter(Mandatory = $true)] [string] $TaskName)
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
}

function Disable-ScheduledTaskAdapter {
    param([Parameter(Mandatory = $true)] [string] $TaskName)
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
}

function Start-ScheduledTaskAdapter {
    param([Parameter(Mandatory = $true)] [string] $TaskName)
    Start-ScheduledTask -TaskName $TaskName
}

function Get-ScheduledTaskInfoAdapter {
    param([Parameter(Mandatory = $true)] [string] $TaskName)
    return Get-ScheduledTaskInfo -TaskName $TaskName
}

function Get-UtcNowAdapter { return [datetime]::UtcNow }

function Add-AzureFilesCredentialAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $User,
        [Parameter(Mandatory = $true)] [string] $AccessKey,
        [Parameter(Mandatory = $true)] [string] $RunAsUserName,
        [Parameter(Mandatory = $true)] [string] $RunAsPassword
    )
    $secure = ConvertTo-SecureStringPlain -Plain $RunAsPassword
    $runAs = New-Object System.Management.Automation.PSCredential($RunAsUserName, $secure)
    $p = Start-Process -FilePath 'cmdkey.exe' -ArgumentList @("/add:$Target", "/user:$User", "/pass:$AccessKey") -Credential $runAs -LoadUserProfile -Wait -PassThru -WindowStyle Hidden
    if ([int]$p.ExitCode -ne 0) {
        Assert-LimsAppV2ConfigFailure "cmdkey failed with exit code $($p.ExitCode) while provisioning the Azure Files credential in the '$RunAsUserName' context. The access key is not logged."
    }
}

function Get-ServiceProcessIdAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { return 0 }
    return [int]$svc.ProcessId
}

function Test-PathReadAsProcessAdapter {
    param(
        [Parameter(Mandatory = $true)] [int] $ProcessId,
        [Parameter(Mandatory = $true)] [string] $Path
    )
    if ($ProcessId -le 0) {
        return [pscustomobject]@{ Readable = $false; Reason = "Service process id $ProcessId is not running; cannot read '$Path' in that context." }
    }
    if (-not ('LimsAppV2ProcessToken' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LimsAppV2ProcessToken {
    public const uint TOKEN_DUPLICATE = 0x0002;
    public const uint TOKEN_QUERY = 0x0008;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool DuplicateToken(IntPtr token, int level, out IntPtr dup);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
    }
    $process = [LimsAppV2ProcessToken]::OpenProcess(
        [LimsAppV2ProcessToken]::PROCESS_QUERY_INFORMATION -bor [LimsAppV2ProcessToken]::PROCESS_QUERY_LIMITED_INFORMATION,
        $false,
        $ProcessId
    )
    if ($process -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ Readable = $false; Reason = "Unable to open service process $ProcessId to read '$Path'." }
    }
    $token = [IntPtr]::Zero
    $dup = [IntPtr]::Zero
    $impersonation = $null
    try {
        $opened = [LimsAppV2ProcessToken]::OpenProcessToken(
            $process,
            [LimsAppV2ProcessToken]::TOKEN_DUPLICATE -bor [LimsAppV2ProcessToken]::TOKEN_QUERY,
            [ref]$token
        )
        if (-not $opened) {
            return [pscustomobject]@{ Readable = $false; Reason = "Unable to open the token for service process $ProcessId." }
        }
        $duplicated = [LimsAppV2ProcessToken]::DuplicateToken($token, 2, [ref]$dup)
        if (-not $duplicated) {
            return [pscustomobject]@{ Readable = $false; Reason = "Unable to duplicate the token for service process $ProcessId." }
        }
        $identity = New-Object System.Security.Principal.WindowsIdentity($dup)
        $impersonation = $identity.Impersonate()
        $null = Get-ChildItem -LiteralPath $Path -Force
        return [pscustomobject]@{ Readable = $true; Reason = $null }
    }
    catch {
        return [pscustomobject]@{ Readable = $false; Reason = "JBoss service context cannot read '$Path'." }
    }
    finally {
        if ($impersonation) { $impersonation.Undo() }
        if ($dup -ne [IntPtr]::Zero) { [void][LimsAppV2ProcessToken]::CloseHandle($dup) }
        if ($token -ne [IntPtr]::Zero) { [void][LimsAppV2ProcessToken]::CloseHandle($token) }
        [void][LimsAppV2ProcessToken]::CloseHandle($process)
    }
}

function ConvertTo-SecureStringPlain {
    param([Parameter(Mandatory = $true)] [string] $Plain)
    return ConvertTo-SecureString -String $Plain -AsPlainText -Force
}

function Get-SdmshomeLinkPath {
    param([Parameter(Mandatory = $true)] $Environment)
    $relative = [string]$Environment.AppV2.SdmshomeLinkRelativePath
    return ('{0}:\{1}' -f $Environment.DestinationDriveLetter.Trim().TrimEnd(':'), $relative.TrimStart('\'))
}

function Get-SdmshomeLinkObservation {
    param([Parameter(Mandatory = $true)] $Environment)
    $linkPath = Get-SdmshomeLinkPath -Environment $Environment
    $parent = Split-Path -Parent $linkPath
    $item = Get-ItemAdapter -Path $linkPath
    $isReparse = $false
    $isDir = $false
    $isFile = $false
    $target = ''
    if ($item) {
        $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $isDir = [bool]$item.PSIsContainer -and -not $isReparse
        $isFile = -not $item.PSIsContainer
        if ($item.PSObject.Properties['Target'] -and $item.Target) { $target = [string](@($item.Target)[0]) }
    }
    return [pscustomobject]@{
        LinkPath       = $linkPath
        ParentPath     = $parent
        ParentExists   = (Test-PathExistsAdapter -Path $parent)
        Exists         = ($null -ne $item)
        IsReparsePoint = $isReparse
        IsDirectory    = $isDir
        IsFile         = $isFile
        Target         = $target
        Item           = $item
    }
}

function Get-RegisterPreflightPathExists {
    param([Parameter(Mandatory = $true)] $Environment)
    $app = $Environment.AppV2
    $paths = @(
        $app.JbossProcrunExePath, $app.JbossProcrunJvm, $app.JbossProcrunWorkingPath,
        $app.ApacheBinaryPath, $app.ShibbolethBinaryPath
    ) + @($app.JbossRunnerDirectoryPaths)
    $map = @{}
    foreach ($path in $paths) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            $map[$path] = [bool](Test-PathExistsAdapter -Path $path)
        }
    }
    return $map
}

function Assert-ConfigureTargetIdentity {
    param([Parameter(Mandatory = $true)] $Environment)

    if (-not $Environment.Enabled) {
        Assert-LimsAppV2ConfigFailure "Environment '$($Environment.EnvironmentName)' is not enabled."
    }
    $actual = Get-ActualComputerNameAdapter
    if ($actual -ne $Environment.DestinationComputerName) {
        Assert-LimsAppV2ConfigFailure "Guest computer name '$actual' does not match the mapped destination '$($Environment.DestinationComputerName)'."
    }
    $imds = Get-ImdsComputeMetadataAdapter
    if ([string]$imds.name -ne $Environment.DestinationVmName) {
        Assert-LimsAppV2ConfigFailure "IMDS VM name '$($imds.name)' does not match the mapped destination '$($Environment.DestinationVmName)'. Refusing to configure this VM."
    }
    if ([string]$imds.subscriptionId -ne $Environment.SubscriptionId -or [string]$imds.resourceGroupName -ne $Environment.ResourceGroupName) {
        Assert-LimsAppV2ConfigFailure 'IMDS subscription or resource group does not match the mapped destination.'
    }
    return $imds
}

function Assert-MappedDestinationVolume {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] $ImdsCompute,
        [Parameter(Mandatory = $true)] [string] $ExpectedDestinationDiskResourceId,
        [Parameter(Mandatory = $true)] [string] $ExpectedDestinationDiskUniqueId
    )
    $guestDisks = @(Get-GuestDiskInventoryAdapter)
    $partitions = @(Get-GuestPartitionInventoryAdapter)
    $dest = Resolve-GuestDiskIdentity -ImdsCompute $ImdsCompute -GuestDisks $guestDisks -ExpectedManagedDiskId $ExpectedDestinationDiskResourceId -ExpectedLun ([int]$Environment.DestinationDataDiskLun) -ExpectedUniqueId $ExpectedDestinationDiskUniqueId -Role 'Destination A:'
    if (-not $dest.Resolved) { Assert-LimsAppV2ConfigFailure $dest.Reason }
    $volume = Get-VolumeAdapter -DriveLetter $Environment.DestinationDriveLetter
    $label = $null
    if ($volume) { $label = [string]$volume.FileSystemLabel }
    $letter = Test-DriveLetterOnResolvedDisk -DriveLetter $Environment.DestinationDriveLetter -ExpectedDiskNumber ([int]$dest.Disk.Number) -Partitions $partitions -ExpectedLabel $Environment.DestinationVolumeLabel -VolumeLabel $label -Role 'Destination A:'
    if (-not $letter.Matches) { Assert-LimsAppV2ConfigFailure $letter.Reason }
    return $dest
}

function Invoke-JbossRunnerAccountReconcile {
    param(
        [Parameter(Mandatory = $true)] $AppV2,
        [Parameter(Mandatory = $true)] [string] $Password
    )
    $name = $AppV2.JbossRunnerUserName
    $secure = ConvertTo-SecureStringPlain -Plain $Password
    $existing = Get-LocalUserAdapter -Name $name
    if ($existing) {
        Set-LocalUserPasswordAdapter -Name $name -Password $secure
        Write-Host "Reconciled local user '.\$name' (password updated, account reused)."
    }
    else {
        New-LocalUserAdapter -Name $name -Password $secure
        Write-Host "Created local user '.\$name'."
    }
    Grant-ServiceLogonRightAdapter -AccountName ".\$name"
    Write-Host "Granted 'Log on as a service' to '.\$name'."
}

function Invoke-JbossRunnerDirectoryPermissions {
    param([Parameter(Mandatory = $true)] $AppV2)
    $paths = @($AppV2.JbossRunnerDirectoryPaths)
    if ($paths.Count -eq 0) {
        return [pscustomobject]@{
            Applied = $false
            Missing = $true
            Reason  = 'Reviewed application-directory paths are empty; ACLs were not changed.'
        }
    }
    foreach ($path in $paths) {
        if (-not (Test-PathExistsAdapter -Path $path)) {
            Assert-LimsAppV2ConfigFailure "Reviewed application directory '$path' does not exist on this guest."
        }
        Grant-DirectoryModifyAclAdapter -Path $path -AccountName ".\$($AppV2.JbossRunnerUserName)"
    }
    return [pscustomobject]@{
        Applied = $true
        Missing = $false
        Reason  = "Granted Modify on $($paths.Count) reviewed application director$(if ($paths.Count -eq 1) { 'y' } else { 'ies' }) to '.\$($AppV2.JbossRunnerUserName)'."
    }
}

function Get-JbossProcrunArgumentList {
    param([Parameter(Mandatory = $true)] $AppV2)
    $argumentList = @(
        "//US//$($AppV2.JbossServiceName)",
        "--DisplayName=$($AppV2.JbossServiceDisplayName)",
        "--StartMode=$($AppV2.JbossProcrunStartMode)",
        "--Jvm=$($AppV2.JbossProcrunJvm)",
        "--StartClass=$($AppV2.JbossProcrunStartClass)",
        "--Startup=manual"
    )
    if ($AppV2.JbossProcrunStartParams) { $argumentList += "--StartParams=$($AppV2.JbossProcrunStartParams)" }
    if ($AppV2.JbossProcrunStopClass) { $argumentList += "--StopClass=$($AppV2.JbossProcrunStopClass)" }
    if ($AppV2.JbossProcrunStopParams) { $argumentList += "--StopParams=$($AppV2.JbossProcrunStopParams)" }
    if ($AppV2.JbossProcrunClasspath) { $argumentList += "--Classpath=$($AppV2.JbossProcrunClasspath)" }
    if ($AppV2.JbossProcrunWorkingPath) { $argumentList += "--StartPath=$($AppV2.JbossProcrunWorkingPath)" }
    if ($AppV2.JbossProcrunLogPath) { $argumentList += "--LogPath=$($AppV2.JbossProcrunLogPath)" }
    if ($AppV2.JbossProcrunStdOutput) { $argumentList += "--StdOutput=$($AppV2.JbossProcrunStdOutput)" }
    if ($AppV2.JbossProcrunStdError) { $argumentList += "--StdError=$($AppV2.JbossProcrunStdError)" }
    return $argumentList
}

function Invoke-JbossServiceRegister {
    param(
        [Parameter(Mandatory = $true)] $AppV2,
        [Parameter(Mandatory = $true)] [string] $Password
    )
    $settings = Test-LimsAppV2ProcrunSettingsComplete -AppV2 $AppV2
    if (-not $settings.Complete) {
        return [pscustomobject]@{ Changed = $false; Missing = $true; Reason = $settings.Reason }
    }
    if (-not (Test-PathExistsAdapter -Path $AppV2.JbossProcrunExePath)) {
        Assert-LimsAppV2ConfigFailure "Reviewed Procrun executable '$($AppV2.JbossProcrunExePath)' was not found."
    }
    $svc = Get-ServiceAdapter -Name $AppV2.JbossServiceName
    if (-not $svc) {
        $install = Invoke-ProcessAdapter -FilePath $AppV2.JbossProcrunExePath -Arguments @("//IS//$($AppV2.JbossServiceName)")
        if ($install.ExitCode -ne 0) {
            Assert-LimsAppV2ConfigFailure "Procrun //IS for '$($AppV2.JbossServiceName)' exited $($install.ExitCode)."
        }
    }
    $update = Invoke-ProcessAdapter -FilePath $AppV2.JbossProcrunExePath -Arguments @(Get-JbossProcrunArgumentList -AppV2 $AppV2)
    if ($update.ExitCode -ne 0) {
        Assert-LimsAppV2ConfigFailure "Procrun //US for '$($AppV2.JbossServiceName)' exited $($update.ExitCode)."
    }
    $account = ".\$($AppV2.JbossRunnerUserName)"
    $sc = Invoke-ProcessAdapter -FilePath 'sc.exe' -Arguments @('config', $AppV2.JbossServiceName, "obj= $account", "password= $Password", 'start=', 'demand')
    if ($sc.ExitCode -ne 0) {
        Assert-LimsAppV2ConfigFailure "sc config for '$($AppV2.JbossServiceName)' exited $($sc.ExitCode). The password is not logged."
    }
    Stop-ServiceAdapter -Name $AppV2.JbossServiceName
    Set-ServiceStartupTypeAdapter -Name $AppV2.JbossServiceName -StartupType 'Manual'
    return [pscustomobject]@{
        Changed = $true
        Missing = $false
        Reason  = "Registered '$($AppV2.JbossServiceName)' as .\$($AppV2.JbossRunnerUserName), startup Manual, left stopped."
    }
}

function Invoke-BinaryServiceRegister {
    param(
        [Parameter(Mandatory = $true)] [string] $ServiceName,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $BinaryPath,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $Arguments
    )
    $settings = Test-LimsAppV2ServiceBinarySettingsComplete -ServiceName $ServiceName -BinaryPath $BinaryPath -Arguments $Arguments
    if (-not $settings.Complete) {
        return [pscustomobject]@{ Changed = $false; Missing = $true; Reason = $settings.Reason }
    }
    if (-not (Test-PathExistsAdapter -Path $BinaryPath)) {
        Assert-LimsAppV2ConfigFailure "Reviewed binary '$BinaryPath' for '$ServiceName' was not found."
    }
    $binPath = $BinaryPath
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $binPath = "`"$BinaryPath`" $Arguments" }
    $svc = Get-ServiceAdapter -Name $ServiceName
    if (-not $svc) {
        $create = Invoke-ProcessAdapter -FilePath 'sc.exe' -Arguments @('create', $ServiceName, "binPath= $binPath", 'start=', 'demand')
        if ($create.ExitCode -ne 0) {
            Assert-LimsAppV2ConfigFailure "sc create for '$ServiceName' exited $($create.ExitCode)."
        }
    }
    else {
        $config = Invoke-ProcessAdapter -FilePath 'sc.exe' -Arguments @('config', $ServiceName, "binPath= $binPath", 'start=', 'demand')
        if ($config.ExitCode -ne 0) {
            Assert-LimsAppV2ConfigFailure "sc config for '$ServiceName' exited $($config.ExitCode)."
        }
    }
    Stop-ServiceAdapter -Name $ServiceName
    Set-ServiceStartupTypeAdapter -Name $ServiceName -StartupType 'Manual'
    return [pscustomobject]@{
        Changed = $true
        Missing = $false
        Reason  = "Registered '$ServiceName', startup Manual, left stopped."
    }
}

function Invoke-AzureFilesStartupTaskRegister {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [string] $Password
    )
    $app = $Environment.AppV2
    $link = Get-SdmshomeLinkPath -Environment $Environment
    $command = 'powershell.exe'
    $arguments = "-NoProfile -NonInteractive -Command `"if (-not (Test-Path -LiteralPath '$link')) { exit 2 }; exit 0`""
    Register-ScheduledTaskAdapter -TaskName $app.AzureFilesStartupTaskName -UserName ".\$($app.JbossRunnerUserName)" -Password $Password -Command $command -Arguments $arguments -Disabled $true
    Write-Host "Registered startup task '$($app.AzureFilesStartupTaskName)' as .\$($app.JbossRunnerUserName), left disabled."
}

function Invoke-SdmshomeLinkProvision {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $SuppliedUnc,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $AccessKey,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $JbossRunnerPassword
    )
    $ready = Test-AzureFilesUncReadyForLink -SuppliedUnc $SuppliedUnc -AppV2 $Environment.AppV2
    if ($ready.Skip) {
        return [pscustomobject]@{ Created = $false; Reused = $false; Skipped = $true; Reason = $ready.Reason }
    }
    if (-not $ready.Ready) { Assert-LimsAppV2ConfigFailure $ready.Reason }

    $keyCheck = Test-LimsAppV2SecretPresent -Name 'AzureFilesAccessKey' -Value $AccessKey
    if (-not $keyCheck.Present) { Assert-LimsAppV2ConfigFailure $keyCheck.Reason }

    $cred = Get-AzureFilesCredentialTargetFromUnc -Unc $Environment.AppV2.AzureFilesUnc
    if (-not $cred.Accepted) { Assert-LimsAppV2ConfigFailure $cred.Reason }
    Add-AzureFilesCredentialAdapter -Target $cred.Target -User $cred.User -AccessKey $AccessKey -RunAsUserName ".\$($Environment.AppV2.JbossRunnerUserName)" -RunAsPassword $JbossRunnerPassword

    $linkPath = Get-SdmshomeLinkPath -Environment $Environment
    $parent = Split-Path -Parent $linkPath
    if (-not (Test-PathExistsAdapter -Path $parent)) {
        Assert-LimsAppV2ConfigFailure "Parent path '$parent' does not exist. The mapped A: volume is missing lv89 after copy."
    }
    $item = Get-ItemAdapter -Path $linkPath
    $exists = $null -ne $item
    $isReparse = $false
    $isDir = $false
    $isFile = $false
    $target = ''
    if ($item) {
        $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $isDir = [bool]$item.PSIsContainer -and -not $isReparse
        $isFile = -not $item.PSIsContainer
        if ($item.PSObject.Properties['Target'] -and $item.Target) { $target = [string](@($item.Target)[0]) }
    }
    $decision = Test-SdmshomeLinkDecision -PathExists $exists -IsReparsePoint $isReparse -ExistingTarget $target -ExpectedTarget $Environment.AppV2.AzureFilesUnc -IsDirectory $isDir -IsFile $isFile
    if ($decision.Action -eq 'Fail') { Assert-LimsAppV2ConfigFailure $decision.Reason }
    if ($decision.Action -eq 'Reuse') {
        return [pscustomobject]@{
            Created = $false
            Reused  = $true
            Skipped = $false
            Reason  = "Reused existing directory symbolic link '$linkPath' (target matches the reviewed UNC)."
        }
    }
    New-DirectorySymbolicLinkAdapter -LinkPath $linkPath -Target $Environment.AppV2.AzureFilesUnc
    return [pscustomobject]@{
        Created = $true
        Reused  = $false
        Skipped = $false
        Reason  = "Created directory symbolic link '$linkPath' to the reviewed v2 UNC. Provisioned the Azure Files access-key credential for '$($cred.Target)' in the task account context. The key is not logged."
    }
}

function Invoke-LimsAppV2Register {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $JbossRunnerPassword,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $AzureFilesAccessKey,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $AzureFilesUnc
    )
    $pathExists = Get-RegisterPreflightPathExists -Environment $Environment
    $linkObservation = Get-SdmshomeLinkObservation -Environment $Environment
    $preflight = Get-LimsAppV2RegisterPreflight -Environment $Environment -JbossRunnerPassword $JbossRunnerPassword -AzureFilesAccessKey $AzureFilesAccessKey -AzureFilesUnc $AzureFilesUnc -PathExists $pathExists -LinkObservation $linkObservation
    if (-not $preflight.Allowed) {
        Assert-LimsAppV2ConfigFailure $preflight.Reason
    }

    Invoke-JbossRunnerAccountReconcile -AppV2 $Environment.AppV2 -Password $JbossRunnerPassword
    $directoryPerms = Invoke-JbossRunnerDirectoryPermissions -AppV2 $Environment.AppV2
    Write-Host $directoryPerms.Reason

    $jboss = Invoke-JbossServiceRegister -AppV2 $Environment.AppV2 -Password $JbossRunnerPassword
    Write-Host $jboss.Reason
    $apache = Invoke-BinaryServiceRegister -ServiceName $Environment.AppV2.ApacheServiceName -BinaryPath $Environment.AppV2.ApacheBinaryPath -Arguments $Environment.AppV2.ApacheArguments
    Write-Host $apache.Reason
    $shib = Invoke-BinaryServiceRegister -ServiceName $Environment.AppV2.ShibbolethServiceName -BinaryPath $Environment.AppV2.ShibbolethBinaryPath -Arguments $Environment.AppV2.ShibbolethArguments
    Write-Host $shib.Reason
    Invoke-AzureFilesStartupTaskRegister -Environment $Environment -Password $JbossRunnerPassword
    $link = Invoke-SdmshomeLinkProvision -Environment $Environment -SuppliedUnc $AzureFilesUnc -AccessKey $AzureFilesAccessKey -JbossRunnerPassword $JbossRunnerPassword
    if ($link.Reason) { Write-Host $link.Reason }

    return [pscustomobject]@{
        Phase            = 'Register'
        JbossService     = $Environment.AppV2.JbossServiceName
        ApacheService    = $Environment.AppV2.ApacheServiceName
        ShibbolethService = $Environment.AppV2.ShibbolethServiceName
        TaskName         = $Environment.AppV2.AzureFilesStartupTaskName
        Link             = $link
        AutomaticStartup = $false
        Status           = 'RegisteredStopped'
    }
}

function Restore-ActivationFailureState {
    param(
        [Parameter(Mandatory = $true)] $AppV2,
        [Parameter(Mandatory = $true)] [string] $Reason
    )
    Stop-ServiceAdapter -Name $AppV2.JbossServiceName
    Disable-ScheduledTaskAdapter -TaskName $AppV2.AzureFilesStartupTaskName
    Assert-LimsAppV2ConfigFailure $Reason
}

function Wait-FreshScheduledTaskResultAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $TaskName,
        [Parameter(Mandatory = $true)] [datetime] $AttemptStartedUtc,
        [Parameter(Mandatory = $false)] [AllowNull()] $PreviousLastRunTime,
        [Parameter(Mandatory = $false)] [int] $TimeoutSeconds = 60
    )
    $deadline = (Get-UtcNowAdapter).AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $info = Get-ScheduledTaskInfoAdapter -TaskName $TaskName
        $last = Test-LimsAppV2ScheduledTaskResultIsFresh -AttemptStartedUtc $AttemptStartedUtc -PreviousLastRunTime $PreviousLastRunTime -CurrentLastRunTime $info.LastRunTime -LastTaskResult $info.LastTaskResult
        if ($last.Fresh) { return $last }
        Start-Sleep -Seconds 1
    } while ((Get-UtcNowAdapter) -lt $deadline)
    if ($last) { return $last }
    return [pscustomobject]@{ Fresh = $false; Succeeded = $false; Reason = 'No scheduled-task LastRunTime was recorded for this attempt. Refusing to accept a stale result.' }
}

function Invoke-LimsAppV2Activate {
    param(
        [Parameter(Mandatory = $true)] $Environment,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $AzureFilesUnc
    )
    $app = $Environment.AppV2
    $reviews = Test-LimsAppV2ActivationReviews -AppV2 $app
    $linkPath = Get-SdmshomeLinkPath -Environment $Environment
    $ready = Test-AzureFilesUncReadyForLink -SuppliedUnc $(if ($AzureFilesUnc) { $AzureFilesUnc } else { $app.AzureFilesUnc }) -AppV2 $app
    if (-not $ready.Ready) {
        Assert-LimsAppV2ConfigFailure "Activation requires a reviewed v2 UNC and matching sdmshome link. $($ready.Reason)"
    }

    $item = Get-ItemAdapter -Path $linkPath
    if (-not $item) { Assert-LimsAppV2ConfigFailure "Activation requires '$linkPath' to exist as a directory symbolic link." }
    $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    $target = ''
    if ($item.PSObject.Properties['Target'] -and $item.Target) { $target = [string](@($item.Target)[0]) }
    $decision = Test-SdmshomeLinkDecision -PathExists $true -IsReparsePoint $isReparse -ExistingTarget $target -ExpectedTarget $app.AzureFilesUnc
    if ($decision.Action -ne 'Reuse') {
        Assert-LimsAppV2ConfigFailure "Activation refused: $linkPath is not a directory symbolic link to the reviewed UNC. $($decision.Reason)"
    }

    $existingTask = Get-ScheduledTaskAdapter -TaskName $app.AzureFilesStartupTaskName
    if (-not $existingTask) {
        Assert-LimsAppV2ConfigFailure "Startup task '$($app.AzureFilesStartupTaskName)' is not registered; cannot verify scheduled-task context access."
    }

    $previousInfo = Get-ScheduledTaskInfoAdapter -TaskName $app.AzureFilesStartupTaskName
    $previousLastRun = $null
    if ($previousInfo -and $previousInfo.PSObject.Properties['LastRunTime']) { $previousLastRun = $previousInfo.LastRunTime }
    $attemptStarted = Get-UtcNowAdapter
    Start-ScheduledTaskAdapter -TaskName $app.AzureFilesStartupTaskName
    $taskResult = Wait-FreshScheduledTaskResultAdapter -TaskName $app.AzureFilesStartupTaskName -AttemptStartedUtc $attemptStarted -PreviousLastRunTime $previousLastRun
    if (-not $taskResult.Fresh -or -not $taskResult.Succeeded) {
        Restore-ActivationFailureState -AppV2 $app -Reason $taskResult.Reason
    }
    Write-Host "Scheduled-task context can access '$linkPath' (fresh LastRunTime for this attempt)."

    $jboss = Get-ServiceAdapter -Name $app.JbossServiceName
    if (-not $jboss) { Restore-ActivationFailureState -AppV2 $app -Reason "JBoss service '$($app.JbossServiceName)' is not registered." }
    Start-ServiceAdapter -Name $app.JbossServiceName
    $live = Get-ServiceAdapter -Name $app.JbossServiceName
    if (-not $live -or $live.Status -ne 'Running') {
        Restore-ActivationFailureState -AppV2 $app -Reason "JBoss service '$($app.JbossServiceName)' did not reach Running; service-context access was not proven."
    }
    $processId = Get-ServiceProcessIdAdapter -Name $app.JbossServiceName
    $serviceRead = Test-PathReadAsProcessAdapter -ProcessId $processId -Path $linkPath
    Stop-ServiceAdapter -Name $app.JbossServiceName
    if (-not $serviceRead.Readable) {
        Restore-ActivationFailureState -AppV2 $app -Reason $serviceRead.Reason
    }
    Write-Host "JBoss service context can read '$linkPath'. Service was stopped again."

    if (-not $reviews.Passed) {
        Disable-ScheduledTaskAdapter -TaskName $app.AzureFilesStartupTaskName
        Write-Host $reviews.Reason
        return [pscustomobject]@{
            Phase            = 'Activate'
            AccessCheck      = 'Passed'
            AutomaticStartup = $false
            Status           = 'AccessVerifiedStartupBlocked'
            Reason           = $reviews.Reason
        }
    }

    foreach ($name in @($app.JbossServiceName, $app.ApacheServiceName, $app.ShibbolethServiceName)) {
        if (Get-ServiceAdapter -Name $name) {
            Set-ServiceStartupTypeAdapter -Name $name -StartupType 'Automatic'
            Stop-ServiceAdapter -Name $name
        }
    }
    Enable-ScheduledTaskAdapter -TaskName $app.AzureFilesStartupTaskName
    Write-Host 'Automatic startup enabled after the fresh task check, the JBoss service-context read, and reviewed v2 JDBC, Apache, Shibboleth, and UNC settings. Services were left stopped.'
    return [pscustomobject]@{
        Phase            = 'Activate'
        AccessCheck      = 'Passed'
        AutomaticStartup = $true
        Status           = 'AutomaticEnabledStopped'
        Reason           = $null
    }
}

function Invoke-LimsAppV2Configure {
    param(
        [Parameter(Mandatory = $true)] [string] $EnvironmentName,
        [Parameter(Mandatory = $true)] [string] $MigrationRunId,
        [Parameter(Mandatory = $true)] [string] $ConfigurePhase,
        [Parameter(Mandatory = $true)] [string] $ExpectedDestinationDiskResourceId,
        [Parameter(Mandatory = $true)] [string] $ExpectedDestinationDiskUniqueId,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $AzureFilesUnc = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $JbossRunnerPassword = '',
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $AzureFilesAccessKey = ''
    )

    $runIdCheck = Test-LimsAppMigNumericBuildId -Value $MigrationRunId
    if (-not $runIdCheck.Accepted) { Assert-LimsAppV2ConfigFailure $runIdCheck.Reason }

    Import-LimsAppDataDiskMigrationMapping
    $environment = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName $EnvironmentName
    $imds = Assert-ConfigureTargetIdentity -Environment $environment
    if ([string]::IsNullOrWhiteSpace($ExpectedDestinationDiskUniqueId)) {
        $ExpectedDestinationDiskUniqueId = $environment.DestinationAttestedGuestUniqueId
    }
    $null = Assert-MappedDestinationVolume -Environment $environment -ImdsCompute $imds -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId

    if ($ConfigurePhase -eq 'Activate') {
        $result = Invoke-LimsAppV2Activate -Environment $environment -AzureFilesUnc $AzureFilesUnc
    }
    else {
        $result = Invoke-LimsAppV2Register -Environment $environment -JbossRunnerPassword $JbossRunnerPassword -AzureFilesAccessKey $AzureFilesAccessKey -AzureFilesUnc $AzureFilesUnc
    }

    Write-Host '===== LIMS APP v2 post-copy configuration ====='
    Write-Host "Migration run ID     : $MigrationRunId"
    Write-Host "Phase                : $($result.Phase)"
    Write-Host "Status               : $($result.Status)"
    Write-Host "Automatic startup    : $($result.AutomaticStartup)"
    Write-Host 'Secrets              : not written to this log'
    Write-Host 'Legacy APP / SQL VMs : not targeted'
    Write-Host '================================================'
    return $result
}

if ($env:LIMS_APP_MIG_CONFIG_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-LimsAppV2Configure -EnvironmentName $EnvironmentName -MigrationRunId $MigrationRunId -ConfigurePhase $ConfigurePhase -ExpectedDestinationDiskResourceId $ExpectedDestinationDiskResourceId -ExpectedDestinationDiskUniqueId $ExpectedDestinationDiskUniqueId -AzureFilesUnc $AzureFilesUnc -JbossRunnerPassword $JbossRunnerPassword -AzureFilesAccessKey $AzureFilesAccessKey | Out-Null
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

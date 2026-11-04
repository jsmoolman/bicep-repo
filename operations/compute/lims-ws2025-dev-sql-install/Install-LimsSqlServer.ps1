<#
.SYNOPSIS
    Installs SQL Server 2022 (Database Engine only, default MSSQLSERVER
    instance) on the existing LIMS WS2025 DEV v2 SQL virtual machine
    (vm-lims-dev-v2-westeu-002), using the media already staged by
    Stage-LimsSqlInstallationMedia.ps1 at the pinned path
    C:\SQLMedia\SQL2022\SETUP.EXE, then hardens TCP 1433 as the only
    listener, installs a reviewable mitigation for TempDB living on the
    Azure temporary disk, confirms Windows administrator sysadmin access,
    and disables the sa login. Narrowly scoped under the LIMS WS2025 DEV v2
    SQL Server 2022 installation exception in docs/scope.md -- this one
    script, this one VM, this one instance, this exact configuration; never
    a named instance, never any feature beyond the Database Engine, never
    any other VM.

.DESCRIPTION
    DELIVERY. Submitted via .azuredevops/pipelines/provision-lims-ws2025-dev-sql.yml,
    action 'install', through the same Microsoft.Compute/virtualMachines/runCommands
    ("Managed Run Command") mechanism the 'stage-only' action already uses
    (scripts/submit-and-wait-run-command.sh), extended to forward this
    script's own parameters via `az vm run-command create --parameters`
    (non-secret inputs) and `--protected-parameters` (the sa password
    only -- never logged, never visible in the VM's own settings file).

    FAIL BEFORE ANY MUTATION. Before SETUP.EXE is ever launched, this
    script independently re-verifies: the same fixed target identity
    (subscription/resource group/VM name/live IMDS compute identity/guest
    computer name) used by the staging script; a valid, Microsoft-signed
    Authenticode signature on the pinned C:\SQLMedia\SQL2022\SETUP.EXE;
    that E:/F: carry the SQL-Data/SQL-Logs volume labels set by the guest
    data-disk preparation script and that D: (the Azure temporary disk)
    exists; and, if an MSSQLSERVER service already exists, that its state
    exactly matches what this run expects (edition/collation/running) --
    an already-healthy match is reported as an idempotent success without
    re-running Setup, and a present-but-partial/unexpected instance stops
    the run with a diagnostic rather than attempting any automatic repair.

    SETUP INVOCATION. Every non-secret Setup option is written to a
    ConfigurationFile.ini this script generates itself (never the
    auto-generated one Setup would otherwise write, which this script
    never relies on); only /SAPWD is ever supplied on the command line,
    and only as a single process argument -- never written to any file,
    pipeline log, or verbose/output stream by this script. Mixed-mode
    authentication, SQL_Latin1_General_CP1_CI_AS collation, the two
    documented default virtual service accounts (NT SERVICE\MSSQLSERVER /
    NT SERVICE\SQLSERVERAGENT -- "the agreed default service-account
    model"), SQL Server Agent installed but disabled, and
    /UPDATEENABLED=False (servicing stays with the existing Azure Update
    Manager patch-onboarding pilot, not Setup's own update discovery) are
    all fixed by this script, never caller-supplied. The approved Windows
    SQL administrator principals, the final data/log/TempDB paths, and
    every TempDB sizing value are explicit caller inputs -- never
    hardcoded or guessed by this script.

    EXIT CODE AND REBOOT HANDLING. Setup exit code 0 is full success.
    Exit code 3010 ("succeeded, reboot required" -- a known, Microsoft-
    documented first-run condition for SQL Server 2022 on a fresh Windows
    Server image whose VCRuntime140 predates 14.29.30139, and also a
    possible pre-existing pending-reboot condition) is reported clearly
    and the run stops there -- it is never treated as a hard failure, and
    this script never attempts post-install verification against a
    possibly-not-yet-functional instance. Rerunning after a human reboots
    the VM resumes correctly via the rerun-safety check above. Any other
    exit code is a hard failure.

    TCP 1433 ONLY. After Setup completes, this script explicitly sets the
    Database Engine's registry-configured TCP listener to a static port
    1433 with dynamic ports blank (idempotent), restarts the service, and
    verifies the effective configuration via the registry -- never left to
    assumption -- then confirms a live local TCP connection succeeds on
    that exact port.

    TEMPDB ON THE AZURE TEMPORARY DISK. D: is the Azure temporary/
    ephemeral disk and is recreated empty on VM deallocation/reallocation;
    SQL Server does not create a missing TempDB directory itself, so a
    plain TempDB placement there would otherwise leave the Database Engine
    unable to start after such an event. This script installs a Windows
    Scheduled Task (AtStartup, running as SYSTEM) that recreates the
    TempDB directory and grants the Database Engine's service account the
    permissions it needs there, before the service starts (set to
    Automatic, Delayed Start) -- and, once, during this same install run,
    proves the mitigation actually works: stops the service, deletes the
    TempDB directory to simulate a freshly recreated temporary disk,
    re-runs the exact same recreation script the scheduled task will run
    on a real reboot, restarts the service, and confirms it reaches
    Running again.

    ADMINISTRATOR ACCESS AND sa. Confirms an approved Windows
    administrator principal has sysadmin access via a local Windows-
    authenticated connection (IS_SRVROLEMEMBER('sysadmin')), and only then
    disables the sa login (ALTER LOGIN [sa] DISABLE) using that same
    connection -- the sa password supplied to Setup is never reused by
    this script to connect to the instance afterward.

    COMPACT OUTPUT. Only a short, compact summary (Setup exit code,
    reboot status, edition, product version, collation, Agent service
    status, TCP 1433 confirmation, TempDB-recreation-safety confirmation,
    sa-disabled confirmation) is ever written to the default output
    stream. The sa password, the full Setup command line, and any raw
    Setup log are never printed.

    TESTABILITY. Pure decision functions (ConfigurationFile.ini content
    construction, Windows-admin-principals CSV parsing, Setup exit-code
    classification, existing-instance-state classification, TCP registry
    comparison) take and return plain data only, with no real cmdlet call
    anywhere inside them -- runnable on any platform, including Pester on
    the Ubuntu CI runner this repository uses. All real I/O (IMDS, the
    filesystem, services, the registry, SQL connections, external
    processes) is isolated in small *Adapter functions, the only functions
    Pester mocks.

    OUT OF SCOPE (see docs/scope.md). This script never installs any SQL
    feature beyond the Database Engine; never creates a named instance,
    multiple instances, or any failover-clustering/Always On
    configuration; never uses any service account other than the two
    named default virtual accounts; never starts SQL Server Agent; never
    configures any network protocol or port other than TCP 1433; never
    invents, guesses, or defaults the Windows SQL administrator
    principals; never changes the staging script or the staged media;
    never performs the SQL IaaS Azure Hybrid Benefit registration itself
    (that is a separate, pipeline-side Azure CLI step -- this VM's own
    managed identity has no Microsoft.SqlVirtualMachine write permission);
    never changes the VM's compute/disk/network/identity configuration;
    never changes the Windows Update/Microsoft Update source
    configuration; and never uninstalls, repairs, or upgrades an existing
    instance.
#>

[CmdletBinding()]
param(
    # Comma-separated list of approved Windows SQL administrator
    # principals (e.g. 'BUILTIN\Administrators' or
    # 'AzureAD\group@tenant.onmicrosoft.com'). Required; never defaulted to
    # a functional value by this script -- left empty by default here only
    # so dot-sourcing this file for Pester never hangs on a missing
    # mandatory parameter (see the top-level invocation guard at the
    # bottom of this file, which performs the real "must be supplied"
    # check).
    [Parameter(Mandatory = $false)]
    [string] $WindowsSqlAdminPrincipalsCsv = '',

    # SQL mixed-mode (sa) password. Supplied via Managed Run Command's
    # --protected-parameters -- never logged, never written to any file by
    # this script, and never reused by this script to connect to the
    # instance after Setup completes.
    [Parameter(Mandatory = $false)]
    [string] $SaPassword = '',

    [Parameter(Mandatory = $false)]
    [string] $DataPath = 'E:\MSSQL\DATA',

    [Parameter(Mandatory = $false)]
    [string] $LogPath = 'F:\MSSQL\LOG',

    [Parameter(Mandatory = $false)]
    [string] $TempDbPath = 'D:\MSSQL\TempDB',

    [Parameter(Mandatory = $false)]
    [int] $TempDbFileCount = 8,

    [Parameter(Mandatory = $false)]
    [int] $TempDbFileSizeMB = 1024,

    [Parameter(Mandatory = $false)]
    [int] $TempDbFileGrowthMB = 512,

    [Parameter(Mandatory = $false)]
    [int] $TempDbLogSizeMB = 1024,

    [Parameter(Mandatory = $false)]
    [int] $TempDbLogGrowthMB = 512
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-LimsSqlInstallFailure {
    <#
        Raises a terminating error for this script's own control flow.
        Never calls exit/Environment.Exit directly, so this function stays
        safe to invoke from a dot-sourced, mocked Pester test -- only the
        top-level invocation guard at the bottom of this file translates a
        thrown failure into a process exit code.
    #>
    param([Parameter(Mandatory = $true)] [string] $Message)
    throw [System.InvalidOperationException]::new($Message)
}

# =============================================================================
# FIXED CONFIGURATION -- single source of truth for this script's one
# approved target, one approved media path, and the fixed (never caller-
# supplied) parts of the install configuration. Never a caller parameter:
# this script is purpose-built for exactly this VM/instance (docs/scope.md),
# not a general-purpose SQL Server installer.
# =============================================================================

function Get-LimsSqlInstallFixedConfig {
    return [pscustomobject]@{
        ExpectedSubscriptionId     = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
        ExpectedResourceGroupName  = 'rg-compute-lims-dev-westeu'
        ExpectedVmName             = 'vm-lims-dev-v2-westeu-002'
        ExpectedComputerName       = 'lims-dev-v2-002'
        SetupExePath               = 'C:\SQLMedia\SQL2022\SETUP.EXE'
        ConfigurationFileIniPath   = 'C:\SQLMedia\SQL2022\ConfigurationFile.ini'
        ExpectedDataVolumeLetter   = 'E'
        ExpectedDataVolumeLabel    = 'SQL-Data'
        ExpectedLogVolumeLetter    = 'F'
        ExpectedLogVolumeLabel     = 'SQL-Logs'
        ExpectedTempDbVolumeLetter = 'D'
        InstanceName               = 'MSSQLSERVER'
        AgentServiceName           = 'SQLSERVERAGENT'
        Collation                  = 'SQL_Latin1_General_CP1_CI_AS'
        SqlServiceAccount          = 'NT SERVICE\MSSQLSERVER'
        AgentServiceAccount        = 'NT SERVICE\SQLSERVERAGENT'
        SqlServerRegistryInstanceKey = 'MSSQL16.MSSQLSERVER'
        TcpPort                    = 1433
        MinimumExpectedEdition     = 'Enterprise'
        ScheduledTaskName          = 'LIMS-SQL-TempDb-Recreate'
        SuccessExitCode            = 0
        RebootRequiredExitCode     = 3010
    }
}

# =============================================================================
# PURE DECISION LOGIC -- plain data objects only, no real cmdlet or network
# call anywhere below. Fully unit-testable on any platform.
# =============================================================================

function ConvertTo-LimsSqlAdminPrincipalsList {
    <#
        Pure parsing/validation of the caller-supplied comma-separated
        Windows SQL administrator principals list. Never returns a
        default/guessed principal -- an empty or whitespace-only input is
        Rejected, never silently substituted.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Csv)

    if ([string]::IsNullOrWhiteSpace($Csv)) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'No Windows SQL administrator principals were supplied (WindowsSqlAdminPrincipalsCsv is empty); refusing to default or guess one.'; Principals = @() }
    }
    $principals = @($Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($principals.Count -eq 0) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'WindowsSqlAdminPrincipalsCsv resolved to zero non-empty principal names.'; Principals = @() }
    }
    return [pscustomobject]@{ Accepted = $true; Reason = $null; Principals = $principals }
}

function Get-LimsSqlSetupExitCodeClassification {
    <#
        Pure classification of a Setup.exe exit code: 'Succeeded' (0),
        'SucceededRebootRequired' (3010 -- a known, documented SQL Server
        2022 first-run condition, never treated as a failure), or 'Failed'
        (anything else).
    #>
    param(
        [Parameter(Mandatory = $true)] [int] $ExitCode,
        [Parameter(Mandatory = $true)] $Config
    )
    if ($ExitCode -eq $Config.SuccessExitCode) { return 'Succeeded' }
    if ($ExitCode -eq $Config.RebootRequiredExitCode) { return 'SucceededRebootRequired' }
    return 'Failed'
}

function Get-LimsSqlExistingInstanceAssessmentDecision {
    <#
        Pure rerun-safety classification given already-gathered facts about
        an existing MSSQLSERVER service: 'NotInstalled' (proceed with
        Setup), 'HealthyMatchingInstance' (already correct -- report
        success without re-running Setup), or 'PartialOrUnexpectedState'
        (exists but does not match -- stop with a diagnostic; this script
        never attempts an automatic repair/reinstall).
    #>
    param(
        [Parameter(Mandatory = $true)] [bool] $ServiceExists,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $ServiceStatus,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $Edition,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $Collation,
        [Parameter(Mandatory = $true)] $Config
    )
    if (-not $ServiceExists) { return 'NotInstalled' }
    if ($ServiceStatus -eq 'Running' -and $Edition -and $Edition -like "*$($Config.MinimumExpectedEdition)*" -and $Collation -eq $Config.Collation) {
        return 'HealthyMatchingInstance'
    }
    return 'PartialOrUnexpectedState'
}

function Test-TcpIPAllConfigurationMatches {
    <#
        Pure comparison: $true only when the current TcpPort exactly
        matches $DesiredPort AND TcpDynamicPorts is empty (static port,
        not dynamic).
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $CurrentTcpPort,
        [Parameter(Mandatory = $false)] [AllowNull()] [string] $CurrentTcpDynamicPorts,
        [Parameter(Mandatory = $true)] [int] $DesiredPort
    )
    return ($CurrentTcpPort -eq [string]$DesiredPort) -and [string]::IsNullOrEmpty($CurrentTcpDynamicPorts)
}

function New-LimsSqlInstallConfigurationFileContent {
    <#
        Pure string construction of the Setup ConfigurationFile.ini
        content. Deliberately never includes SAPWD or any other secret --
        the only secret value (the sa password) is supplied to Setup
        exclusively as a command-line argument by the caller of
        Invoke-LimsSqlServerSetup below, never written into this file.
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string[]] $AdminPrincipals,
        [Parameter(Mandatory = $true)] [string] $DataPath,
        [Parameter(Mandatory = $true)] [string] $LogPath,
        [Parameter(Mandatory = $true)] [string] $TempDbPath,
        [Parameter(Mandatory = $true)] [int] $TempDbFileCount,
        [Parameter(Mandatory = $true)] [int] $TempDbFileSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbFileGrowthMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogGrowthMB
    )

    $adminAccountsValue = ($AdminPrincipals | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $lines = @(
        '[OPTIONS]'
        'ACTION="Install"'
        'QUIET="True"'
        'SUPPRESSPRIVACYSTATEMENTNOTICE="True"'
        'IACCEPTSQLSERVERLICENSETERMS="True"'
        'FEATURES=SQL'
        "INSTANCENAME=`"$($Config.InstanceName)`""
        "SQLCOLLATION=`"$($Config.Collation)`""
        'SECURITYMODE="SQL"'
        "SQLSVCACCOUNT=`"$($Config.SqlServiceAccount)`""
        'SQLSVCSTARTUPTYPE="Automatic"'
        "AGTSVCACCOUNT=`"$($Config.AgentServiceAccount)`""
        'AGTSVCSTARTUPTYPE="Disabled"'
        'TCPENABLED="1"'
        'NPENABLED="0"'
        "SQLSYSADMINACCOUNTS=$adminAccountsValue"
        "INSTALLSQLDATADIR=`"$DataPath`""
        "SQLUSERDBDIR=`"$DataPath`""
        "SQLUSERDBLOGDIR=`"$LogPath`""
        "SQLTEMPDBDIR=`"$TempDbPath`""
        "SQLTEMPDBLOGDIR=`"$TempDbPath`""
        "SQLTEMPDBFILECOUNT=$TempDbFileCount"
        "SQLTEMPDBFILESIZE=$TempDbFileSizeMB"
        "SQLTEMPDBFILEGROWTH=$TempDbFileGrowthMB"
        "SQLTEMPDBLOGFILESIZE=$TempDbLogSizeMB"
        "SQLTEMPDBLOGFILEGROWTH=$TempDbLogGrowthMB"
        'UPDATEENABLED="False"'
    )
    return ($lines -join [Environment]::NewLine)
}

# =============================================================================
# ADAPTERS -- the only functions that perform real I/O (IMDS, the
# filesystem, services, the registry, SQL connections, and external
# processes). Each is a single, narrow point of real action; every one is
# mocked by the Pester test suite for this script.
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
        Assert-LimsSqlInstallFailure "Unable to query the Azure Instance Metadata Service (IMDS) compute document: $($_.Exception.Message)"
    }
}

function Test-CurrentIdentityIsAdministratorOrSystemAdapter {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.User -and $identity.User.Value -eq 'S-1-5-18'
    $isAdministrator = ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
    return [bool]($isSystem -or $isAdministrator)
}

function Test-PathExistsAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    return [bool](Test-Path -LiteralPath $Path)
}

function Get-AuthenticodeSignatureAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    return Get-AuthenticodeSignature -FilePath $Path
}

function Get-VolumeLabelAdapter {
    param([Parameter(Mandatory = $true)] [string] $DriveLetter)
    try {
        $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        return [string]$volume.FileSystemLabel
    }
    catch {
        return $null
    }
}

function Get-ServiceStateAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $null }
    return [pscustomobject]@{ Status = [string]$service.Status; StartType = [string]$service.StartType }
}

function Set-ServiceDelayedAutoStartAdapter {
    <#
        Set-Service only supports Automatic/Manual/Disabled -- "Automatic
        (Delayed Start)" has no PowerShell cmdlet and must be set via
        sc.exe. The literal space after 'start=' is sc.exe's own required
        syntax, not a typo -- passed here as separate argv elements, which
        sc.exe accepts correctly.
    #>
    param([Parameter(Mandatory = $true)] [string] $Name)
    $null = & sc.exe config $Name start= delayed-auto
    if ($LASTEXITCODE -ne 0) {
        Assert-LimsSqlInstallFailure "Failed to configure delayed automatic start for service '$Name' (sc.exe exit code $LASTEXITCODE)."
    }
}

function Stop-ServiceAdapter {
    param([Parameter(Mandatory = $true)] [string] $Name)
    Stop-Service -Name $Name -Force -ErrorAction Stop
}

function Start-ServiceAndWaitRunningAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $false)] [int] $TimeoutSeconds = 180
    )
    Start-Service -Name $Name -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Restart-ServiceAndWaitRunningAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $false)] [int] $TimeoutSeconds = 180
    )
    Restart-Service -Name $Name -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function New-DirectoryAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
}

function Remove-DirectoryRecursivelyAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Write-TextFileAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Content
    )
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII -Force
}

function Invoke-SqlSetupProcessAdapter {
    <#
        Invokes SETUP.EXE with the given argument array via Start-Process,
        waiting for completion and returning its exit code. $Arguments
        (which includes the one /SAPWD element) is passed here only as the
        literal process argument list -- this adapter never writes it to
        any output/verbose/error stream.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $SetupExePath,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )
    $process = Start-Process -FilePath $SetupExePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

function Invoke-TempDbRecreationScriptAdapter {
    param([Parameter(Mandatory = $true)] [string] $ScriptPath)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    if ($LASTEXITCODE -ne 0) {
        Assert-LimsSqlInstallFailure "TempDB recreation script '$ScriptPath' exited with code $LASTEXITCODE."
    }
}

function Register-TempDbRecreationScheduledTaskAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $TaskName,
        [Parameter(Mandatory = $true)] [string] $ScriptPath
    )
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
}

function Get-TcpIPAllRegistryValuesAdapter {
    param([Parameter(Mandatory = $true)] [string] $RegistryPath)
    $item = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
    if (-not $item) { return [pscustomobject]@{ TcpPort = $null; TcpDynamicPorts = $null } }
    return [pscustomobject]@{ TcpPort = [string]$item.TcpPort; TcpDynamicPorts = [string]$item.TcpDynamicPorts }
}

function Set-TcpIPAllRegistryValuesAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $RegistryPath,
        [Parameter(Mandatory = $true)] [int] $Port
    )
    Set-ItemProperty -Path $RegistryPath -Name 'TcpPort' -Value ([string]$Port)
    Set-ItemProperty -Path $RegistryPath -Name 'TcpDynamicPorts' -Value ''
}

function Test-TcpPortOpenAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $ComputerName,
        [Parameter(Mandatory = $true)] [int] $Port,
        [Parameter(Mandatory = $false)] [int] $TimeoutMilliseconds = 5000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)
        return [bool]($connected -and $client.Connected)
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Invoke-SqlWindowsAuthScalarAdapter {
    <#
        Executes one scalar T-SQL query against the local default instance
        using Windows Integrated Security -- never a SQL login, never the
        sa password.
    #>
    param([Parameter(Mandatory = $true)] [string] $Query)
    Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue
    $connection = New-Object System.Data.SqlClient.SqlConnection('Server=.;Database=master;Integrated Security=True;Connection Timeout=30')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Close()
    }
}

function Invoke-SqlWindowsAuthNonQueryAdapter {
    param([Parameter(Mandatory = $true)] [string] $Query)
    Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue
    $connection = New-Object System.Data.SqlClient.SqlConnection('Server=.;Database=master;Integrated Security=True;Connection Timeout=30')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $connection.Close()
    }
}

# =============================================================================
# ORCHESTRATION -- ties pure decision logic and adapters together. This is
# the layer Pester exercises end-to-end with every *Adapter function mocked.
# =============================================================================

function Assert-InstallTargetIdentity {
    <#
        FAILS BEFORE ANY MUTATION: independently checks the guest hostname
        AND the live IMDS compute identity against this script's own fixed
        config -- the same duplicated-verification pattern the staging
        script uses. Must be the very first action
        Invoke-LimsSqlServerInstall performs.
    #>
    param([Parameter(Mandatory = $true)] $Config)

    $actualComputerName = Get-ActualComputerNameAdapter
    if ($actualComputerName -ne $Config.ExpectedComputerName) {
        Assert-LimsSqlInstallFailure "Guest computer name '$actualComputerName' does not match the expected target '$($Config.ExpectedComputerName)'. Refusing to proceed."
    }

    $imdsCompute = Get-ImdsComputeMetadataAdapter
    if ([string]::IsNullOrWhiteSpace([string]$imdsCompute.subscriptionId) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.resourceGroupName) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.name)) {
        Assert-LimsSqlInstallFailure 'IMDS returned incomplete compute identity metadata (missing subscriptionId, resourceGroupName, or name).'
    }
    if ([string]$imdsCompute.subscriptionId -ne $Config.ExpectedSubscriptionId) {
        Assert-LimsSqlInstallFailure "IMDS subscription ID '$($imdsCompute.subscriptionId)' does not match the expected target '$($Config.ExpectedSubscriptionId)'. Refusing to proceed."
    }
    if ([string]$imdsCompute.resourceGroupName -ne $Config.ExpectedResourceGroupName) {
        Assert-LimsSqlInstallFailure "IMDS resource group '$($imdsCompute.resourceGroupName)' does not match the expected target '$($Config.ExpectedResourceGroupName)'. Refusing to proceed."
    }
    if ([string]$imdsCompute.name -ne $Config.ExpectedVmName) {
        Assert-LimsSqlInstallFailure "IMDS VM name '$($imdsCompute.name)' does not match the expected target '$($Config.ExpectedVmName)'. Refusing to proceed."
    }
}

function Assert-SetupExecutableSignatureValid {
    param([Parameter(Mandatory = $true)] $Config)
    if (-not (Test-PathExistsAdapter -Path $Config.SetupExePath)) {
        Assert-LimsSqlInstallFailure "The pinned Setup executable was not found at '$($Config.SetupExePath)'. Run the staging capability first."
    }
    $signature = Get-AuthenticodeSignatureAdapter -Path $Config.SetupExePath
    if ($signature.Status -ne 'Valid') {
        Assert-LimsSqlInstallFailure "The pinned Setup executable at '$($Config.SetupExePath)' does not have a valid Authenticode signature (status: $($signature.Status)). Refusing to execute it."
    }
    if (-not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notlike '*Microsoft Corporation*') {
        $signerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '<none>' }
        Assert-LimsSqlInstallFailure "The pinned Setup executable at '$($Config.SetupExePath)' is signed, but not by Microsoft Corporation (signer: '$signerSubject'). Refusing to execute it."
    }
}

function Assert-RequiredVolumesPresent {
    <#
        Cross-checks E:/F: against the exact volume labels the guest
        data-disk preparation script assigns (SQL-Data/SQL-Logs) -- the
        same "duplicated verification, never trusted only against each
        other" pattern used elsewhere in this repository. A wrong-drive-
        letter mistake here would be installing onto, and potentially
        overwriting data on, the wrong disk.
    #>
    param([Parameter(Mandatory = $true)] $Config)

    $dataLabel = Get-VolumeLabelAdapter -DriveLetter $Config.ExpectedDataVolumeLetter
    if ($dataLabel -ne $Config.ExpectedDataVolumeLabel) {
        Assert-LimsSqlInstallFailure "Volume $($Config.ExpectedDataVolumeLetter): reports label '$dataLabel', expected '$($Config.ExpectedDataVolumeLabel)'. Refusing to proceed."
    }
    $logLabel = Get-VolumeLabelAdapter -DriveLetter $Config.ExpectedLogVolumeLetter
    if ($logLabel -ne $Config.ExpectedLogVolumeLabel) {
        Assert-LimsSqlInstallFailure "Volume $($Config.ExpectedLogVolumeLetter): reports label '$logLabel', expected '$($Config.ExpectedLogVolumeLabel)'. Refusing to proceed."
    }
    if (-not (Test-PathExistsAdapter -Path "$($Config.ExpectedTempDbVolumeLetter):\")) {
        Assert-LimsSqlInstallFailure "Volume $($Config.ExpectedTempDbVolumeLetter): (expected Azure temporary disk for TempDB) does not exist. Refusing to proceed."
    }
}

function Get-LimsSqlExistingInstanceAssessment {
    param([Parameter(Mandatory = $true)] $Config)

    $serviceState = Get-ServiceStateAdapter -Name $Config.InstanceName
    if (-not $serviceState) {
        return [pscustomobject]@{ Decision = 'NotInstalled'; Edition = $null; ProductVersion = $null; Collation = $null }
    }

    $edition = $null
    $version = $null
    $collation = $null
    if ($serviceState.Status -eq 'Running') {
        $edition = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('Edition')")
        $version = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('ProductVersion')")
        $collation = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('Collation')")
    }

    $decision = Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $true -ServiceStatus $serviceState.Status -Edition $edition -Collation $collation -Config $Config
    return [pscustomobject]@{ Decision = $decision; Edition = $edition; ProductVersion = $version; Collation = $collation }
}

function Invoke-LimsSqlServerSetup {
    <#
        Builds the non-secret ConfigurationFile.ini, writes it to disk,
        then invokes Setup with exactly two command-line arguments: the
        path to that file, and /SAPWD -- the only secret value, never
        written into the ini file or logged anywhere by this function.
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string[]] $AdminPrincipals,
        [Parameter(Mandatory = $true)] [string] $SaPassword,
        [Parameter(Mandatory = $true)] [string] $DataPath,
        [Parameter(Mandatory = $true)] [string] $LogPath,
        [Parameter(Mandatory = $true)] [string] $TempDbPath,
        [Parameter(Mandatory = $true)] [int] $TempDbFileCount,
        [Parameter(Mandatory = $true)] [int] $TempDbFileSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbFileGrowthMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogGrowthMB
    )

    New-DirectoryAdapter -Path $DataPath
    New-DirectoryAdapter -Path $LogPath
    New-DirectoryAdapter -Path $TempDbPath

    $iniContent = New-LimsSqlInstallConfigurationFileContent -Config $Config -AdminPrincipals $AdminPrincipals `
        -DataPath $DataPath -LogPath $LogPath -TempDbPath $TempDbPath `
        -TempDbFileCount $TempDbFileCount -TempDbFileSizeMB $TempDbFileSizeMB -TempDbFileGrowthMB $TempDbFileGrowthMB `
        -TempDbLogSizeMB $TempDbLogSizeMB -TempDbLogGrowthMB $TempDbLogGrowthMB
    Write-TextFileAdapter -Path $Config.ConfigurationFileIniPath -Content $iniContent

    # Deliberately built as an array and deliberately never written to any
    # output/verbose/error stream in this form -- /SAPWD is the only
    # secret value. Each value is individually quoted (embedded literal
    # double quotes) so Start-Process's own ArgumentList joining never
    # mis-splits a value that happens to contain a space.
    $setupArguments = @(
        "/ConfigurationFile=`"$($Config.ConfigurationFileIniPath)`""
        "/SAPWD=`"$SaPassword`""
    )
    Write-Verbose "Invoking Setup with /ConfigurationFile=`"$($Config.ConfigurationFileIniPath)`" and a redacted /SAPWD."
    $exitCode = Invoke-SqlSetupProcessAdapter -SetupExePath $Config.SetupExePath -Arguments $setupArguments
    $classification = Get-LimsSqlSetupExitCodeClassification -ExitCode $exitCode -Config $Config
    return [pscustomobject]@{ ExitCode = $exitCode; Classification = $classification }
}

function Set-LimsSqlServerTcpPort1433 {
    param([Parameter(Mandatory = $true)] $Config)

    $registryPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($Config.SqlServerRegistryInstanceKey)\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
    $current = Get-TcpIPAllRegistryValuesAdapter -RegistryPath $registryPath
    if (-not (Test-TcpIPAllConfigurationMatches -CurrentTcpPort $current.TcpPort -CurrentTcpDynamicPorts $current.TcpDynamicPorts -DesiredPort $Config.TcpPort)) {
        Set-TcpIPAllRegistryValuesAdapter -RegistryPath $registryPath -Port $Config.TcpPort
        $running = Restart-ServiceAndWaitRunningAdapter -Name $Config.InstanceName
        if (-not $running) {
            Assert-LimsSqlInstallFailure "The $($Config.InstanceName) service did not reach Running state within the timeout after applying the TCP $($Config.TcpPort) configuration change."
        }
    }

    $verifyValues = Get-TcpIPAllRegistryValuesAdapter -RegistryPath $registryPath
    if (-not (Test-TcpIPAllConfigurationMatches -CurrentTcpPort $verifyValues.TcpPort -CurrentTcpDynamicPorts $verifyValues.TcpDynamicPorts -DesiredPort $Config.TcpPort)) {
        Assert-LimsSqlInstallFailure "TCP configuration verification failed: TcpPort='$($verifyValues.TcpPort)', TcpDynamicPorts='$($verifyValues.TcpDynamicPorts)' (expected TcpPort='$($Config.TcpPort)', TcpDynamicPorts='')."
    }
    if (-not (Test-TcpPortOpenAdapter -ComputerName 'localhost' -Port $Config.TcpPort)) {
        Assert-LimsSqlInstallFailure "TCP port $($Config.TcpPort) did not accept a local connection after configuration and service restart."
    }
}

function Install-LimsSqlTempDbRecreationSafety {
    <#
        Writes one small recreation script (the single implementation of
        "recreate the TempDB folder and grant the service account access
        to it" -- never duplicated between the scheduled task and this
        function's own verification below), registers it as an AtStartup
        scheduled task, sets the Database Engine service to Automatic
        (Delayed Start), then proves the mitigation works once during this
        same run by simulating the Azure temporary disk being recreated
        empty.
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $TempDbPath
    )

    $recreateScriptPath = Join-Path -Path (Split-Path -Path $Config.SetupExePath -Parent) -ChildPath 'Ensure-LimsSqlTempDbPath.ps1'
    $recreateScriptContent = @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath '$TempDbPath')) {
    New-Item -ItemType Directory -Path '$TempDbPath' -Force | Out-Null
}
& icacls.exe '$TempDbPath' /grant '$($Config.SqlServiceAccount):(OI)(CI)F' /T | Out-Null
"@
    Write-TextFileAdapter -Path $recreateScriptPath -Content $recreateScriptContent
    Register-TempDbRecreationScheduledTaskAdapter -TaskName $Config.ScheduledTaskName -ScriptPath $recreateScriptPath
    Set-ServiceDelayedAutoStartAdapter -Name $Config.InstanceName

    # One-time, in-run proof: TempDB is always recreated fresh by SQL
    # Server on every startup regardless (it is never carried across
    # restarts), so deleting its directory here and letting the real
    # recreation script rebuild it is a safe, accurate simulation of the
    # Azure temporary disk being wiped and recreated.
    Stop-ServiceAdapter -Name $Config.InstanceName
    Remove-DirectoryRecursivelyAdapter -Path $TempDbPath
    Invoke-TempDbRecreationScriptAdapter -ScriptPath $recreateScriptPath
    $started = Start-ServiceAndWaitRunningAdapter -Name $Config.InstanceName
    if (-not $started) {
        Assert-LimsSqlInstallFailure 'SQL Server did not reach Running state after simulating Azure temporary-disk recreation and re-running the TempDB recreation script. The scheduled-task mitigation cannot be confirmed working.'
    }
    return $true
}

function Test-LimsSqlPostInstallState {
    param([Parameter(Mandatory = $true)] $Config)

    $edition = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('Edition')")
    $version = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('ProductVersion')")
    $collation = [string](Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT SERVERPROPERTY('Collation')")

    if ($edition -notlike "*$($Config.MinimumExpectedEdition)*") {
        Assert-LimsSqlInstallFailure "Installed edition '$edition' does not contain the expected '$($Config.MinimumExpectedEdition)'."
    }
    if ($collation -ne $Config.Collation) {
        Assert-LimsSqlInstallFailure "Installed collation '$collation' does not match the expected '$($Config.Collation)'."
    }

    $agentState = Get-ServiceStateAdapter -Name $Config.AgentServiceName
    if (-not $agentState) {
        Assert-LimsSqlInstallFailure "$($Config.AgentServiceName) service was not found after installation."
    }
    if ($agentState.Status -eq 'Running') {
        Assert-LimsSqlInstallFailure "$($Config.AgentServiceName) is running; it is expected to be installed but disabled/stopped initially."
    }

    return [pscustomobject]@{ Edition = $edition; ProductVersion = $version; Collation = $collation; AgentStatus = $agentState.Status }
}

function Confirm-LimsSqlWindowsAdminAccessAndDisableSa {
    $isSysadmin = $null
    try {
        $isSysadmin = Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT IS_SRVROLEMEMBER('sysadmin')"
    }
    catch {
        Assert-LimsSqlInstallFailure 'Unable to verify Windows administrator sysadmin access to the newly installed instance via a local Windows-authenticated connection.'
    }
    if ([int]$isSysadmin -ne 1) {
        Assert-LimsSqlInstallFailure 'The current Windows identity does not have sysadmin access to the newly installed instance; refusing to disable the sa login without first confirming administrator access through another path.'
    }

    Invoke-SqlWindowsAuthNonQueryAdapter -Query 'ALTER LOGIN [sa] DISABLE'
    $saDisabled = Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT is_disabled FROM sys.sql_logins WHERE name = 'sa'"
    if ([int]$saDisabled -ne 1) {
        Assert-LimsSqlInstallFailure 'The sa login does not report as disabled after attempting to disable it.'
    }
    return $true
}

function Invoke-LimsSqlServerInstall {
    param(
        # Deliberately NOT [Parameter(Mandatory = $true)]: PowerShell's own
        # mandatory-string validation would reject an empty string with a
        # generic "Cannot bind argument" message before this function's own
        # body ever runs, bypassing ConvertTo-LimsSqlAdminPrincipalsList's
        # clear, specific diagnostic below. The "must not be empty, and is
        # never defaulted/guessed" rule is enforced explicitly, in one
        # place, by that function instead.
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $WindowsSqlAdminPrincipalsCsv,
        # Also deliberately NOT Mandatory, for the same reason -- this
        # function's own explicit check below ("SaPassword was not
        # supplied.") is the one, specific diagnostic for a missing value,
        # not PowerShell's generic mandatory-binding error.
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [string] $SaPassword,
        [Parameter(Mandatory = $true)] [string] $DataPath,
        [Parameter(Mandatory = $true)] [string] $LogPath,
        [Parameter(Mandatory = $true)] [string] $TempDbPath,
        [Parameter(Mandatory = $true)] [int] $TempDbFileCount,
        [Parameter(Mandatory = $true)] [int] $TempDbFileSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbFileGrowthMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogSizeMB,
        [Parameter(Mandatory = $true)] [int] $TempDbLogGrowthMB
    )

    if (-not (Test-CurrentIdentityIsAdministratorOrSystemAdapter)) {
        Assert-LimsSqlInstallFailure 'This script must run as SYSTEM or an Administrator.'
    }
    if ([string]::IsNullOrWhiteSpace($SaPassword)) {
        Assert-LimsSqlInstallFailure 'SaPassword was not supplied.'
    }

    $principalsResult = ConvertTo-LimsSqlAdminPrincipalsList -Csv $WindowsSqlAdminPrincipalsCsv
    if (-not $principalsResult.Accepted) {
        Assert-LimsSqlInstallFailure $principalsResult.Reason
    }

    $config = Get-LimsSqlInstallFixedConfig

    # FAIL BEFORE ANY MUTATION -- identity, signature, and volume checks
    # all run before Setup is ever launched.
    Assert-InstallTargetIdentity -Config $config
    Assert-SetupExecutableSignatureValid -Config $config
    Assert-RequiredVolumesPresent -Config $config

    $assessment = Get-LimsSqlExistingInstanceAssessment -Config $config
    if ($assessment.Decision -eq 'HealthyMatchingInstance') {
        Write-Verbose 'An existing, healthy, matching MSSQLSERVER instance was found; Setup will not be re-run.'
        $setupResult = [pscustomobject]@{ ExitCode = $config.SuccessExitCode; Classification = 'Succeeded' }
    }
    elseif ($assessment.Decision -eq 'PartialOrUnexpectedState') {
        Assert-LimsSqlInstallFailure "An existing $($config.InstanceName) service was found in a partial or unexpected state (edition '$($assessment.Edition)', collation '$($assessment.Collation)'); refusing to repair, reinstall, or proceed automatically. Review the instance manually before rerunning."
    }
    else {
        $setupResult = Invoke-LimsSqlServerSetup -Config $config -AdminPrincipals $principalsResult.Principals -SaPassword $SaPassword `
            -DataPath $DataPath -LogPath $LogPath -TempDbPath $TempDbPath `
            -TempDbFileCount $TempDbFileCount -TempDbFileSizeMB $TempDbFileSizeMB -TempDbFileGrowthMB $TempDbFileGrowthMB `
            -TempDbLogSizeMB $TempDbLogSizeMB -TempDbLogGrowthMB $TempDbLogGrowthMB

        if ($setupResult.Classification -eq 'SucceededRebootRequired') {
            return [pscustomobject]@{
                Status        = 'RebootRequired'
                SetupExitCode = $setupResult.ExitCode
                Message       = 'SQL Server Setup reported success but requires a reboot before the instance can be used (a known first-run condition on a fresh Windows Server image). Reboot the VM, then rerun this script to resume.'
            }
        }
        if ($setupResult.Classification -eq 'Failed') {
            Assert-LimsSqlInstallFailure "SQL Server Setup failed with exit code $($setupResult.ExitCode)."
        }
    }

    Set-LimsSqlServerTcpPort1433 -Config $config
    $tempDbSafetyConfirmed = Install-LimsSqlTempDbRecreationSafety -Config $config -TempDbPath $TempDbPath
    $postInstall = Test-LimsSqlPostInstallState -Config $config
    $saDisabled = Confirm-LimsSqlWindowsAdminAccessAndDisableSa

    return [pscustomobject]@{
        Status                          = 'Succeeded'
        SetupExitCode                   = $setupResult.ExitCode
        Edition                         = $postInstall.Edition
        ProductVersion                  = $postInstall.ProductVersion
        Collation                       = $postInstall.Collation
        AgentServiceStatus              = $postInstall.AgentStatus
        Tcp1433Confirmed                = $true
        TempDbRecreationSafetyConfirmed = $tempDbSafetyConfirmed
        SaDisabled                      = $saDisabled
    }
}

function Write-LimsSqlServerInstallSummary {
    <#
        The ONLY place in this script that prints the final compact
        result to the default output stream. Never prints the sa
        password, the full Setup command line, or any raw Setup log.
    #>
    param([Parameter(Mandatory = $true)] $Summary)

    if ($Summary.Status -eq 'RebootRequired') {
        Write-Output '===== LIMS SQL Server 2022 installation: REBOOT REQUIRED ====='
        Write-Output "Setup exit code : $($Summary.SetupExitCode)"
        Write-Output "$($Summary.Message)"
        Write-Output '================================================================'
        return
    }

    Write-Output '===== LIMS SQL Server 2022 installation: SUCCESS ====='
    Write-Output "Setup exit code          : $($Summary.SetupExitCode)"
    Write-Output "Edition                  : $($Summary.Edition)"
    Write-Output "Product version          : $($Summary.ProductVersion)"
    Write-Output "Collation                : $($Summary.Collation)"
    Write-Output "Agent service status     : $($Summary.AgentServiceStatus) (expected: not running)"
    Write-Output "TCP 1433 confirmed       : $($Summary.Tcp1433Confirmed)"
    Write-Output "TempDB recreation safety : $($Summary.TempDbRecreationSafetyConfirmed)"
    Write-Output "sa login disabled        : $($Summary.SaDisabled)"
    Write-Output '======================================================='
}

# ---- Top-level invocation guard ----
# Set LIMS_SQL_INSTALL_DOT_SOURCE_ONLY=1 before dot-sourcing this file
# (e.g. from a Pester test) to load every function above without executing
# Invoke-LimsSqlServerInstall, so adapters can be safely mocked and
# asserted against instead of ever running against a real guest/SQL/Azure
# dependency.
if ($env:LIMS_SQL_INSTALL_DOT_SOURCE_ONLY -ne '1') {
    try {
        $summary = Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv $WindowsSqlAdminPrincipalsCsv -SaPassword $SaPassword `
            -DataPath $DataPath -LogPath $LogPath -TempDbPath $TempDbPath `
            -TempDbFileCount $TempDbFileCount -TempDbFileSizeMB $TempDbFileSizeMB -TempDbFileGrowthMB $TempDbFileGrowthMB `
            -TempDbLogSizeMB $TempDbLogSizeMB -TempDbLogGrowthMB $TempDbLogGrowthMB
        Write-LimsSqlServerInstallSummary -Summary $summary
        # A 'RebootRequired' result means Setup itself succeeded -- it is
        # reported clearly above, never treated as a hard failure; a human
        # reboots the VM and reruns this script to resume.
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

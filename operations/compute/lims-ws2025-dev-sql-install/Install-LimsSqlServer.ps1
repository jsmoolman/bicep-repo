<#
.SYNOPSIS
    Installs SQL Server 2022 (Database Engine only, default MSSQLSERVER
    instance) on the existing LIMS WS2025 DEV v2 SQL virtual machine
    (vm-lims-dev-v2-westeu-002), using the media already staged by
    Stage-LimsSqlInstallationMedia.ps1 at the pinned path
    C:\SQLMedia\SQL2022\SETUP.EXE, then hardens TCP 1433 as the only
    listener and installs an explicit, deterministic TempDB-preparation-
    then-start sequence for TempDB living on the Azure temporary disk.
    Disabling the sa login is a separate, documented, operator-performed
    post-install step (see docs/operations.md) -- this script only
    attempts it itself if it can verify the session performing the
    disable is actually connected as one of the explicitly approved
    Windows SQL administrator principals (never merely "has sysadmin",
    which the Managed Run Command automation identity commonly also
    satisfies); delivered via Managed Run Command, that verification is
    expected to fail every real run, by design, and the manual procedure
    is what actually completes it. Narrowly scoped under the LIMS WS2025 DEV v2
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
    unable to start after such an event. Rather than relying on the
    Database Engine's own "Automatic (Delayed Start)" timing to race a
    separate preparation task, this script disables the Database Engine
    service's own startup type entirely and installs a single Windows
    Scheduled Task (AtStartup, running as SYSTEM) that is the ONLY thing
    that ever starts it after a reboot: the task's own script waits for
    D: to become available, creates the TempDB directory if missing,
    grants the Database Engine's service account the permissions it needs
    there via icacls.exe (checking its exit code and refusing to proceed
    on failure), and only then starts the service -- an explicit,
    deterministic sequence, not a timing assumption. During install, this
    script runs that exact same script once, non-destructively (it never
    deletes the live TempDB directory or stops the running service -- the
    directory-create and icacls grant are idempotent and safe to reapply
    against a directory already in active use), as a smoke test that it
    executes successfully in this environment. A true end-to-end test
    (after a real reboot, and separately after a real Azure temporary-
    disk recreation) is a documented, DEV-only, operator-performed manual
    procedure -- see docs/operations.md.

    ADMINISTRATOR ACCESS AND sa. Managed Run Command always connects to
    SQL as the automation identity (SYSTEM), which commonly already has
    sysadmin access (e.g. via BUILTIN\Administrators membership in
    SQLSYSADMINACCOUNTS) -- a successful IS_SRVROLEMEMBER('sysadmin')
    check in that session proves the automation identity has access,
    never that an approved human administrator does. This script
    therefore only disables sa (ALTER LOGIN [sa] DISABLE) if it can
    verify the CURRENT session's own connected identity (SYSTEM_USER)
    exactly matches one of the explicitly approved Windows SQL
    administrator principals supplied to this script, in addition to
    sysadmin membership. Delivered via Managed Run Command, the connected
    identity is always SYSTEM, which never matches an approved human
    principal -- so this check is expected to fail, by design, on every
    real run through this script's normal delivery mechanism, and sa
    disabling is instead a separate, documented, operator-performed
    post-install procedure (docs/operations.md, "SQL Server 2022
    post-install administrator verification and sa disable") with exact
    commands to verify identity and role, disable sa, and confirm
    is_disabled = 1. This script always reports this step's status
    (Completed/PendingManualOperatorVerification) rather than silently
    assuming it is done. The sa password supplied to Setup is never
    reused by this script to connect to the instance afterward.

    COMPACT OUTPUT. Only a short, compact summary (Setup exit code,
    reboot status, edition, product version, collation, Agent service
    status, TCP 1433 confirmation, TempDB-startup-sequence confirmation,
    sa-disable status) is ever written to the default output stream. The
    sa password, the full Setup command line, and any raw Setup log are
    never printed.

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
        ScheduledTaskName          = 'LIMS-SQL-TempDb-PrepareAndStart'
        TempDbVolumeWaitTimeoutSeconds = 120
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

function Test-LimsSqlVerifiedAdministratorSession {
    <#
        Pure decision: a session is a verified administrator session, for
        the purpose of authorizing an sa-disable, only when BOTH its own
        connected identity exactly (case-insensitively) matches one of the
        explicitly approved Windows SQL administrator principals AND it
        reports sysadmin membership. Sysadmin membership alone is
        deliberately NOT sufficient -- Managed Run Command always connects
        as the SYSTEM automation identity, which commonly inherits
        sysadmin via BUILTIN\Administrators membership in
        SQLSYSADMINACCOUNTS; that proves the automation identity has
        access, never that an approved human administrator does.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $ConnectedIdentity,
        [Parameter(Mandatory = $true)] [bool] $IsSysadmin,
        [Parameter(Mandatory = $true)] [string[]] $ApprovedPrincipals
    )
    if (-not $IsSysadmin) { return $false }
    if ([string]::IsNullOrWhiteSpace($ConnectedIdentity)) { return $false }
    foreach ($approved in $ApprovedPrincipals) {
        if ($ConnectedIdentity -ieq $approved) { return $true }
    }
    return $false
}

function New-LimsSqlTempDbPreparationScriptContent {
    <#
        Pure string construction of the one script that both the AtStartup
        scheduled task and this script's own non-destructive smoke test
        run. Deliberately an explicit, deterministic sequence, never a
        timing assumption: wait for the TempDB volume to be available,
        create the TempDB directory if missing, grant the Database
        Engine's service account permissions there via icacls.exe,
        checking its exit code and refusing to start the service if it
        fails, and only then start the Database Engine -- the service's
        own Windows startup type is set to Disabled by the caller, so this
        script, run by the scheduled task, is the ONLY thing that ever
        starts it after a reboot. This function never includes any
        directory-deletion logic -- recreation is handled entirely by
        "create if missing", never by first removing an existing
        directory.
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $TempDbPath
    )
    return @"
`$ErrorActionPreference = 'Stop'
`$volumeDeadline = (Get-Date).AddSeconds($($Config.TempDbVolumeWaitTimeoutSeconds))
while (-not (Test-Path -LiteralPath '$($Config.ExpectedTempDbVolumeLetter):\')) {
    if ((Get-Date) -ge `$volumeDeadline) {
        Write-Error "Volume $($Config.ExpectedTempDbVolumeLetter): did not become available within $($Config.TempDbVolumeWaitTimeoutSeconds) seconds; refusing to start $($Config.InstanceName)."
        exit 1
    }
    Start-Sleep -Seconds 2
}
if (-not (Test-Path -LiteralPath '$TempDbPath')) {
    New-Item -ItemType Directory -Path '$TempDbPath' -Force | Out-Null
}
& icacls.exe '$TempDbPath' /grant '$($Config.SqlServiceAccount):(OI)(CI)F' | Out-Null
if (`$LASTEXITCODE -ne 0) {
    Write-Error "icacls.exe failed to grant $($Config.SqlServiceAccount) permissions on '$TempDbPath' (exit code `$LASTEXITCODE); refusing to start $($Config.InstanceName)."
    exit 1
}
Start-Service -Name '$($Config.InstanceName)' -ErrorAction Stop
"@
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

function Set-ServiceStartupTypeAdapter {
    <#
        Used to set the Database Engine's own Windows startup type to
        Disabled, so Windows never starts it independently after a
        reboot -- the AtStartup scheduled task registered by
        Install-LimsSqlTempDbStartupSequence becomes the only thing that
        ever starts it, removing any timing race between the two.
        Disabled/Automatic/Manual are all natively supported by
        Set-Service -- unlike "Automatic (Delayed Start)", no sc.exe
        fallback is needed here.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $StartupType
    )
    Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
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

function Invoke-TempDbPreparationScriptAdapter {
    <#
        Runs the TempDB preparation-then-start script (the exact same
        file the AtStartup scheduled task runs) and throws if it exits
        non-zero -- covers a volume-wait timeout, an icacls.exe failure,
        or a Start-Service failure, all of which the script itself
        detects and reports via its own exit code.
    #>
    param([Parameter(Mandatory = $true)] [string] $ScriptPath)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    if ($LASTEXITCODE -ne 0) {
        Assert-LimsSqlInstallFailure "TempDB preparation script '$ScriptPath' exited with code $LASTEXITCODE."
    }
}

function Register-TempDbPreparationScheduledTaskAdapter {
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

function Install-LimsSqlTempDbStartupSequence {
    <#
        Writes the one TempDB preparation-then-start script (the single
        implementation shared by the AtStartup scheduled task and this
        function's own smoke test below -- never duplicated), registers
        it as an AtStartup scheduled task, and disables the Database
        Engine service's own Windows startup type so that scheduled task
        is the ONLY thing that ever starts it after a reboot -- an
        explicit, deterministic sequence (wait for the volume, create the
        directory, apply the ACL and check icacls.exe's exit code, only
        then start the service), never a "delayed start plus hope the
        task wins the race" timing assumption.

        Then runs that exact script once, as a non-destructive smoke
        test: the directory-create and ACL-grant steps are idempotent and
        safe to reapply against a directory already in active use, and
        Start-Service against an already-Running service is a no-op --
        this never deletes the live TempDB directory and never stops the
        running instance. It only proves the script executes successfully
        in this environment; it does NOT prove the real reboot/temporary-
        disk-recreation sequence works end-to-end. See docs/operations.md
        for the separate, documented, DEV-only manual procedure that does.
    #>
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $TempDbPath
    )

    $prepScriptPath = Join-Path -Path (Split-Path -Path $Config.SetupExePath -Parent) -ChildPath 'Start-LimsSqlServerAfterTempDbPreparation.ps1'
    $prepScriptContent = New-LimsSqlTempDbPreparationScriptContent -Config $Config -TempDbPath $TempDbPath
    Write-TextFileAdapter -Path $prepScriptPath -Content $prepScriptContent
    Register-TempDbPreparationScheduledTaskAdapter -TaskName $Config.ScheduledTaskName -ScriptPath $prepScriptPath
    Set-ServiceStartupTypeAdapter -Name $Config.InstanceName -StartupType 'Disabled'

    # Non-destructive smoke test. Invoke-TempDbPreparationScriptAdapter
    # itself throws if the script exits non-zero (volume-wait timeout,
    # icacls.exe failure, or Start-Service failure), so a failure here
    # fails this function closed, before any post-install verification or
    # administrator/sa handling is ever reached.
    Invoke-TempDbPreparationScriptAdapter -ScriptPath $prepScriptPath
    $serviceState = Get-ServiceStateAdapter -Name $Config.InstanceName
    if (-not $serviceState -or $serviceState.Status -ne 'Running') {
        Assert-LimsSqlInstallFailure "After running the TempDB preparation script as a smoke test, $($Config.InstanceName) is not in the Running state (status: $(if ($serviceState) { $serviceState.Status } else { '<service not found>' }))."
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

function Invoke-LimsSqlAdminVerificationAndSaDisableAttempt {
    <#
        Only disables sa if THIS session's own connected identity can be
        verified as one of the explicitly approved Windows SQL
        administrator principals (never merely "has sysadmin" -- see
        Test-LimsSqlVerifiedAdministratorSession). Delivered via Managed
        Run Command, the connected identity is always the SYSTEM
        automation identity, which never matches an approved human
        principal, so this is expected to return
        'PendingManualOperatorVerification' on every real run through this
        script's normal delivery mechanism -- the documented,
        operator-performed procedure in docs/operations.md ("SQL Server
        2022 post-install administrator verification and sa disable") is
        what actually completes it. This function still performs the real
        check and the real disable itself (rather than skipping either
        outright) so it remains correct in any future delivery context
        where a session really is connected as an approved administrator,
        and so this function alone is the single place that decides
        whether sa is ever disabled.
    #>
    param([Parameter(Mandatory = $true)] [string[]] $ApprovedPrincipals)

    $connectedIdentity = $null
    $isSysadminRaw = $null
    try {
        $connectedIdentity = [string](Invoke-SqlWindowsAuthScalarAdapter -Query 'SELECT SYSTEM_USER')
        $isSysadminRaw = Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT IS_SRVROLEMEMBER('sysadmin')"
    }
    catch {
        Assert-LimsSqlInstallFailure 'Unable to query the connected identity or sysadmin membership of the newly installed instance via a local Windows-authenticated connection.'
    }
    $isSysadmin = ([int]$isSysadminRaw -eq 1)

    if (-not (Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity $connectedIdentity -IsSysadmin $isSysadmin -ApprovedPrincipals $ApprovedPrincipals)) {
        Write-Verbose "This session (connected identity: '$connectedIdentity') is not a verified approved-administrator session; sa will NOT be disabled automatically. Complete the documented manual post-install procedure instead."
        return 'PendingManualOperatorVerification'
    }

    Invoke-SqlWindowsAuthNonQueryAdapter -Query 'ALTER LOGIN [sa] DISABLE'
    $saDisabled = Invoke-SqlWindowsAuthScalarAdapter -Query "SELECT is_disabled FROM sys.sql_logins WHERE name = 'sa'"
    if ([int]$saDisabled -ne 1) {
        Assert-LimsSqlInstallFailure 'The sa login does not report as disabled after a verified administrator session attempted to disable it.'
    }
    return 'Completed'
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
    $tempDbStartupSequenceConfirmed = Install-LimsSqlTempDbStartupSequence -Config $config -TempDbPath $TempDbPath
    $postInstall = Test-LimsSqlPostInstallState -Config $config
    $saDisableStatus = Invoke-LimsSqlAdminVerificationAndSaDisableAttempt -ApprovedPrincipals $principalsResult.Principals

    return [pscustomobject]@{
        Status                          = 'Succeeded'
        SetupExitCode                   = $setupResult.ExitCode
        Edition                         = $postInstall.Edition
        ProductVersion                  = $postInstall.ProductVersion
        Collation                       = $postInstall.Collation
        AgentServiceStatus              = $postInstall.AgentStatus
        Tcp1433Confirmed                = $true
        TempDbStartupSequenceConfirmed  = $tempDbStartupSequenceConfirmed
        SaDisableStatus                 = $saDisableStatus
    }
}

function Write-LimsSqlServerInstallSummary {
    <#
        The ONLY place in this script that prints the final compact
        result to the default output stream. Never prints the sa
        password, the full Setup command line, or any raw Setup log.

        Deliberately distinguishes three separate facts, never collapsed
        into one ambiguous "SUCCESS": (1) Setup completion status itself
        (REBOOT REQUIRED is a distinct literal marker line, matched
        verbatim by provision-lims-ws2025-dev-sql.yml's own pipeline logic
        to gate the SQL IaaS/Azure Hybrid Benefit registration step --
        never change that one line's text without updating the pipeline
        to match); (2) whether the TCP 1433 / TempDB-startup-sequence
        hardening completed; and (3) whether administrator verification
        and the sa disable are Completed or still Pending a manual
        operator step -- this script never claims sa is disabled unless
        Invoke-LimsSqlAdminVerificationAndSaDisableAttempt actually
        verified and performed it.
    #>
    param([Parameter(Mandatory = $true)] $Summary)

    if ($Summary.Status -eq 'RebootRequired') {
        Write-Output '===== LIMS SQL Server 2022 installation: REBOOT REQUIRED ====='
        Write-Output "Setup exit code : $($Summary.SetupExitCode)"
        Write-Output "$($Summary.Message)"
        Write-Output 'Hardening (TCP 1433 / TempDB startup sequence): NOT YET PERFORMED -- resumes after reboot and rerun.'
        Write-Output 'Administrator verification and sa disable: NOT APPLICABLE YET -- complete after a successful, non-reboot-pending rerun.'
        Write-Output '================================================================'
        return
    }

    Write-Output '===== LIMS SQL Server 2022 installation: SETUP COMPLETED ====='
    Write-Output "Setup exit code          : $($Summary.SetupExitCode)"
    Write-Output "Edition                  : $($Summary.Edition)"
    Write-Output "Product version          : $($Summary.ProductVersion)"
    Write-Output "Collation                : $($Summary.Collation)"
    Write-Output "Agent service status     : $($Summary.AgentServiceStatus) (expected: not running)"
    Write-Output "TCP 1433 confirmed       : $($Summary.Tcp1433Confirmed)"
    Write-Output "Hardening                : COMPLETED (TCP 1433 confirmed: $($Summary.Tcp1433Confirmed); TempDB startup sequence confirmed: $($Summary.TempDbStartupSequenceConfirmed))"
    Write-Output "Administrator verification and sa disable: $($Summary.SaDisableStatus)"
    if ($Summary.SaDisableStatus -ne 'Completed') {
        Write-Output "  -> The sa login remains ENABLED. Complete the documented manual procedure in docs/operations.md ('SQL Server 2022 post-install administrator verification and sa disable') to verify an approved Windows administrator's own identity and sysadmin membership, disable sa, and confirm is_disabled = 1."
    }
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

<#
.SYNOPSIS
    Stages the approved SQL Server 2022 installation media from the existing
    mssql-2022-source blob container onto the existing LIMS WS2025 DEV v2 SQL
    virtual machine (vm-lims-dev-v2-westeu-002), at C:\SQLMedia\SQL2022, using
    that VM's own existing system-assigned managed identity. Narrowly scoped
    under the LIMS WS2025 DEV v2 SQL installation-media staging exception in
    docs/scope.md -- staging only, never SQL Setup/installation/configuration,
    VM configuration, RBAC, or networking.

.DESCRIPTION
    DELIVERY. This is a standalone, self-contained script with no external
    module dependency, intended to be delivered one of two ways:
      1. Azure Portal -> Run Command -> RunPowerShellScript (manual fallback;
         paste this file's content, or point the portal's "Load script"
         picker at it).
      2. .azuredevops/pipelines/provision-lims-ws2025-dev-sql.yml (primary
         route, action 'stage-only'), which submits this exact file via a
         Microsoft.Compute/virtualMachines/runCommands ("Managed Run
         Command") resource created ad hoc via `az vm run-command create`,
         waits for completion, and checks the execution state/exit code.

    PORTAL 90-MINUTE LIMIT -- USE MANAGED RUN COMMAND FOR LONGER TRANSFERS.
    The interactive Azure Portal "Run Command" blade (RunPowerShellScript)
    enforces a documented 90-minute script execution timeout
    (https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command#restrictions).
    SQL Server 2022 installation media is large enough that staging it over
    a slow or constrained network path could plausibly approach or exceed
    that limit. If the portal blade reports a timeout, or if the expected
    transfer is large/slow enough that 90 minutes is a real risk, use the
    dedicated pipeline above (or `az vm run-command create` directly) --
    Managed Run Command is asynchronous and accepts its own, separately
    configurable --timeout-in-seconds, independent of any portal session or
    browser tab remaining open.

    FAIL BEFORE ANY WRITE. Guest hostname and the Azure Instance Metadata
    Service (IMDS) identity (subscription/resource group/VM name) are each
    independently checked against this script's own fixed, hardcoded
    target (Assert-StagingTargetIdentity) BEFORE any token is requested,
    any blob is listed, any directory is created, or any file is written.
    A mismatch on either check is a hard failure with zero side effects.

    BLOB ACCESS. Reads an OAuth2 token for the `https://storage.azure.com/`
    resource from the VM's own existing system-assigned managed identity via
    IMDS (http://169.254.169.254/metadata/identity/oauth2/token) and uses it
    as a Bearer token against the Blob REST API directly over HTTPS (TLS 1.2
    enforced; proxy bypassed via the same PowerShell 5.1-compatible
    WebRequestSession/WebProxy technique used elsewhere in this repository's
    guest scripts -- see Initialize-LimsGuestDataDisks.ps1; certificate
    validation is left at its default/normal behavior -- never disabled).
    The token is held only in local variables, is never written to any
    output/verbose/error stream, and is discarded when the script ends.

    ENUMERATION AND PLANNING. Every page of the container's Blob listing
    (List Blobs, marker-based pagination) is read before any download
    decision is made. Each blob's reported length is used to: (a) compute
    and validate a safe local destination path preserving the blob's
    virtual folder structure under C:\SQLMedia\SQL2022 -- rejecting any
    blob name that would escape the staging root, traverse through an
    existing junction/reparse point, collide with another blob's
    destination under Windows' case-insensitive/trailing-dot-or-space
    filename rules, or otherwise violate Windows naming rules; and (b) sum
    the bytes that will actually need to be downloaded (excluding files
    already correctly staged) and confirm C:\ reports enough free space
    (plus a fixed safety margin) before any download begins. Any planning
    failure blocks the entire run -- zero files are written.

    RERUN-SAFE COPY. A destination file whose current length already
    exactly matches the blob's reported length is left untouched (skipped)
    -- this is what makes an interrupted run safe to simply rerun: already-
    complete files are never re-downloaded, and files unrelated to this
    container's listing are never touched or deleted. Each file that is
    missing or whose length does not match is downloaded to a temporary
    file beside its destination (same directory, `.partial` suffix), its
    downloaded length is verified against the expected length, and only
    then is it moved into its final destination -- a download that is
    interrupted partway (or that completes but yields the wrong length)
    never leaves a wrong-length file at the real destination path; it is
    simply retried (as a fresh download, not a byte-range resume) on the
    next run.

    FINAL VERIFICATION. After every planned download completes, every blob
    in the listing (not only the ones just downloaded) is re-checked against
    its destination file's actual length, and the presence of a file named
    SETUP.EXE (case-insensitive) among the verified set is confirmed, before
    this script reports success.

    COMPACT OUTPUT. Raw Blob List XML and per-file progress are written only
    to the Verbose stream (silent by default; add -Verbose to see them).
    The only default-stream (Write-Output) text is one final, compact
    summary line set: destination, expected/verified file counts, files
    copied vs. reused, total bytes copied, and the local SETUP.EXE path. On
    any failure, a short error identifying the failed operation is written
    via Write-Error and the script exits non-zero (checked by the pipeline
    above via the Managed Run Command's own execution state/exit code).

    TESTABILITY. Pure decision/planning functions (blob-listing-page
    parsing, destination-path safety validation, collision detection,
    skip/download decision, free-space arithmetic) take and return plain
    data only, with no real cmdlet call anywhere inside them -- runnable on
    any platform, including Pester on the Ubuntu CI runner this repository
    uses (see .azuredevops/pipelines/ci.yml). All real I/O (IMDS, the Blob
    REST API, the local filesystem, free-disk-space) is isolated in small
    *Adapter functions, the only functions Pester mocks.

    OUT OF SCOPE (see docs/scope.md). This script never runs SQL Server
    Setup or any other guest installer; never changes any VM configuration,
    RBAC assignment, or networking; never touches the existing SQL Server
    instance; never lists/copies anything other than this one named
    container's contents to this one named local path; and never creates,
    modifies, or reads any identity, account key, connection string, or SAS
    token.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-LimsSqlMediaStagingFailure {
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
# approved target and one approved source container. Never a caller
# parameter: this script is purpose-built for exactly this VM/container
# pair (docs/scope.md), not a general-purpose media-staging tool.
# =============================================================================

function Get-LimsSqlMediaStagingFixedConfig {
    return [pscustomobject]@{
        ExpectedSubscriptionId    = '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
        ExpectedResourceGroupName = 'rg-compute-lims-dev-westeu'
        ExpectedVmName            = 'vm-lims-dev-v2-westeu-002'
        ExpectedComputerName      = 'lims-dev-v2-002'
        StorageAccountName        = 'salimsmgmtwe'
        ContainerName             = 'mssql-2022-source'
        BlobServiceBaseUri        = 'https://salimsmgmtwe.blob.core.windows.net'
        StagingRoot               = 'C:\SQLMedia\SQL2022'
        # Fixed, conservative buffer added on top of the exact bytes this
        # run plans to download, before comparing against C:'s reported
        # free space -- never left at exactly zero margin.
        FreeSpaceSafetyMarginBytes = [int64]5 * 1024 * 1024 * 1024
        # Blob Storage REST API version used for every call below; must
        # support Azure AD (Bearer token) authorization.
        BlobApiVersion            = '2021-08-06'
        TempFileSuffix            = '.partial'
    }
}

# =============================================================================
# PURE DECISION / PLANNING LOGIC -- plain data objects only, no real cmdlet
# or network call anywhere below. Fully unit-testable on any platform.
# =============================================================================

function Get-XmlBytePrefixClassification {
    <#
        Pure, read-only classification of a byte array's leading bytes,
        for a parsing-failure diagnostic only -- it never influences how
        parsing is actually done (XmlReader does its own correct,
        byte-level encoding/BOM detection; see ConvertFrom-BlobListingXml
        below). Produces one short, safe-to-log label; never echoes the
        bytes/content themselves.
    #>
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Bytes)

    if ($Bytes.Length -eq 0) { return 'empty response body' }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return 'UTF-8 BOM'
    }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        return 'UTF-32 LE BOM'
    }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        return 'UTF-32 BE BOM'
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return 'UTF-16 LE BOM'
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return 'UTF-16 BE BOM'
    }

    if ($Bytes[0] -eq [byte][char]'<') {
        $prefixLength = [Math]::Min(5, $Bytes.Length)
        $prefixAscii = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $prefixLength)
        if ($prefixAscii -eq '<?xml') { return "no BOM, '<?xml' prefix" }
        return "no BOM, '<' prefix"
    }
    return 'no BOM, non-XML-looking prefix'
}

function ConvertFrom-BlobListingXml {
    <#
        Parses ONE page of an Azure Blob "List Blobs" REST response
        (EnumerationResults XML) into a plain array of {Name, Length} blob
        entries plus the page's own NextMarker ('' when there is no further
        page). Takes the response as plain data (raw bytes plus HTTP
        status/content-type metadata, all gathered by the
        Invoke-BlobContainerListPageAdapter below) -- never calls a real
        cmdlet itself, so this stays a PURE, Pester-testable function.

        Parses the RAW BYTES directly through a stream-based XmlReader
        rather than ever decoding to a .NET string first. This is not
        just a style choice: Windows PowerShell 5.1's own
        Invoke-WebRequest -UseBasicParsing .Content string decoding has
        been observed, when the Content-Type header carries no explicit
        charset (e.g. 'application/xml'), to mis-decode a UTF-8 BOM
        (bytes EF BB BF) into three separate, unrelated characters
        (U+00EF, U+00BB, U+00BF) rather than the single U+FEFF character
        a correct UTF-8 decode would produce -- so a leading-U+FEFF
        string trim (the prior fix for this exact symptom) never matches
        and parsing still fails at line 1, position 1. XmlReader created
        directly over the byte stream performs its own correct BOM/
        encoding detection at the byte level, which is unaffected by any
        of PowerShell's own string-decoding behavior.

        DtdProcessing is explicitly Prohibit and XmlResolver is $null --
        this response is untrusted input from the network; DTD
        processing and external entity/schema resolution are both
        refused outright, never merely limited.

        A failed Load() is wrapped by PowerShell in a
        MethodInvocationException (any direct .NET method call, as
        opposed to a cmdlet, gets this treatment); its InnerException is
        the real XmlException, unwrapped below to report line/position
        when available. On failure, only HTTP status, content type,
        byte count, a leading-byte BOM/prefix classification, and the
        XML error position are reported -- never the exception's own
        Message, and never the response body itself.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $ResponseBytes,
        [Parameter(Mandatory = $true)] [int] $HttpStatusCode,
        [Parameter(Mandatory = $false)] [string] $ContentType = ''
    )

    $doc = New-Object System.Xml.XmlDocument
    $memoryStream = $null
    $xmlReader = $null
    try {
        $memoryStream = [System.IO.MemoryStream]::new($ResponseBytes)
        $readerSettings = [System.Xml.XmlReaderSettings]::new()
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $readerSettings.CloseInput = $true
        $xmlReader = [System.Xml.XmlReader]::Create($memoryStream, $readerSettings)
        $doc.Load($xmlReader)
    }
    catch {
        $reportedException = $_.Exception
        if ($reportedException.InnerException) { $reportedException = $reportedException.InnerException }
        $positionText = '<unavailable>'
        if ($reportedException -is [System.Xml.XmlException]) {
            $xmlException = [System.Xml.XmlException]$reportedException
            if ($xmlException.LineNumber -gt 0 -or $xmlException.LinePosition -gt 0) {
                $positionText = "line $($xmlException.LineNumber), position $($xmlException.LinePosition)"
            }
        }
        $byteClassification = Get-XmlBytePrefixClassification -Bytes $ResponseBytes
        Assert-LimsSqlMediaStagingFailure (
            "Blob listing page could not be parsed as XML. HTTP status: $HttpStatusCode. " +
            "Content-Type: '$ContentType'. Byte count: $($ResponseBytes.Length). " +
            "Leading-byte classification: $byteClassification. XML error position: $positionText."
        )
    }
    finally {
        if ($xmlReader) { $xmlReader.Dispose() }
        if ($memoryStream) { $memoryStream.Dispose() }
    }

    if (-not $doc.DocumentElement -or $doc.DocumentElement.LocalName -ne 'EnumerationResults') {
        $actualRoot = if ($doc.DocumentElement) { $doc.DocumentElement.LocalName } else { '<none>' }
        Assert-LimsSqlMediaStagingFailure "Blob listing page root element was '$actualRoot', expected 'EnumerationResults'."
    }

    $blobs = @()
    $blobsNode = $doc.EnumerationResults.Blobs
    if ($blobsNode -and $blobsNode.Blob) {
        foreach ($blobElement in @($blobsNode.Blob)) {
            $name = [string]$blobElement.Name
            $lengthText = [string]$blobElement.Properties.'Content-Length'
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($lengthText)) {
                Assert-LimsSqlMediaStagingFailure "Blob listing page contains an entry with a missing Name or Content-Length."
            }
            $length = [int64]0
            if (-not [int64]::TryParse($lengthText, [ref]$length) -or $length -lt 0) {
                Assert-LimsSqlMediaStagingFailure "Blob '$name' reports a non-numeric or negative Content-Length ('$lengthText')."
            }
            $blobs += [pscustomobject]@{ Name = $name; Length = $length }
        }
    }

    $nextMarker = [string]$doc.EnumerationResults.NextMarker
    return [pscustomobject]@{ Blobs = $blobs; NextMarker = $nextMarker }
}

# Reserved Windows device names -- a segment equal to one of these (ignoring
# case and any extension) is rejected regardless of position in the path.
# https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
$script:ReservedWindowsNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

# Characters never valid anywhere inside one Windows path segment (NTFS file
# name), beyond the '/' already used as the blob virtual-directory separator.
$script:InvalidWindowsSegmentCharsPattern = '[<>:"\\|?*\x00-\x1F]'

# Classic Windows MAX_PATH; this script never opts into the \\?\ long-path
# prefix, so a destination this long or longer is rejected up front rather
# than failing unpredictably deep inside a later file operation.
$script:MaxWindowsPathLength = 260

function Test-SafeStagingRelativePath {
    <#
        Pure validation of ONE blob name as a safe relative path under the
        staging root: rejects path traversal/escape, absolute-path
        indicators, invalid Windows filename characters, reserved Windows
        device names, trailing dot/space segments (Windows silently strips
        these, which is exactly the kind of ambiguity that causes
        collisions), and a combined path longer than Windows' classic
        MAX_PATH. Returns an Accepted result (with the normalized segment
        array and the joined local-style relative path) or a Rejected
        result with a human-readable reason -- never throws.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $BlobName,
        [Parameter(Mandatory = $true)] [string] $StagingRoot
    )

    if ([string]::IsNullOrWhiteSpace($BlobName)) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'Blob name is empty.'; RelativePath = $null; Segments = @() }
    }
    if ($BlobName.StartsWith('/') -or $BlobName.StartsWith('\')) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' begins with a path separator (absolute-path shape)."; RelativePath = $null; Segments = @() }
    }

    $segments = @($BlobName -split '/')
    if ($segments.Count -eq 0) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' resolved to zero path segments."; RelativePath = $null; Segments = @() }
    }

    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment)) {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains an empty path segment (leading/trailing/double slash)."; RelativePath = $null; Segments = @() }
        }
        if ($segment -eq '.' -or $segment -eq '..') {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains a '$segment' path-traversal segment."; RelativePath = $null; Segments = @() }
        }
        if ($segment -match $script:InvalidWindowsSegmentCharsPattern) {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains a path segment ('$segment') with a character that is invalid in a Windows file name."; RelativePath = $null; Segments = @() }
        }
        if ($segment -match '^[A-Za-z]:$') {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains a drive-letter-shaped path segment ('$segment')."; RelativePath = $null; Segments = @() }
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains a path segment ('$segment') ending in a trailing dot or space, which Windows treats ambiguously."; RelativePath = $null; Segments = @() }
        }
        $baseNameForReservedCheck = $segment
        $dotIndex = $segment.IndexOf('.')
        if ($dotIndex -ge 0) { $baseNameForReservedCheck = $segment.Substring(0, $dotIndex) }
        if ($script:ReservedWindowsNames -contains $baseNameForReservedCheck.ToUpperInvariant()) {
            return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' contains a path segment ('$segment') that is a reserved Windows device name."; RelativePath = $null; Segments = @() }
        }
    }

    $relativePath = [string]::Join('\', $segments)
    $fullPath = Join-Path -Path $StagingRoot -ChildPath $relativePath
    if ($fullPath.Length -ge $script:MaxWindowsPathLength) {
        return [pscustomobject]@{ Accepted = $false; Reason = "Blob name '$BlobName' resolves to a local path $($fullPath.Length) characters long, at or beyond the classic Windows MAX_PATH limit ($script:MaxWindowsPathLength)."; RelativePath = $null; Segments = @() }
    }

    return [pscustomobject]@{ Accepted = $true; Reason = $null; RelativePath = $relativePath; Segments = $segments }
}

function Get-LimsSqlMediaStagingBlobPlanEntries {
    <#
        Pure: validates every blob's destination path (Test-SafeStagingRelativePath),
        detects case-insensitive destination-path collisions across different
        blobs, and -- only if every blob passes -- returns the full, unblocked
        set of plan entries {BlobName, DestinationPath, ExpectedLength}. Any
        single rejection or collision blocks the ENTIRE run (Blocked=$true,
        Errors=[...]) before any adapter is ever consulted for existing-file
        state, free space, or reparse points.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Blobs,
        [Parameter(Mandatory = $true)] [string] $StagingRoot
    )

    $errors = @()
    $entries = @()
    $destinationsSeen = @{}

    foreach ($blob in $Blobs) {
        $validated = Test-SafeStagingRelativePath -BlobName $blob.Name -StagingRoot $StagingRoot
        if (-not $validated.Accepted) {
            $errors += $validated.Reason
            continue
        }
        $destinationPath = Join-Path -Path $StagingRoot -ChildPath $validated.RelativePath
        $destinationKey = $destinationPath.ToLowerInvariant()
        if ($destinationsSeen.ContainsKey($destinationKey)) {
            $errors += "Blob '$($blob.Name)' and blob '$($destinationsSeen[$destinationKey])' both resolve to the same local destination path ('$destinationPath') once Windows' case-insensitive filename rules are applied; refusing to proceed with an ambiguous collision."
            continue
        }
        $destinationsSeen[$destinationKey] = $blob.Name
        $entries += [pscustomobject]@{
            BlobName        = $blob.Name
            DestinationPath = $destinationPath
            ExpectedLength  = [int64]$blob.Length
            Decision        = $null
        }
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Blocked = $true; Errors = $errors; Entries = @() }
    }
    if ($entries.Count -eq 0) {
        return [pscustomobject]@{ Blocked = $true; Errors = @('The source container listing contains zero blobs; nothing to stage.'); Entries = @() }
    }

    return [pscustomobject]@{ Blocked = $false; Errors = @(); Entries = $entries }
}

function Get-FileDownloadDecision {
    <#
        Pure skip/download decision for one file: 'Skip' only when the file
        already exists AND its current length exactly equals the expected
        length; 'Download' for a missing file or any length mismatch.
        $ExistingLength is $null (never 0) when the destination file does
        not exist at all, so a genuine zero-byte expected/actual length is
        never confused with "missing."
    #>
    param(
        [Parameter(Mandatory = $true)] [int64] $ExpectedLength,
        [Parameter(Mandatory = $false)] [AllowNull()] $ExistingLength
    )
    if ($null -ne $ExistingLength -and [int64]$ExistingLength -eq $ExpectedLength) {
        return 'Skip'
    }
    return 'Download'
}

function Get-RequiredFreeBytes {
    <#
        Pure: sum of ExpectedLength across only the entries decided
        'Download' (entries already 'Skip' need no additional free space),
        plus the fixed safety margin -- never exactly the bare sum.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Entries,
        [Parameter(Mandatory = $true)] [int64] $SafetyMarginBytes
    )
    $sum = [int64]0
    foreach ($entry in $Entries) {
        if ($entry.Decision -eq 'Download') { $sum += [int64]$entry.ExpectedLength }
    }
    return $sum + $SafetyMarginBytes
}

function Test-SufficientFreeSpace {
    <#
        Pure comparison. Returns $null when $AvailableBytes is enough to
        cover $RequiredBytes (which already includes the safety margin --
        see Get-RequiredFreeBytes), or a human-readable reason string when
        it is not.
    #>
    param(
        [Parameter(Mandatory = $true)] [int64] $RequiredBytes,
        [Parameter(Mandatory = $true)] [int64] $AvailableBytes
    )
    if ($AvailableBytes -ge $RequiredBytes) { return $null }
    return "C: reports $AvailableBytes free bytes, which is less than the $RequiredBytes bytes required to stage the planned downloads (including a fixed safety margin)."
}

function Get-UniqueStagingDirectories {
    <#
        Pure: returns the full, de-duplicated set of directory paths --
        including the staging root itself -- that will be traversed or
        created to hold every entry's DestinationPath. Used so every one of
        them can be checked for a pre-existing junction/reparse point
        BEFORE any directory is created or any file is written (never only
        the deepest directory per file, since a reparse point could exist
        at any intermediate level).
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Entries,
        [Parameter(Mandatory = $true)] [string] $StagingRoot
    )

    $directories = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $rootKey = $StagingRoot.TrimEnd('\').ToLowerInvariant()
    if (-not $seen.ContainsKey($rootKey)) { $seen[$rootKey] = $true; $directories.Add($StagingRoot.TrimEnd('\')) }

    foreach ($entry in $Entries) {
        $dir = Split-Path -Path $entry.DestinationPath -Parent
        $chain = New-Object System.Collections.Generic.List[string]
        while ($dir -and $dir.TrimEnd('\').ToLowerInvariant() -ne $rootKey -and $dir.Length -ge $StagingRoot.Length) {
            $chain.Insert(0, $dir)
            $parent = Split-Path -Path $dir -Parent
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
        foreach ($d in $chain) {
            $key = $d.TrimEnd('\').ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $directories.Add($d) }
        }
    }

    return @($directories.ToArray())
}

# =============================================================================
# ADAPTERS -- the only functions that perform real I/O (IMDS, the Blob REST
# API over HTTPS, and the local filesystem). Each is a single, narrow point
# of real action; every one is mocked by the Pester test suite for this
# script. The access token is handled ONLY inside these adapters and the
# orchestration layer immediately below -- it is never written to any
# output/verbose/error stream anywhere in this file.
# =============================================================================

function Set-Tls12SecurityProtocolAdapter {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function New-NoProxyWebSessionAdapter {
    <#
        PowerShell 5.1-compatible proxy bypass: -NoProxy on
        Invoke-WebRequest/Invoke-RestMethod requires PowerShell 6+ and is
        unavailable in Windows PowerShell 5.1 (Run Command's default
        Windows runtime). Uses the same empty-System.Net.WebProxy-bound-to-
        a-WebRequestSession technique already established in this
        repository's Initialize-LimsGuestDataDisks.ps1 (itself taken from
        Microsoft's own IMDS sample/troubleshooting guidance).
    #>
    $proxy = New-Object System.Net.WebProxy
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $webSession.Proxy = $proxy
    return $webSession
}

function Get-ActualComputerNameAdapter {
    return $env:COMPUTERNAME
}

function Get-ImdsComputeMetadataAdapter {
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json'
    try {
        return Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -WebSession (New-NoProxyWebSessionAdapter) -TimeoutSec 15
    }
    catch {
        Assert-LimsSqlMediaStagingFailure "Unable to query the Azure Instance Metadata Service (IMDS) compute document: $($_.Exception.Message)"
    }
}

function Get-ManagedIdentityAccessTokenAdapter {
    <#
        Requests an OAuth2 token for https://storage.azure.com/ from this
        VM's own existing system-assigned managed identity via IMDS. The
        token string is returned to the caller and MUST NOT be logged by
        any caller -- this function itself never writes it to any stream.
    #>
    param([Parameter(Mandatory = $true)] [string] $Resource)

    $encodedResource = [uri]::EscapeDataString($Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource"
    try {
        $response = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $uri -WebSession (New-NoProxyWebSessionAdapter) -TimeoutSec 15
    }
    catch {
        # Deliberately generic: never interpolate $_.Exception into a
        # message that could, on some .NET versions, echo request details.
        Assert-LimsSqlMediaStagingFailure 'Unable to obtain a managed-identity access token from IMDS.'
    }
    if (-not $response -or [string]::IsNullOrWhiteSpace([string]$response.access_token)) {
        Assert-LimsSqlMediaStagingFailure 'IMDS token response did not contain an access_token.'
    }
    return [string]$response.access_token
}

function Invoke-BlobContainerListPageAdapter {
    <#
        Fetches ONE page of the container's "List Blobs" response as raw
        response BYTES plus HTTP status/content-type metadata -- never
        pre-parsed, and deliberately never string-decoded here, either.
        Parsing (including correct byte-level BOM/encoding detection) is
        the pure ConvertFrom-BlobListingXml function above, so it stays
        testable without this adapter.

        Reads the response's own raw byte stream (RawContentStream)
        rather than its already-string-decoded Content property: Windows
        PowerShell 5.1's own Content-Type-based encoding detection for
        .Content has been observed to mis-decode a UTF-8 BOM into
        unrelated garbage characters when the Content-Type header (e.g.
        'application/xml') carries no explicit charset -- exactly the
        live-incident symptom this adapter exists to avoid entirely by
        never going through that string decode in the first place.
        RawContentStream is a seekable MemoryStream that may already have
        been read by other code; its Position is explicitly verified and
        reset to 0 before this adapter reads from it, regardless.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $false)] [string] $Marker = ''
    )

    $uri = "$($Config.BlobServiceBaseUri)/$($Config.ContainerName)?restype=container&comp=list"
    if (-not [string]::IsNullOrWhiteSpace($Marker)) {
        $uri += "&marker=$([uri]::EscapeDataString($Marker))"
    }
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'x-ms-version' = $Config.BlobApiVersion
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing -WebSession (New-NoProxyWebSessionAdapter) -TimeoutSec 100
    }
    catch {
        # Deliberately interpolates only the exception's own Message --
        # never $headers (which carries the bearer token) or any response
        # body.
        Assert-LimsSqlMediaStagingFailure "Blob container list request failed: $($_.Exception.Message)"
    }

    $rawStream = $response.RawContentStream
    if ($rawStream) {
        if ($rawStream.CanSeek) { $rawStream.Position = 0 }
        $byteCount = [int64]$rawStream.Length
        $bytes = [byte[]]::new($byteCount)
        $totalRead = 0
        while ($totalRead -lt $byteCount) {
            $read = $rawStream.Read($bytes, $totalRead, $byteCount - $totalRead)
            if ($read -le 0) { break }
            $totalRead += $read
        }
    }
    elseif ($response.Content -is [byte[]]) {
        # RawContentStream is expected to be present for every real
        # Invoke-WebRequest response in Windows PowerShell 5.1; this and
        # the string fallback below exist only so an unexpected future
        # runtime change can't silently become a null-reference failure
        # here. Preferring an already-byte[] Content (binary content
        # types are returned this way) still avoids any string decode.
        $bytes = $response.Content
    }
    else {
        # Last-resort fallback: Content was already decoded to a string
        # by PowerShell itself before this adapter ever saw it -- any
        # BOM-related mis-decoding has already happened by this point.
        # Re-encoding it does not undo that; this path is intentionally
        # only reachable when neither byte-level source above exists.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$response.Content)
    }

    $contentType = ''
    if ($response.Headers -and $response.Headers.ContainsKey('Content-Type')) {
        $contentType = [string]$response.Headers['Content-Type']
    }

    return [pscustomobject]@{
        Bytes       = $bytes
        StatusCode  = [int]$response.StatusCode
        ContentType = $contentType
    }
}

function Invoke-BlobDownloadToFileAdapter {
    <#
        Downloads one blob's content directly to $DestinationPath (expected
        to be a temporary path beside the real destination -- see
        Invoke-LimsSqlMediaStagingDownload). A long timeout is used because
        SQL Server installation media files can be several gigabytes.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $BlobName,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )

    $encodedSegments = @($BlobName -split '/' | ForEach-Object { [uri]::EscapeDataString($_) })
    $encodedBlobPath = [string]::Join('/', $encodedSegments)
    $uri = "$($Config.BlobServiceBaseUri)/$($Config.ContainerName)/$encodedBlobPath"
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'x-ms-version' = $Config.BlobApiVersion
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    try {
        $null = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing -OutFile $DestinationPath -WebSession (New-NoProxyWebSessionAdapter) -TimeoutSec 3600
    }
    catch {
        Assert-LimsSqlMediaStagingFailure "Download failed for blob '$BlobName': $($_.Exception.Message)"
    }
}

function Get-FileLengthIfExistsAdapter {
    <#
        Returns the file's current length as [int64], or $null when the
        file does not exist -- the $null/0 distinction matters to
        Get-FileDownloadDecision above.
    #>
    param([Parameter(Mandatory = $true)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return $null }
    return [int64]$item.Length
}

function Get-FreeBytesOnDriveAdapter {
    param([Parameter(Mandatory = $true)] [string] $DriveLetter)
    try {
        return [int64]([System.IO.DriveInfo]::new($DriveLetter)).AvailableFreeSpace
    }
    catch {
        Assert-LimsSqlMediaStagingFailure "Unable to determine free space on drive ${DriveLetter}: $($_.Exception.Message)"
    }
}

function Test-AncestorIsReparsePointAdapter {
    <#
        $true only when $Path already exists AND is a reparse point
        (junction, directory symlink, or mount point). A path that does
        not exist yet is never a traversal risk by itself -- returns
        $false, since this script is about to create it fresh.
    #>
    param([Parameter(Mandatory = $true)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function New-StagingDirectoryAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
}

function Move-StagingFileIntoPlaceAdapter {
    param(
        [Parameter(Mandatory = $true)] [string] $TempPath,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )
    Move-Item -LiteralPath $TempPath -Destination $DestinationPath -Force
}

function Remove-StagingTempFileAdapter {
    param([Parameter(Mandatory = $true)] [string] $Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-CurrentIdentityIsAdministratorOrSystemAdapter {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.User -and $identity.User.Value -eq 'S-1-5-18'
    $isAdministrator = ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
    return [bool]($isSystem -or $isAdministrator)
}

# =============================================================================
# ORCHESTRATION -- ties pure decision logic and adapters together. This is
# the layer Pester exercises end-to-end with every *Adapter function mocked.
# =============================================================================

function Assert-StagingTargetIdentity {
    <#
        FAILS BEFORE ANY WRITE: independently checks the guest hostname AND
        the live IMDS compute identity against this script's own fixed
        config (Get-LimsSqlMediaStagingFixedConfig) -- the two sides
        agreeing with each other is never treated as sufficient. Must be
        the very first action Invoke-LimsSqlMediaStaging performs.
    #>
    param([Parameter(Mandatory = $true)] $Config)

    $actualComputerName = Get-ActualComputerNameAdapter
    if ($actualComputerName -ne $Config.ExpectedComputerName) {
        Assert-LimsSqlMediaStagingFailure "Guest computer name '$actualComputerName' does not match the expected target '$($Config.ExpectedComputerName)'. Refusing to proceed."
    }

    $imdsCompute = Get-ImdsComputeMetadataAdapter
    if ([string]::IsNullOrWhiteSpace([string]$imdsCompute.subscriptionId) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.resourceGroupName) -or
        [string]::IsNullOrWhiteSpace([string]$imdsCompute.name)) {
        Assert-LimsSqlMediaStagingFailure 'IMDS returned incomplete compute identity metadata (missing subscriptionId, resourceGroupName, or name).'
    }
    if ([string]$imdsCompute.subscriptionId -ne $Config.ExpectedSubscriptionId) {
        Assert-LimsSqlMediaStagingFailure "IMDS subscription ID '$($imdsCompute.subscriptionId)' does not match the expected target '$($Config.ExpectedSubscriptionId)'. Refusing to proceed."
    }
    if ([string]$imdsCompute.resourceGroupName -ne $Config.ExpectedResourceGroupName) {
        Assert-LimsSqlMediaStagingFailure "IMDS resource group '$($imdsCompute.resourceGroupName)' does not match the expected target '$($Config.ExpectedResourceGroupName)'. Refusing to proceed."
    }
    if ([string]$imdsCompute.name -ne $Config.ExpectedVmName) {
        Assert-LimsSqlMediaStagingFailure "IMDS VM name '$($imdsCompute.name)' does not match the expected target '$($Config.ExpectedVmName)'. Refusing to proceed."
    }
}

function Get-LimsSqlMediaStagingFullListing {
    <#
        Enumerates EVERY page of the container's Blob listing before any
        download decision is made, following NextMarker until it is empty.
        A fixed page-count cap guards against an unexpected infinite-marker
        loop rather than hanging indefinitely.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config
    )

    $allBlobs = @()
    $marker = ''
    $pageCount = 0
    $maxPages = 10000
    do {
        $pageCount++
        if ($pageCount -gt $maxPages) {
            Assert-LimsSqlMediaStagingFailure "Blob listing did not terminate after $maxPages pages; refusing to loop further."
        }
        $pageResponse = Invoke-BlobContainerListPageAdapter -AccessToken $AccessToken -Config $Config -Marker $marker
        Write-Verbose "Blob listing page $pageCount (marker='$marker'): HTTP $($pageResponse.StatusCode), Content-Type '$($pageResponse.ContentType)', $($pageResponse.Bytes.Length) byte(s)."
        $page = ConvertFrom-BlobListingXml -ResponseBytes $pageResponse.Bytes -HttpStatusCode $pageResponse.StatusCode -ContentType $pageResponse.ContentType
        $allBlobs += $page.Blobs
        $marker = $page.NextMarker
    } while (-not [string]::IsNullOrWhiteSpace($marker))

    Write-Verbose "Blob listing complete: $($allBlobs.Count) blob(s) across $pageCount page(s)."
    return $allBlobs
}

function Assert-NoReparsePointsInStagingTree {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Entries,
        [Parameter(Mandatory = $true)] [string] $StagingRoot
    )
    $directories = Get-UniqueStagingDirectories -Entries $Entries -StagingRoot $StagingRoot
    foreach ($directory in $directories) {
        if (Test-AncestorIsReparsePointAdapter -Path $directory) {
            Assert-LimsSqlMediaStagingFailure "'$directory' is an existing junction/reparse point; refusing to traverse or write through it."
        }
    }
}

function Get-LimsSqlMediaStagingPlan {
    <#
        Builds one complete, pre-write plan: full paginated listing, safe
        destination-path validation and collision detection, per-file
        skip/download decision against current destination-file state,
        junction/reparse-point safety across the whole destination tree,
        and a free-space check covering only the planned downloads. ANY
        failure at any of these stages blocks the entire plan -- zero
        files are written as a result of building this plan.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config
    )

    $blobs = Get-LimsSqlMediaStagingFullListing -AccessToken $AccessToken -Config $Config

    $pathPlan = Get-LimsSqlMediaStagingBlobPlanEntries -Blobs $blobs -StagingRoot $Config.StagingRoot
    if ($pathPlan.Blocked) {
        return [pscustomobject]@{ Blocked = $true; Errors = $pathPlan.Errors; Entries = @() }
    }

    foreach ($entry in $pathPlan.Entries) {
        $existingLength = Get-FileLengthIfExistsAdapter -Path $entry.DestinationPath
        $entry.Decision = Get-FileDownloadDecision -ExpectedLength $entry.ExpectedLength -ExistingLength $existingLength
    }

    try {
        Assert-NoReparsePointsInStagingTree -Entries $pathPlan.Entries -StagingRoot $Config.StagingRoot
    }
    catch {
        return [pscustomobject]@{ Blocked = $true; Errors = @($_.Exception.Message); Entries = @() }
    }

    $requiredBytes = Get-RequiredFreeBytes -Entries $pathPlan.Entries -SafetyMarginBytes $Config.FreeSpaceSafetyMarginBytes
    $availableBytes = Get-FreeBytesOnDriveAdapter -DriveLetter ($Config.StagingRoot.Substring(0, 1))
    $spaceError = Test-SufficientFreeSpace -RequiredBytes $requiredBytes -AvailableBytes $availableBytes
    if ($spaceError) {
        return [pscustomobject]@{ Blocked = $true; Errors = @($spaceError); Entries = @() }
    }

    return [pscustomobject]@{ Blocked = $false; Errors = @(); Entries = $pathPlan.Entries }
}

function Invoke-LimsSqlMediaStagingDownload {
    <#
        Downloads ONE planned entry to a temporary file beside its real
        destination, verifies the downloaded length exactly matches the
        expected length, then moves it into place -- never leaving a
        wrong-length file at the real destination path. The temp file is
        removed on any verification failure before this function re-throws.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] $Entry
    )

    $directory = Split-Path -Path $Entry.DestinationPath -Parent
    New-StagingDirectoryAdapter -Path $directory

    $tempPath = "$($Entry.DestinationPath)$($Config.TempFileSuffix)"
    Write-Verbose "Downloading '$($Entry.BlobName)' -> '$tempPath'."
    Invoke-BlobDownloadToFileAdapter -AccessToken $AccessToken -Config $Config -BlobName $Entry.BlobName -DestinationPath $tempPath

    $downloadedLength = Get-FileLengthIfExistsAdapter -Path $tempPath
    if ($null -eq $downloadedLength -or [int64]$downloadedLength -ne [int64]$Entry.ExpectedLength) {
        Remove-StagingTempFileAdapter -Path $tempPath
        Assert-LimsSqlMediaStagingFailure "Downloaded length for '$($Entry.BlobName)' ($downloadedLength bytes) did not match the expected length ($($Entry.ExpectedLength) bytes); the incomplete temporary file was removed. Rerun this script to retry."
    }

    Move-StagingFileIntoPlaceAdapter -TempPath $tempPath -DestinationPath $Entry.DestinationPath
}

function Invoke-LimsSqlMediaStagingPlanApply {
    <#
        Executes every 'Download' entry in the plan via
        Invoke-LimsSqlMediaStagingDownload; 'Skip' entries are left
        completely untouched. Returns {FilesCopied, FilesReused, BytesCopied}.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] $Plan
    )

    $filesCopied = 0
    $filesReused = 0
    $bytesCopied = [int64]0

    foreach ($entry in $Plan.Entries) {
        if ($entry.Decision -eq 'Skip') {
            Write-Verbose "Already staged, skipping: '$($entry.DestinationPath)'."
            $filesReused++
            continue
        }
        Invoke-LimsSqlMediaStagingDownload -AccessToken $AccessToken -Config $Config -Entry $entry
        $filesCopied++
        $bytesCopied += [int64]$entry.ExpectedLength
    }

    return [pscustomobject]@{ FilesCopied = $filesCopied; FilesReused = $filesReused; BytesCopied = $bytesCopied }
}

function Test-LimsSqlMediaStagingComplete {
    <#
        Post-copy verification: re-checks EVERY entry in the plan (not only
        the ones just downloaded) against its destination file's actual
        current length, and confirms a verified entry exists at EXACTLY
        $Config.StagingRoot\SETUP.EXE (case-insensitive full-path match --
        not merely a 'SETUP.EXE' leaf name anywhere in the tree). This is
        the one pinned path the installation capability (see
        operations/compute/lims-ws2025-dev-sql-install) itself independently
        re-verifies via Authenticode signature before ever executing it;
        pinning the exact path here too means staging can never report
        success over a same-named file sitting in an unexpected
        subdirectory. Throws with a clear reason on any gap -- this script
        never reports success without this check passing.
    #>
    param(
        [Parameter(Mandatory = $true)] $Plan,
        [Parameter(Mandatory = $true)] $Config
    )

    $verified = @()
    $missingOrMismatched = @()
    foreach ($entry in $Plan.Entries) {
        $actualLength = Get-FileLengthIfExistsAdapter -Path $entry.DestinationPath
        if ($null -ne $actualLength -and [int64]$actualLength -eq [int64]$entry.ExpectedLength) {
            $verified += $entry
        }
        else {
            $missingOrMismatched += $entry.DestinationPath
        }
    }

    if ($missingOrMismatched.Count -gt 0) {
        Assert-LimsSqlMediaStagingFailure "Final inventory verification failed: $($missingOrMismatched.Count) file(s) missing or length-mismatched, including '$($missingOrMismatched[0])'."
    }

    $pinnedSetupExePath = Join-Path -Path $Config.StagingRoot -ChildPath 'SETUP.EXE'
    $setupExeEntry = $verified | Where-Object { $_.DestinationPath -eq $pinnedSetupExePath } | Select-Object -First 1
    if (-not $setupExeEntry) {
        Assert-LimsSqlMediaStagingFailure "Final inventory verification failed: no verified file was found at the pinned path '$pinnedSetupExePath'."
    }

    return [pscustomobject]@{ VerifiedCount = $verified.Count; SetupExePath = $setupExeEntry.DestinationPath }
}

function Invoke-LimsSqlMediaStaging {
    if (-not (Test-CurrentIdentityIsAdministratorOrSystemAdapter)) {
        Assert-LimsSqlMediaStagingFailure 'This script must run as SYSTEM or an Administrator.'
    }

    $config = Get-LimsSqlMediaStagingFixedConfig

    # FAIL BEFORE ANY WRITE -- identity checks run before anything else,
    # including before a token is ever requested.
    Assert-StagingTargetIdentity -Config $config

    Set-Tls12SecurityProtocolAdapter
    $accessToken = Get-ManagedIdentityAccessTokenAdapter -Resource 'https://storage.azure.com/'

    $plan = Get-LimsSqlMediaStagingPlan -AccessToken $accessToken -Config $config
    if ($plan.Blocked) {
        Assert-LimsSqlMediaStagingFailure "Staging plan blocked before any write: $($plan.Errors -join ' | ')"
    }

    $applyResult = Invoke-LimsSqlMediaStagingPlanApply -AccessToken $accessToken -Config $config -Plan $plan
    $verification = Test-LimsSqlMediaStagingComplete -Plan $plan -Config $config

    $summary = [pscustomobject]@{
        Destination        = $config.StagingRoot
        ExpectedFileCount   = $plan.Entries.Count
        VerifiedFileCount   = $verification.VerifiedCount
        FilesCopied         = $applyResult.FilesCopied
        FilesReused         = $applyResult.FilesReused
        BytesCopied         = $applyResult.BytesCopied
        SetupExePath        = $verification.SetupExePath
    }

    # Deliberately returns ONLY $summary -- no Write-Output call happens
    # anywhere inside this function. PowerShell aggregates every
    # Write-Output call made during a function's execution together with
    # its final returned value into ONE combined output collection; mixing
    # the two here would make a caller's `$summary = Invoke-LimsSqlMediaStaging`
    # receive a jumbled array of strings-and-object instead of the clean
    # object alone (exactly the bug this comment exists to prevent
    # reintroducing). The compact human-readable printing below is a
    # separate function, called only once, only by the top-level
    # invocation guard at the bottom of this file -- never from here.
    return $summary
}

function Write-LimsSqlMediaStagingSummary {
    <#
        The ONLY place in this script that prints the final compact
        success summary to the default output stream (what Run
        Command/the portal capture as this script's "output"). Called
        exactly once, by the top-level invocation guard, after
        Invoke-LimsSqlMediaStaging has already returned successfully --
        never called from inside Invoke-LimsSqlMediaStaging itself (see
        that function's own closing comment for why).
    #>
    param([Parameter(Mandatory = $true)] $Summary)

    Write-Output '===== LIMS SQL v2 installation-media staging: SUCCESS ====='
    Write-Output "Destination         : $($Summary.Destination)"
    Write-Output "Expected files       : $($Summary.ExpectedFileCount)"
    Write-Output "Verified files       : $($Summary.VerifiedFileCount)"
    Write-Output "Files copied         : $($Summary.FilesCopied)"
    Write-Output "Files reused (skip)  : $($Summary.FilesReused)"
    Write-Output "Bytes copied         : $($Summary.BytesCopied)"
    Write-Output "SETUP.EXE path       : $($Summary.SetupExePath)"
    Write-Output '============================================================'
}

# ---- Top-level invocation guard ----
# Set LIMS_SQL_MEDIA_STAGING_DOT_SOURCE_ONLY=1 before dot-sourcing this file
# (e.g. from a Pester test) to load every function above without executing
# Invoke-LimsSqlMediaStaging, so adapters can be safely mocked and asserted
# against instead of ever running against a real guest/network/Azure.
if ($env:LIMS_SQL_MEDIA_STAGING_DOT_SOURCE_ONLY -ne '1') {
    try {
        $summary = Invoke-LimsSqlMediaStaging
        Write-LimsSqlMediaStagingSummary -Summary $summary
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

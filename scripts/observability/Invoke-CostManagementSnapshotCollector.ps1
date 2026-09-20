<#
.SYNOPSIS
  Collects one calendar month of Azure Cost Management data for the configured
  subscriptions and writes normalized snapshot rows into the
  CostManagementSnapshot_CL Log Analytics table via the Logs Ingestion API.

.DESCRIPTION
  Approved data path (see docs/operations.md):

    Azure DevOps service connection
    -> ONE management-group Cost Management query for ONE month
    -> normalize the Cost Management response
    -> map SubscriptionId to Environment from existing repo config
    -> ONE Logs Ingestion API POST
    -> CostManagementSnapshot_CL

  This script performs exactly one Cost Management API call and exactly one
  Logs Ingestion API call per execution. There is no retry loop, no automatic
  fallback to subscription-scope queries, and no pagination handling — a
  paged, throttled, schema-mismatched, or empty Cost Management response
  fails the run instead of being worked around.

  Configuration is never duplicated into a new file: managementGroupId and
  subscriptionEnvironmentMappings remain authoritative in the checked-in Cost
  Management workbook parameter file; workspaceResourceId, tableName, and
  dataCollectionRuleName remain authoritative in the checked-in LAW
  foundation parameter file. The DCR immutable ID and Direct logs-ingestion
  endpoint are never hard-coded here — they are read live from the deployed
  DCR via an authenticated, read-only ARM GET at run time.

  Intended to be invoked from
  .azuredevops/pipelines/collect-cost-management-snapshot.yml inside an
  AzureCLI@2 task (so `az` is already logged in with the pipeline's service
  connection). -ImportOnly loads only the pure functions (column resolution,
  environment mapping, month-window arithmetic, normalization) without
  executing Main and without any Azure/network call — see the guard at the
  bottom of this file. Any other invocation runs Main.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$CostParametersFile = 'config/example/observability/cost-management-workbook.bicepparam',

    [Parameter()]
    [string]$FoundationParametersFile = 'config/example/observability/cost-management-data-foundation.bicepparam',

    [Parameter()]
    [string]$Project = 'example',

    [Parameter()]
    [string]$BillingMonth = 'current',

    # Sent as the ClientType request header on the Cost Management API call.
    # Deployments may override this value.
    [Parameter()]
    [string]$ClientType = 'CostManagementSnapshotCollector',

    [Parameter()]
    [switch]$ImportOnly
)

$ErrorActionPreference = 'Stop'

# Pinned API versions (see docs/operations.md). DCR matches the API version
# used by modules/observability/cost-management-data-foundation/main.bicep.
$script:CostManagementApiVersion = '2026-06-01'
$script:DataCollectionRuleApiVersion = '2024-03-11'
$script:LogsIngestionApiVersion = '2023-01-01'

# =============================================================================
# Bicep parameter file reading
# =============================================================================

function Read-BicepParametersFile {
    <#
      Reads a .bicepparam file using `az bicep build-params --stdout` and
      returns its resolved parameters object. Handles the known build-params
      envelope: the outer JSON has a "parametersJson" property that is itself
      a JSON *string* and must be parsed a second time.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $outerJsonText = az bicep build-params --file $Path --stdout
    if ($LASTEXITCODE -ne 0) {
        throw "az bicep build-params failed against '$Path'."
    }

    $outerJson = $outerJsonText | Out-String | ConvertFrom-Json
    $innerJson = $outerJson.parametersJson | ConvertFrom-Json
    return $innerJson.parameters
}

function Get-RequiredParameterValue {
    <#
      Returns the .value of a named parameter from a build-params result,
      failing closed if the parameter is absent.
    #>
    param(
        [Parameter(Mandatory)]
        $Parameters,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourceFile
    )

    $property = $Parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        throw "Required parameter '$Name' is missing from '$SourceFile'."
    }
    return $property.Value.value
}

# =============================================================================
# Billing month window (calendar arithmetic only — never a 30-day approximation)
# =============================================================================

function Get-BillingMonthWindow {
    <#
      Resolves the requested BillingMonth ('current' or 'YYYY-MM') into a
      calendar-accurate query window.

      'current'  -> from = first day of the current UTC month, 00:00:00Z
                    to   = NowUtc (partial month; never a full six-month range)
      'YYYY-MM'  -> from = first day of that month, 00:00:00Z
                    to   = final day of that month, 23:59:59Z (complete month)
                    Must name a completed historical month — an explicit
                    'YYYY-MM' equal to the current calendar month is rejected
                    (the current, still-in-progress month has no "final day"
                    yet; use the literal 'current' for it instead).

      Rejects an invalid month format, an explicit 'YYYY-MM' naming the
      current (incomplete) calendar month, and any month later than the
      current calendar month.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BillingMonth,

        [Parameter()]
        [datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )

    $currentMonthStart = Get-Date -Year $NowUtc.Year -Month $NowUtc.Month -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0

    if ($BillingMonth -eq 'current') {
        return [pscustomobject]@{
            BillingMonthKey = $currentMonthStart.ToString('yyyy-MM')
            FromUtc         = $currentMonthStart
            ToUtc           = $NowUtc
        }
    }

    if ($BillingMonth -notmatch '^\d{4}-(0[1-9]|1[0-2])$') {
        throw "BillingMonth '$BillingMonth' is not a valid YYYY-MM value or the literal 'current'."
    }

    $monthStart = [datetime]::ParseExact($BillingMonth, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($monthStart -gt $currentMonthStart) {
        throw "BillingMonth '$BillingMonth' is in the future. The collector only accepts the current month (use 'current') or a completed past month (an exact past YYYY-MM)."
    }
    if ($monthStart -eq $currentMonthStart) {
        throw "BillingMonth '$BillingMonth' is the current, still-in-progress calendar month. An explicit YYYY-MM must name a completed historical month. Use the literal 'current' to collect the current month instead."
    }

    $monthEnd = $monthStart.AddMonths(1).AddSeconds(-1)
    return [pscustomobject]@{
        BillingMonthKey = $BillingMonth
        FromUtc         = $monthStart
        ToUtc           = $monthEnd
    }
}

# =============================================================================
# Cost Management request
# =============================================================================

function New-CostManagementRequestBody {
    <#
      Builds the Cost Management request body: ActualCost, Monthly
      granularity, SubscriptionId + ServiceName grouping, explicit
      SubscriptionId "In" filter. Subscriptions are never dynamically
      enumerated from the management group — only the configured IDs are
      ever sent.
    #>
    param(
        [Parameter(Mandatory)]
        [datetime]$FromUtc,

        [Parameter(Mandatory)]
        [datetime]$ToUtc,

        [Parameter(Mandatory)]
        [string[]]$SubscriptionIds
    )

    return [ordered]@{
        type       = 'ActualCost'
        timeframe  = 'Custom'
        timePeriod = [ordered]@{
            from = $FromUtc.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'
            to   = $ToUtc.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'
        }
        dataset    = [ordered]@{
            granularity = 'Monthly'
            aggregation = [ordered]@{
                totalCost = [ordered]@{ name = 'Cost'; function = 'Sum' }
            }
            grouping    = @(
                [ordered]@{ type = 'Dimension'; name = 'SubscriptionId' }
                [ordered]@{ type = 'Dimension'; name = 'ServiceName' }
            )
            filter      = [ordered]@{
                dimensions = [ordered]@{
                    name     = 'SubscriptionId'
                    operator = 'In'
                    values   = @($SubscriptionIds)
                }
            }
        }
    }
}

function Write-CostManagementThrottleDiagnostics {
    <#
      Prints known Cost Management rate-limit/throttle headers, if present,
      without printing the full response body or any subscription ID.
    #>
    param(
        [Parameter(Mandatory)]
        $ResponseHeaders
    )

    $knownThrottleHeaders = @(
        'x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after',
        'x-ms-ratelimit-microsoft.costmanagement-qpu-consumed',
        'x-ms-ratelimit-microsoft.costmanagement-qpu-remaining',
        'x-ms-ratelimit-microsoft.costmanagement-entity-retry-after',
        'x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after',
        'x-ms-ratelimit-microsoft.costmanagement-client-retry-after',
        'Retry-After'
    )

    Write-Host '== Cost Management throttle headers =='
    foreach ($headerName in $knownThrottleHeaders) {
        if ($ResponseHeaders.ContainsKey($headerName)) {
            $value = $ResponseHeaders[$headerName]
            if ($value -is [System.Array]) { $value = ($value -join ', ') }
            Write-Host "  $headerName = $value"
        }
    }
}

# =============================================================================
# Cost Management response validation (column NAME resolution, fail closed)
# =============================================================================

function Resolve-CostColumnIndexes {
    <#
      Resolves the index of each required column by name from
      properties.columns, never from a fixed array position. Fails closed if
      any required column is absent.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Columns
    )

    $requiredColumnNames = @('Cost', 'BillingMonth', 'SubscriptionId', 'ServiceName', 'Currency')

    $indexByName = @{}
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $indexByName[[string]$Columns[$i].name] = $i
    }

    $missingColumnNames = @($requiredColumnNames | Where-Object { -not $indexByName.ContainsKey($_) })
    if ($missingColumnNames.Count -gt 0) {
        throw "Cost Management response is missing required column(s): $($missingColumnNames -join ', ')."
    }

    return [pscustomobject]@{
        Cost           = $indexByName['Cost']
        BillingMonth   = $indexByName['BillingMonth']
        SubscriptionId = $indexByName['SubscriptionId']
        ServiceName    = $indexByName['ServiceName']
        Currency       = $indexByName['Currency']
    }
}

function Assert-CostResponseNotPaged {
    <#
      Fails closed if the Cost Management response is paged
      (properties.nextLink present). This collector intentionally issues
      exactly one Cost Management request per run and never follows
      pagination links.
    #>
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NextLink
    )

    if (-not [string]::IsNullOrEmpty($NextLink)) {
        throw 'Cost Management returned a paged response (properties.nextLink present). Not following pagination — failing closed rather than ingesting a partial result.'
    }
}

function Assert-CostResponseHasRows {
    <#
      Fails closed on zero returned rows rather than silently treating an
      empty result as valid zero-cost data.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows
    )

    if ($Rows.Count -eq 0) {
        throw 'Cost Management returned zero rows. Failing closed rather than treating this as valid zero-cost data.'
    }
}

# =============================================================================
# Normalization (Cost row -> the exact 9-column CostManagementSnapshot_CL shape)
# =============================================================================

function New-CollectionRunId {
    param(
        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$BillingMonthKey
    )

    return "cost-$Project-$BillingMonthKey-$([guid]::NewGuid().ToString())"
}

function Resolve-EnvironmentForSubscription {
    <#
      Maps a Cost Management SubscriptionId to its configured Environment
      using subscriptionEnvironmentMappings only — never Azure tags. Fails
      closed if the returned SubscriptionId is not in the configured
      mapping. Multiple subscriptions may map to the same environment; that
      is not ambiguous, because the lookup is keyed by SubscriptionId, not
      by environment.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [array]$SubscriptionEnvironmentMappings
    )

    $matches = @($SubscriptionEnvironmentMappings | Where-Object { $_.subscriptionId -ieq $SubscriptionId })
    if ($matches.Count -eq 0) {
        throw "Cost Management returned SubscriptionId '$SubscriptionId', which is not present in the configured subscriptionEnvironmentMappings."
    }
    return [string]$matches[0].environment
}

function ConvertTo-NormalizedCostRecords {
    <#
      Converts Cost Management rows into the exact 9-column
      CostManagementSnapshot_CL shape. One shared TimeGenerated and one
      shared CollectionRunId are used for every row produced by this run.
      Does not re-pivot, summarize, or otherwise modify the rows beyond the
      Cost API's own SubscriptionId + ServiceName grouping.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter(Mandatory)]
        $ColumnIndexes,

        [Parameter(Mandatory)]
        [array]$SubscriptionEnvironmentMappings,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [datetime]$CollectionTimestampUtc,

        [Parameter(Mandatory)]
        [string]$CollectionRunId
    )

    $timeGeneratedText = $CollectionTimestampUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $dateTimeStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal

    # A generic List (not "$records = foreach (...) {...}; return @($records)")
    # avoids PowerShell enumerating a single-row [ordered] hashtable result
    # into its individual dictionary entries instead of a one-element array.
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        $subscriptionId = [string]$row[$ColumnIndexes.SubscriptionId]
        $environment = Resolve-EnvironmentForSubscription -SubscriptionId $subscriptionId -SubscriptionEnvironmentMappings $SubscriptionEnvironmentMappings
        $billingMonthUtc = [datetime]::Parse([string]$row[$ColumnIndexes.BillingMonth], [System.Globalization.CultureInfo]::InvariantCulture, $dateTimeStyles)

        $records.Add([ordered]@{
                TimeGenerated   = $timeGeneratedText
                Project         = $Project
                SubscriptionId  = $subscriptionId
                Environment     = $environment
                BillingMonth    = $billingMonthUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                ServiceName     = [string]$row[$ColumnIndexes.ServiceName]
                ActualCost      = [double]$row[$ColumnIndexes.Cost]
                Currency        = [string]$row[$ColumnIndexes.Currency]
                CollectionRunId = $CollectionRunId
            })
    }

    # "return $records" streams each record individually; the caller wraps
    # this call in @() for a flat, one-element-per-row array regardless of row
    # count. Do not use "Write-Output -NoEnumerate $records" — that would
    # return the List container as a single object instead.
    return $records
}

# =============================================================================
# Live DCR discovery (immutable ID / logs-ingestion endpoint — never hard-coded)
# =============================================================================

function Get-DeployedDataCollectionRule {
    <#
      Reads the already-deployed DCR with a read-only ARM GET (via the
      already-authenticated `az` context) and returns its live
      properties.immutableId and properties.endpoints.logsIngestion. Never
      mutates the DCR. The target subscription/resource group are derived
      from workspaceResourceId, the same convention used by
      src/observability/cost-management-data-foundation/main.bicep.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceResourceId,

        [Parameter(Mandatory)]
        [string]$DataCollectionRuleName
    )

    $segments = $WorkspaceResourceId -split '/'
    if ($segments.Count -le 4) {
        throw "workspaceResourceId '$WorkspaceResourceId' does not look like a full ARM resource ID."
    }
    $subscriptionId = $segments[2]
    $resourceGroupName = $segments[4]

    $dcrArmUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DataCollectionRuleName" + "?api-version=$script:DataCollectionRuleApiVersion"

    $dcrJsonText = az rest --method get --url $dcrArmUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read the deployed Data Collection Rule '$DataCollectionRuleName' via 'az rest'."
    }

    $dcr = $dcrJsonText | Out-String | ConvertFrom-Json
    $immutableId = $dcr.properties.immutableId
    $logsIngestionEndpoint = $dcr.properties.endpoints.logsIngestion

    if ([string]::IsNullOrWhiteSpace($immutableId)) {
        throw "The deployed DCR '$DataCollectionRuleName' has no properties.immutableId."
    }
    if ([string]::IsNullOrWhiteSpace($logsIngestionEndpoint)) {
        throw "The deployed DCR '$DataCollectionRuleName' has no properties.endpoints.logsIngestion."
    }

    return [pscustomobject]@{
        ImmutableId           = $immutableId
        LogsIngestionEndpoint = $logsIngestionEndpoint
    }
}

# =============================================================================
# Main orchestration (performs Azure/network calls — not used by local tests)
# =============================================================================

function Invoke-CostManagementSnapshotCollectorMain {
    param(
        [Parameter(Mandatory)] [string]$CostParametersFile,
        [Parameter(Mandatory)] [string]$FoundationParametersFile,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$BillingMonth,
        [Parameter(Mandatory)] [string]$ClientType
    )

    try {
        Write-Host '== Cost Management snapshot collector =='
        Write-Host "Project: $Project"

        # --- Authoritative configuration (never duplicated into a new file) ---
        $costParameters = Read-BicepParametersFile -Path $CostParametersFile
        $managementGroupId = Get-RequiredParameterValue -Parameters $costParameters -Name 'managementGroupId' -SourceFile $CostParametersFile
        $subscriptionEnvironmentMappings = @(Get-RequiredParameterValue -Parameters $costParameters -Name 'subscriptionEnvironmentMappings' -SourceFile $CostParametersFile)

        $foundationParameters = Read-BicepParametersFile -Path $FoundationParametersFile
        $workspaceResourceId = Get-RequiredParameterValue -Parameters $foundationParameters -Name 'workspaceResourceId' -SourceFile $FoundationParametersFile
        $dataCollectionRuleName = Get-RequiredParameterValue -Parameters $foundationParameters -Name 'dataCollectionRuleName' -SourceFile $FoundationParametersFile
        $tableName = Get-RequiredParameterValue -Parameters $foundationParameters -Name 'tableName' -SourceFile $FoundationParametersFile
        $streamName = "Custom-$tableName"

        $environmentNames = @($subscriptionEnvironmentMappings | ForEach-Object { $_.environment } | Sort-Object -Unique)
        Write-Host "Configured subscription count: $($subscriptionEnvironmentMappings.Count)"
        Write-Host "Configured environment names: $($environmentNames -join ', ')"

        # --- Billing month window (calendar arithmetic only) ------------------
        $window = Get-BillingMonthWindow -BillingMonth $BillingMonth
        Write-Host "Selected billing month: $($window.BillingMonthKey)"
        Write-Host "Query from: $($window.FromUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        Write-Host "Query to:   $($window.ToUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

        # --- Exactly ONE Cost Management POST ----------------------------------
        $subscriptionIds = @($subscriptionEnvironmentMappings | ForEach-Object { $_.subscriptionId })
        $costRequestBody = New-CostManagementRequestBody -FromUtc $window.FromUtc -ToUtc $window.ToUtc -SubscriptionIds $subscriptionIds
        $costRequestJson = $costRequestBody | ConvertTo-Json -Depth 10

        $costUrl = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$managementGroupId/providers/Microsoft.CostManagement/query" + "?api-version=$script:CostManagementApiVersion"

        $armToken = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($armToken)) {
            throw 'Failed to obtain an ARM access token from the authenticated Azure CLI context.'
        }

        $costHeaders = @{
            'Authorization' = "Bearer $armToken"
            'Content-Type'  = 'application/json'
            'ClientType'    = $ClientType
        }

        # =====================================================================
        # EXACTLY ONE Cost Management POST. No retries. No loops. No fallback.
        # =====================================================================
        $costResponse = Invoke-WebRequest -Uri $costUrl -Method Post -Headers $costHeaders -Body $costRequestJson -ContentType 'application/json' -SkipHttpErrorCheck
        $armToken = $null

        Write-Host "Cost Management HTTP status: $($costResponse.StatusCode)"

        if ($costResponse.StatusCode -eq 429) {
            Write-CostManagementThrottleDiagnostics -ResponseHeaders $costResponse.Headers
            throw 'Cost Management request returned HTTP 429 (throttled). Not retrying — see diagnostics above.'
        }
        if ($costResponse.StatusCode -lt 200 -or $costResponse.StatusCode -ge 300) {
            throw "Cost Management request returned unexpected HTTP status $($costResponse.StatusCode). Not retrying."
        }

        $costResult = $costResponse.Content | ConvertFrom-Json
        $columns = @($costResult.properties.columns)
        $columnIndexes = Resolve-CostColumnIndexes -Columns $columns

        Assert-CostResponseNotPaged -NextLink $costResult.properties.nextLink

        $rows = @($costResult.properties.rows)
        Write-Host "Cost row count: $($rows.Count)"
        Assert-CostResponseHasRows -Rows $rows

        $currencies = @($rows | ForEach-Object { [string]$_[$columnIndexes.Currency] } | Sort-Object -Unique)
        Write-Host "Currencies returned: $($currencies -join ', ')"

        # --- Normalize into the exact 9-column LAW contract --------------------
        $collectionTimestampUtc = (Get-Date).ToUniversalTime()
        $collectionRunId = New-CollectionRunId -Project $Project -BillingMonthKey $window.BillingMonthKey
        Write-Host "CollectionRunId: $collectionRunId"

        $normalizedRecords = @(ConvertTo-NormalizedCostRecords -Rows $rows -ColumnIndexes $columnIndexes -SubscriptionEnvironmentMappings $subscriptionEnvironmentMappings -Project $Project -CollectionTimestampUtc $collectionTimestampUtc -CollectionRunId $collectionRunId)
        Write-Host "Normalized row count: $($normalizedRecords.Count)"

        # --- Live DCR discovery (never hard-coded) ------------------------------
        Write-Host "DCR name: $dataCollectionRuleName"
        $dcr = Get-DeployedDataCollectionRule -WorkspaceResourceId $workspaceResourceId -DataCollectionRuleName $dataCollectionRuleName

        # --- Exactly ONE Logs Ingestion POST -------------------------------------
        $monitorToken = az account get-access-token --resource https://monitor.azure.com/ --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($monitorToken)) {
            throw 'Failed to obtain a Monitor access token from the authenticated Azure CLI context.'
        }

        $ingestionUrl = '{0}/dataCollectionRules/{1}/streams/{2}?api-version={3}' -f `
            $dcr.LogsIngestionEndpoint.TrimEnd('/'),
            $dcr.ImmutableId,
            $streamName,
            $script:LogsIngestionApiVersion

        $ingestionHeaders = @{
            'Authorization' = "Bearer $monitorToken"
            'Content-Type'  = 'application/json'
        }
        # -InputObject (not piping into ConvertTo-Json) is required: piping a
        # one-element collection serializes as a bare JSON object, not the
        # one-element JSON array the Logs Ingestion API always requires.
        $ingestionBody = ConvertTo-Json -InputObject $normalizedRecords -Depth 5

        # =========================================================================
        # EXACTLY ONE Logs Ingestion POST for this run. No retries. No loops.
        # =========================================================================
        $ingestionResponse = Invoke-WebRequest -Uri $ingestionUrl -Method Post -Headers $ingestionHeaders -Body $ingestionBody -ContentType 'application/json' -SkipHttpErrorCheck
        $monitorToken = $null

        Write-Host "Ingestion HTTP status: $($ingestionResponse.StatusCode)"

        if ($ingestionResponse.StatusCode -lt 200 -or $ingestionResponse.StatusCode -ge 300) {
            throw "Logs Ingestion request returned unexpected HTTP status $($ingestionResponse.StatusCode). Not retrying."
        }

        Write-Host 'RESULT: SUCCESS'
        exit 0
    }
    catch {
        Write-Host 'RESULT: FAILED'
        Write-Host "Error: $($_.Exception.Message)"
        exit 1
    }
}

# Entry point guard — runs Main unless -ImportOnly was passed. Does NOT check
# $MyInvocation.InvocationName: AzureCLI@2 (scriptType: pscore,
# scriptLocation: scriptPath) dot-sources this script to run it, so an
# InvocationName-based guard would incorrectly suppress Main in the real
# pipeline. -ImportOnly is the explicit switch offline tests pass to load only
# the functions above with no Azure/network call.

if (-not $ImportOnly) {
    Invoke-CostManagementSnapshotCollectorMain -CostParametersFile $CostParametersFile -FoundationParametersFile $FoundationParametersFile -Project $Project -BillingMonth $BillingMonth -ClientType $ClientType
}

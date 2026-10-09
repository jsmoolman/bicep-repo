metadata description = 'Azure Monitor Workbook for Cost Management reporting. Reads monthly cost snapshots from the CostManagementSnapshot_CL Log Analytics table (written by scripts/observability/Invoke-CostManagementSnapshotCollector.ps1) and renders an Environment pivot grid and a Service pivot grid (with month-over-month Trend), six calendar months wide.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "contoso"). Used for parameter labelling, the deterministic workbook name, and as the Project value this workbook filters CostManagementSnapshot_CL by. Must match the value the collector script writes.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Cost Management query-scope management group ID. Not used to query Azure Cost Management directly; retained for resource-name/GUID stability and because the separate collector script reads it from this same parameter file.')
param managementGroupId string

@description('ARM resource ID of the Log Analytics workspace hosting CostManagementSnapshot_CL. Viewers require read/query access to this workspace, granted separately.')
param workspaceResourceId string

@description('Array of { subscriptionId, environment } mappings. Only the distinct environment values are used here, to build the Environment selector and zero-fill the grid. Row order also drives the Environment grid display order. subscriptionId is retained because the collector script reads this same array.')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// Environment choices, grid zero-fill, and display order all come only from
// subscriptionEnvironmentMappings — never a hard-coded list.
var allEnvironmentValues = [for m in subscriptionEnvironmentMappings: m.environment]
var configuredEnvironments = union([], allEnvironmentValues)
var environmentDropdownValues = concat(['All'], configuredEnvironments)
var configuredEnvironmentsKqlBody = join(map(configuredEnvironments, e => '"${e}"'), ', ')

// Explicit 730-day query window, matching CostManagementSnapshot_CL's
// retention, so no default time-range control can exclude older snapshots.
var lawQueryTimeContext = {
  durationMs: 63072000000
}

// Euro money formatter: two decimals, "." thousands separator, "," decimal
// separator (e.g. € 3.701,30). "-" is rendered upstream when a value is
// unavailable.
var formatMoneyKql = 'let FormatMoney = (v:double) {\n    let isNeg = v < 0;\n    let av = round(abs(v), 2);\n    let wholePart = floor(av, 1);\n    let centsInt = toint(round((av - wholePart) * 100, 0));\n    let cents = tostring(centsInt);\n    let cents2 = case(strlen(cents) == 0, "00", strlen(cents) == 1, strcat("0", cents), cents);\n    let intPart = tostring(toint(wholePart));\n    let len = strlen(intPart);\n    let r = len % 3;\n    let head = iff(r == 0, "", substring(intPart, 0, r));\n    let remainder = substring(intPart, r);\n    let remLen = strlen(remainder);\n    let groups = remLen / 3;\n    let seg1 = iff(groups >= 1, substring(remainder, 0, 3), "");\n    let seg2 = iff(groups >= 2, substring(remainder, 3, 3), "");\n    let seg3 = iff(groups >= 3, substring(remainder, 6, 3), "");\n    let segCount = iff(r == 0, groups, groups + 1);\n    let grouped = case(\n        segCount <= 1, iff(r == 0, seg1, head),\n        segCount == 2, iff(r == 0, strcat(seg1, ".", seg2), strcat(head, ".", seg1)),\n        segCount == 3, iff(r == 0, strcat(seg1, ".", seg2, ".", seg3), strcat(head, ".", seg1, ".", seg2)),\n        strcat(head, ".", seg1, ".", seg2, ".", seg3)\n    );\n    strcat(iff(isNeg, "-", ""), "€ ", grouped, ",", cents2)\n};\n'

// Shared snapshot base for both grids. Selects the newest complete collector
// run per Project + BillingMonth (CollectionRunId prefixed
// "cost-{workloadName}-", excluding synthetic/diagnostic probes) and uses
// all of that run's rows — never a per-row arg_max(), which could mix rows
// from different runs. IsValidMonth is tracked per calendar month, so a
// valid month with zero cost is distinct from a month with no snapshot.
var baseSnapshotKql = 'let ConfiguredEnvironments = datatable(Environment:string) [${configuredEnvironmentsKqlBody}];\nlet LatestRuns =\n    CostManagementSnapshot_CL\n    | where Project == "{workloadName}"\n    | where CollectionRunId startswith "cost-{workloadName}-"\n    | summarize RunTime = max(TimeGenerated) by Project, BillingMonth, CollectionRunId\n    | summarize arg_max(RunTime, CollectionRunId) by Project, BillingMonth;\nlet LatestSnapshotRows =\n    CostManagementSnapshot_CL\n    | where Project == "{workloadName}"\n    | join kind=inner (LatestRuns | project Project, BillingMonth, CollectionRunId) on Project, BillingMonth, CollectionRunId\n    | extend MonthKey = format_datetime(BillingMonth, "yyyy-MM");\nlet ValidMonths = LatestSnapshotRows | summarize by MonthKey;\nlet selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet isCurrentMonth = selectedMonth == startofmonth(now());\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (ValidMonths | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\nlet base = LatestSnapshotRows | project Cost = ActualCost, Environment, ServiceName, MonthKey;\n'

// Environment pivot grid. Rows: configured environments + a final "Total"
// row; columns: 6 calendar months + Total. Zero-fills every configured
// environment for a valid month; a cell/Total is "-" only when its month
// has no valid snapshot. Row order follows subscriptionEnvironmentMappings'
// configured order via EnvironmentDisplayOrder + array_index_of(); "Total"
// is always forced last. "Environment1" is a join duplicate-key column,
// projected away.
var kqlEnvironmentGrid = '${baseSnapshotKql}${formatMoneyKql}let EnvironmentDisplayOrder = dynamic([${configuredEnvironmentsKqlBody}]);\nlet selectedEnvList = ConfiguredEnvironments | where "{Environment}" == "All" or Environment == "{Environment}";\nlet envMonthGrid = selectedEnvList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project Environment, MonthKey, IsValidMonth;\nlet envMonthActual =\n    envMonthGrid\n    | join kind=leftouter (base | summarize ActualCost = sum(Cost) by Environment, MonthKey) on Environment, MonthKey\n    | project Environment, MonthKey, IsValidMonth, RawCost = iff(IsValidMonth, coalesce(ActualCost, 0.0), real(null));\nlet totals =\n    envMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by Environment\n    | extend Total = iff(anyInvalidMonth, real(null), SumCost)\n    | project Environment, Total;\nlet envPivotSrc = envMonthActual | extend Display = iff(IsValidMonth, FormatMoney(RawCost), "-") | project Environment, MonthKey, Display;\nlet envPivot = envPivotSrc | evaluate pivot(MonthKey, take_any(Display), Environment);\nlet grandRowSrc =\n    envMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by MonthKey, IsValidMonth\n    | extend Display = iff(IsValidMonth, FormatMoney(SumCost), "-")\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = iff(anyInvalidMonth, real(null), toscalar(totals | summarize sum(Total)));\nlet grandRow = grandPivot | extend Environment = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal));\nlet envRows =\n    envPivot\n    | join kind=inner totals on Environment\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | project-away Total, Environment1;\nunion envRows, grandRow\n| extend __DisplayOrderKey = iff(Environment == "Total", 999999, array_index_of(EnvironmentDisplayOrder, Environment))\n| order by __DisplayOrderKey asc\n| project-away __DisplayOrderKey'

// Service pivot grid, six displayed months, restricted to services present
// within that window, + final "Total" row, a "Trend" column, and a
// "Trend vs 5M Avg" column.
//
// Trend compares only the selected Report Month against the immediately
// preceding calendar month (never the other four displayed months), using
// cent-rounded aggregates (SelectedCostForTrend/PreviousCostForTrend) so it
// matches the displayed money values. Trend is "-" when the selected month
// is the current, incomplete month, or when either month has no valid
// snapshot; a missing snapshot is never treated as a zero cost for this
// comparison. FormatTrend() renders "↑/↓ xx.xx%", "→ 0.00%", or "↑/↓ New"
// (previous month had zero cost); the Total row's Trend stays blank.
//
// Trend vs 5M Avg reuses the same FormatTrend() formatter — and therefore
// the same symbols/rounding — but compares the selected Report Month
// against the arithmetic average of the other five displayed months
// (M-1..M-5), computed independently per ServiceName. It is "-" whenever
// Trend itself would be "-" (current/incomplete selected month, or the
// selected month has no valid snapshot), and additionally "-" if any one
// of the five historical months lacks a valid snapshot — the average is
// never computed from fewer than all five.
// "ServiceName1"/"ServiceName2"/"ServiceName3" are join duplicate-key
// columns, projected away.
var kqlServiceGrid = '${baseSnapshotKql}${formatMoneyKql}let filtered = base | where "{Environment}" == "All" or Environment == "{Environment}";\nlet serviceList = filtered | where MonthKey in (monthList | project MonthKey) | summarize by ServiceName;\nlet serviceMonthGrid = serviceList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project ServiceName, MonthKey, IsValidMonth;\nlet serviceMonthActual =\n    serviceMonthGrid\n    | join kind=leftouter (filtered | summarize ActualCost = sum(Cost) by ServiceName, MonthKey) on ServiceName, MonthKey\n    | project ServiceName, MonthKey, IsValidMonth, RawCost = iff(IsValidMonth, coalesce(ActualCost, 0.0), real(null));\nlet selectedMonthKey = "{ReportMonth}";\nlet previousMonthKey = toscalar(monthList | where MonthOffset == -1 | project MonthKey);\nlet selectedMonthValid = toscalar(monthList | where MonthOffset == 0 | project IsValidMonth);\nlet previousMonthValid = toscalar(monthList | where MonthOffset == -1 | project IsValidMonth);\nlet trendAvailable = not(isCurrentMonth) and selectedMonthValid and previousMonthValid;\nlet FormatTrendPct = (v:double) {\n    let r = round(v, 2);\n    let s = tostring(r);\n    let dotIdx = indexof(s, ".");\n    let wholePart = iff(dotIdx == -1, s, substring(s, 0, dotIdx));\n    let fracRaw = iff(dotIdx == -1, "", substring(s, dotIdx + 1));\n    let fracPadded = case(strlen(fracRaw) == 0, "00", strlen(fracRaw) == 1, strcat(fracRaw, "0"), substring(fracRaw, 0, 2));\n    strcat(wholePart, ".", fracPadded)\n};\nlet FormatTrend = (SelectedCost:double, PreviousCost:double) {\n    case(\n        PreviousCost == 0.0 and SelectedCost == 0.0, "→ 0.00%",\n        PreviousCost == 0.0, strcat(iff(SelectedCost > 0.0, "↑", "↓"), " New"),\n        SelectedCost == PreviousCost, "→ 0.00%",\n        SelectedCost > PreviousCost, strcat("↑ ", FormatTrendPct(abs(SelectedCost - PreviousCost) / abs(PreviousCost) * 100.0), "%"),\n        strcat("↓ ", FormatTrendPct(abs(SelectedCost - PreviousCost) / abs(PreviousCost) * 100.0), "%")\n    )\n};\nlet trendBase =\n    serviceMonthActual\n    | where MonthKey == selectedMonthKey or MonthKey == previousMonthKey\n    | summarize SelectedCost = sumif(coalesce(RawCost, 0.0), MonthKey == selectedMonthKey), PreviousCost = sumif(coalesce(RawCost, 0.0), MonthKey == previousMonthKey) by ServiceName\n    | extend SelectedCostForTrend = round(SelectedCost, 2), PreviousCostForTrend = round(PreviousCost, 2)\n    | extend Trend = iff(trendAvailable, FormatTrend(SelectedCostForTrend, PreviousCostForTrend), "-")\n    | project ServiceName, Trend;\nlet trend5mBase =\n    serviceMonthActual\n    | where MonthKey != selectedMonthKey\n    | summarize FiveMonthValidCount = countif(IsValidMonth), FiveMonthSum = sumif(coalesce(RawCost, 0.0), IsValidMonth) by ServiceName\n    | join kind=inner (serviceMonthActual | where MonthKey == selectedMonthKey | project ServiceName, SelectedRawCost = RawCost) on ServiceName\n    | extend FiveMonthAverage = FiveMonthSum / 5.0\n    | extend FiveMonthAvailable = not(isCurrentMonth) and selectedMonthValid and FiveMonthValidCount == 5\n    | extend SelectedCostForTrend5m = round(coalesce(SelectedRawCost, 0.0), 2), FiveMonthAverageForTrend = round(FiveMonthAverage, 2)\n    | extend TrendVs5MAvg = iff(FiveMonthAvailable, FormatTrend(SelectedCostForTrend5m, FiveMonthAverageForTrend), "-")\n    | project ServiceName, TrendVs5MAvg;\nlet totals =\n    serviceMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by ServiceName\n    | extend Total = iff(anyInvalidMonth, real(null), SumCost)\n    | project ServiceName, Total;\nlet servicePivotSrc = serviceMonthActual | extend Display = iff(IsValidMonth, FormatMoney(RawCost), "-") | project ServiceName, MonthKey, Display;\nlet servicePivot = servicePivotSrc | evaluate pivot(MonthKey, take_any(Display), ServiceName);\nlet grandRowSrc =\n    serviceMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by MonthKey, IsValidMonth\n    | extend Display = iff(IsValidMonth, FormatMoney(SumCost), "-")\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = iff(anyInvalidMonth, real(null), toscalar(totals | summarize sum(Total)));\nlet grandRow = grandPivot | extend ServiceName = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal)), Trend = "", TrendVs5MAvg = "";\nlet serviceRows =\n    servicePivot\n    | join kind=leftouter totals on ServiceName\n    | join kind=leftouter trendBase on ServiceName\n    | join kind=leftouter trend5mBase on ServiceName\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | extend Trend = coalesce(Trend, "-")\n    | extend TrendVs5MAvg = coalesce(TrendVs5MAvg, "-")\n    | project-away Total, ServiceName1, ServiceName2, ServiceName3;\nunion serviceRows, grandRow\n| order by iff(ServiceName == "Total", 1, 0) asc, ServiceName asc'

// ─── Workbook content ─────────────────────────────────────────────────────────

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar ──────────────────────────────────────────────
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [

          {
            id: guid(workloadName, 'p-workloadName-cost')
            version: 'KqlParameterItem/1.0'
            name: 'workloadName'
            label: 'Workload'
            type: 1
            isRequired: true
            value: workloadName
          }

          // Report Month: current month + previous 12 completed calendar
          // months. Default selection uses the query's own `selected`
          // column (MonthOffset == 0).
          {
            id: guid(workloadName, 'p-reportMonth-cost')
            version: 'KqlParameterItem/1.0'
            name: 'ReportMonth'
            label: 'Report Month'
            type: 2
            isRequired: true
            query: 'range MonthOffset from 0 to 12 step 1\n| extend MonthStart = datetime_add("month", -MonthOffset, startofmonth(now()))\n| order by MonthStart desc\n| project value=format_datetime(MonthStart, "yyyy-MM"), label=strcat(format_datetime(MonthStart, "yyyy-MM"), iff(MonthOffset == 0, " (current, month-to-date)", "")), selected=(MonthOffset == 0)'
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

          // Environment: filters already-retrieved snapshot data only.
          // Choices come from subscriptionEnvironmentMappings.
          {
            id: guid(workloadName, 'p-environment-cost')
            version: 'KqlParameterItem/1.0'
            name: 'Environment'
            label: 'Environment'
            type: 2
            isRequired: false
            jsonData: string(environmentDropdownValues)
            value: 'All'
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

        ]
      }
      name: 'parameters-visible'
    }

    // ── Title / methodology text ─────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '# Cost Management Dashboard — {workloadName}\n\n| | |\n|---|---|\n| **Report month** | {ReportMonth} |\n| **Data source** | `CostManagementSnapshot_CL` (Log Analytics) — the newest complete collector snapshot for each month, not a live Cost Management API call |\n| **Window** | Report Month and the five preceding calendar months (six columns) |\n| **Trend basis** | Percentage change between the selected completed month and the immediately preceding calendar month. Current month-to-date has no trend |\n| **Trend vs 5M Avg basis** | Percentage change between the selected completed month and the arithmetic average of the other five displayed months. Current month-to-date has no trend |\n| **Zero vs. unavailable** | € 0,00 = a valid collected snapshot exists for that month with no cost for this row. "-" = no valid collector snapshot exists for that month yet |\n| **Trend unavailable** | Both Trend and Trend vs 5M Avg are "-" when the selected month is the current incomplete month, or when the selected month has no valid snapshot. Trend is additionally "-" when the immediately preceding month has no valid snapshot; Trend vs 5M Avg is additionally "-" when any one of the five preceding months has no valid snapshot |\n| **Trend symbols** | ↑ increase · ↓ decrease · → unchanged · ↑ New = baseline (previous month, or 5-month average) was €0 |\n\nCost data is collected by a separate, manually-run process (see docs/operations.md) that writes normalized monthly snapshots into the existing central Log Analytics workspace. This workbook only reads the newest complete snapshot per month for **{workloadName}** — it never calls the Azure Cost Management API directly.'
      }
      name: 'text-title'
    }

    // ── Environment pivot grid ───────────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlEnvironmentGrid
        // Full-size (Azure Workbooks Size = Full) so all rows + Total render
        // without scrolling.
        size: 3
        title: 'Cost per Environment'
        noDataMessage: 'No cost data returned for the selected Report Month.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          formatters: [
            // Monetary columns only: the six dynamic yyyy-MM month columns
            // (matched by pattern, since their names depend on the selected
            // Report Month) plus Total use the Azure Workbooks Right
            // Aligned renderer (formatter 2). The existing FormatMoney()/"-"
            // string values themselves are unchanged.
            { columnMatch: '^\\d{4}-\\d{2}$', formatter: 2 }
            { columnMatch: '^TotalDisplay$', formatter: 2 }
          ]
          labelSettings: [
            { columnId: 'Environment',   label: 'Environment' }
            { columnId: 'TotalDisplay',  label: 'Total' }
          ]
        }
      }
      name: 'query-environment-grid'
    }

    // ── Trend guidance (shown immediately above the Service grid, where the
    // two trend columns are visible) ─────────────────────────────────────────
    {
      type: 1
      content: {
        json: '**Trend guidance**\n\n- **Trend** compares the selected Report Month with the immediately preceding month.\n- **Trend vs 5M Avg** compares the selected Report Month with the arithmetic average of the five preceding months.\n- `-` means the trend is unavailable because the selected month is still incomplete or required monthly snapshot data is unavailable.'
      }
      name: 'text-trend-guidance'
    }

    // ── Service pivot grid (with Trend) ──────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlServiceGrid
        // Full-size (Azure Workbooks Size = Full) so all service rows +
        // Total render without scrolling.
        size: 3
        title: 'Cost per Service'
        noDataMessage: 'No cost data returned for the selected Report Month and Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        // Trend / Trend vs 5M Avg get no formatter: both render as plain
        // text (arrow + percentage).
        gridSettings: {
          formatters: [
            // Monetary columns only: the six dynamic yyyy-MM month columns
            // (matched by pattern, since their names depend on the selected
            // Report Month) plus Total use the Azure Workbooks Right
            // Aligned renderer (formatter 2). The existing FormatMoney()/"-"
            // string values themselves are unchanged.
            { columnMatch: '^\\d{4}-\\d{2}$', formatter: 2 }
            { columnMatch: '^TotalDisplay$', formatter: 2 }
          ]
          labelSettings: [
            { columnId: 'ServiceName',   label: 'Service' }
            { columnId: 'TotalDisplay',  label: 'Total' }
            { columnId: 'Trend',         label: 'Trend' }
            { columnId: 'TrendVs5MAvg',  label: 'Trend vs 5M Avg' }
          ]
        }
      }
      name: 'query-service-grid'
    }

  ]
}

// Deterministic resource name, independent of workbookDisplayName, so
// renaming the title never changes resource identity.
resource workbook 'microsoft.insights/workbooks@2023-06-01' = {
  name: guid(workloadName, managementGroupId, workspaceResourceId, 'cost-management-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: workbookDisplayName
    serializedData: string(workbookContent)
    version: '1.0'
    category: 'workbook'
    sourceId: workspaceResourceId
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed workbook.')
output workbookResourceId string = workbook.id

@description('GUID name of the deployed workbook resource.')
output workbookName string = workbook.name

@description('Display name of the deployed workbook.')
output workbookDisplayName string = workbook.properties.displayName

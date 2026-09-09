metadata description = 'Azure Monitor Workbook — Cost Management dashboard, refactored to read exclusively from the CostManagementSnapshot_CL Log Analytics table (append-only monthly snapshots written by the separate scripts/observability/Invoke-CostManagementSnapshotCollector.ps1 collector). This workbook no longer calls the Azure Cost Management REST API itself: for each Project + BillingMonth it selects only the rows belonging to the newest complete collector run (CollectionRunId), then pivots and trends that data as Log Analytics KQL. An Environment pivot grid and a Service pivot grid, six calendar months wide, are produced. Environment selection filters the already-retrieved snapshot data only — it never changes which LAW rows are read.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('''Workload/project short code (e.g. "lims"). Used for parameter labelling, the deterministic workbook name seed, and as the exact value of the Project column this workbook filters CostManagementSnapshot_CL by. This must match the Project value the collector writes for this workload (the collector''s own -Project pipeline parameter) — both default to the same project short code by convention; there is deliberately no second, separate "project" parameter here, so this value is never duplicated across two configuration points that could drift apart.''')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('''Historical Azure Cost Management query-scope management group ID. This workbook no longer queries Azure Cost Management directly (it reads only CostManagementSnapshot_CL), so this value is no longer used to scope any query. It is retained as a declared parameter for two narrow reasons only: (1) it remains one of the deterministic inputs to this workbook''s resource name/GUID (see the resource below), so this LAW refactor does not change the workbook''s identity and does not orphan/duplicate the existing deployed resource; and (2) the checked-in config/nfi/lims/observability/cost-management-workbook.bicepparam file that declares it is also the collector script''s (scripts/observability/Invoke-CostManagementSnapshotCollector.ps1) own authoritative configuration source for its live Cost Management query scope, read directly via `az bicep build-params` — removing or renaming this parameter here would break that unrelated, unchanged collector contract.''')
param managementGroupId string

@description('''Full ARM resource ID of the existing central Log Analytics workspace that hosts CostManagementSnapshot_CL. This workbook queries that table directly and exclusively for all cost figures — it is no longer used merely as a stateless compute engine for an externally-supplied JSON blob. Workbook viewers require read/query access to this workspace; that access is reviewed and granted separately and is not part of this deployment.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. This workbook no longer uses the subscriptionId values (CostManagementSnapshot_CL rows already carry their own Environment column, written by the collector) — only the distinct set of environment values is used here, to build the Environment selector''s choices and to zero-fill every configured environment in the Environment grid even when a valid monthly snapshot has no cost row for it. subscriptionId remains part of this array''s shape only because the collector (scripts/observability/Invoke-CostManagementSnapshotCollector.ps1) reads this exact same array, by this exact parameter name, from the same checked-in parameter file, to build its own Cost Management subscription filter and Environment mapping — that contract is unrelated to this workbook and is not changed here.''')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Derived configuration (no hard-coded environment names) ─────────────────
// The set of Environment values shown/zero-filled in the grid, and offered in
// the Environment selector, comes only from the caller's
// subscriptionEnvironmentMappings configuration — never a literal list — so
// this module stays reusable for a different project with a different
// environment set. Multiple subscriptions may legitimately map to the same
// environment; union() de-duplicates the resulting environment list.

var allEnvironmentValues = [for m in subscriptionEnvironmentMappings: m.environment]
var configuredEnvironments = union([], allEnvironmentValues)
var environmentDropdownValues = concat(['All'], configuredEnvironments)
var configuredEnvironmentsKqlBody = join(map(configuredEnvironments, e => '"${e}"'), ', ')

// ─── Explicit LAW query time context ──────────────────────────────────────────
// CostManagementSnapshot_CL is provisioned with retentionInDays = 730 (see
// modules/observability/cost-management-data-foundation/main.bicep). Both grid
// queries below set this exact 730-day window explicitly via `timeContext`
// rather than relying on any workbook-level default time-range control, so a
// short default lookback can never silently exclude older, still-in-retention
// monthly snapshots. 730 days * 24h * 60m * 60s * 1000ms = 63,072,000,000 ms.

var lawQueryTimeContext = {
  durationMs: 63072000000
}

// ─── KQL: shared money-formatting helper (embedded in both grid queries) ──────
// Euro, two decimals, "." thousands separator, "," decimal separator — e.g. € 3.701,30.
// Renders "-" upstream (not inside this helper) whenever the underlying value is unavailable.
// Unchanged by this LAW migration.

var formatMoneyKql = 'let FormatMoney = (v:double) {\n    let isNeg = v < 0;\n    let av = abs(v);\n    let cents = tostring(round((av - floor(av, 1)) * 100, 0));\n    let cents2 = case(strlen(cents) == 0, "00", strlen(cents) == 1, strcat("0", cents), cents);\n    let intPart = tostring(toint(floor(av, 1)));\n    let len = strlen(intPart);\n    let r = len % 3;\n    let head = iff(r == 0, "", substring(intPart, 0, r));\n    let remainder = substring(intPart, r);\n    let remLen = strlen(remainder);\n    let groups = remLen / 3;\n    let seg1 = iff(groups >= 1, substring(remainder, 0, 3), "");\n    let seg2 = iff(groups >= 2, substring(remainder, 3, 3), "");\n    let seg3 = iff(groups >= 3, substring(remainder, 6, 3), "");\n    let segCount = iff(r == 0, groups, groups + 1);\n    let grouped = case(\n        segCount <= 1, iff(r == 0, seg1, head),\n        segCount == 2, iff(r == 0, strcat(seg1, ".", seg2), strcat(head, ".", seg1)),\n        segCount == 3, iff(r == 0, strcat(seg1, ".", seg2, ".", seg3), strcat(head, ".", seg1, ".", seg2)),\n        strcat(head, ".", seg1, ".", seg2, ".", seg3)\n    );\n    strcat(iff(isNeg, "-", ""), "€ ", grouped, ",", cents2)\n};\n'

// ─── KQL: shared snapshot base (embedded in both grid queries) ────────────────
//
// This is the sole data-access path into CostManagementSnapshot_CL. There is no
// ARMEndpoint / queryType 12 query, no Microsoft.CostManagement/query reference,
// and no CostDataJson anywhere in this module — that entire direct-Cost-API
// mechanism was removed by this refactor (see git history for the previous
// implementation).
//
// Latest-whole-run selection (critical): the collector's writes are append-only
// — repeated runs for the same BillingMonth create additional, complete
// snapshots rather than updating rows in place. This workbook must therefore
// select the single newest complete CollectionRunId per Project + BillingMonth
// and then use ALL rows belonging to that one run — it must never independently
// arg_max() each Environment/Service row on its own, because that could freely
// mix rows from two different collection runs for the same month. TimeGenerated
// (the collector's write timestamp) is used ONLY to rank collection runs by
// recency here; all business/grid filtering below uses BillingMonth, never
// TimeGenerated.
//
// hasData/IsValidMonth is tracked PER CALENDAR MONTH (via ValidMonths), not as
// one global flag for the whole six-month window — a month with no valid
// collector snapshot is "-" (unavailable) for that month only; the other five
// months in the same window are unaffected. A legitimate zero-cost snapshot
// still contains rows for its own BillingMonth (SubscriptionId/ServiceName rows
// are only absent for individual environments/services, not for the whole
// month), so "valid month" and "zero cost month" are correctly distinguished.

var baseSnapshotKql = 'let ConfiguredEnvironments = datatable(Environment:string) [${configuredEnvironmentsKqlBody}];\nlet LatestRuns =\n    CostManagementSnapshot_CL\n    | where Project == "{workloadName}"\n    | summarize RunTime = max(TimeGenerated) by Project, BillingMonth, CollectionRunId\n    | summarize arg_max(RunTime, CollectionRunId) by Project, BillingMonth;\nlet LatestSnapshotRows =\n    CostManagementSnapshot_CL\n    | where Project == "{workloadName}"\n    | join kind=inner (LatestRuns | project Project, BillingMonth, CollectionRunId) on Project, BillingMonth, CollectionRunId\n    | extend MonthKey = format_datetime(BillingMonth, "yyyy-MM");\nlet ValidMonths = LatestSnapshotRows | summarize by MonthKey;\nlet selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet isCurrentMonth = selectedMonth == startofmonth(now());\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (ValidMonths | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\nlet base = LatestSnapshotRows | project Cost = ActualCost, Environment, ServiceName, MonthKey;\n'

// ─── KQL: Environment pivot grid ──────────────────────────────────────────────
// Rows: configured environments (+ final "Total" row). Columns: 6 calendar
// months (YYYY-MM) + Total. Environment selector filters the already-retrieved
// LatestSnapshotRows dataset only — it never changes which BillingMonth/
// CollectionRunId rows are read.
//
// Zero vs. unavailable: a cell is "€ 0,00" only when its month IS in
// ValidMonths and has no matching cost row (a genuine zero); it is "-" when its
// month has NO valid snapshot at all. A row's Total (and the grand Total row's
// Total) is "-" whenever ANY of the six displayed months lacks a valid
// snapshot — summing the other five and silently treating the missing month as
// zero would misrepresent an incomplete total as a complete one.
//
// The environment selection is applied to selectedEnvList BEFORE the month
// grid, totals, and grand Total row are built — every downstream aggregate
// (including the Total row) is therefore computed only from the selected
// subset, never from a pre-computed all-environment grand total that gets
// filtered afterwards. When Environment = All, selectedEnvList is every
// configured environment, so behavior is unchanged from the All case.

var kqlEnvironmentGrid = '${baseSnapshotKql}${formatMoneyKql}let selectedEnvList = ConfiguredEnvironments | where "{Environment}" == "All" or Environment == "{Environment}";\nlet envMonthGrid = selectedEnvList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project Environment, MonthKey, IsValidMonth;\nlet envMonthActual =\n    envMonthGrid\n    | join kind=leftouter (base | summarize ActualCost = sum(Cost) by Environment, MonthKey) on Environment, MonthKey\n    | project Environment, MonthKey, IsValidMonth, RawCost = iff(IsValidMonth, coalesce(ActualCost, 0.0), real(null));\nlet totals =\n    envMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by Environment\n    | extend Total = iff(anyInvalidMonth, real(null), SumCost)\n    | project Environment, Total;\nlet envPivotSrc = envMonthActual | extend Display = iff(IsValidMonth, FormatMoney(RawCost), "-") | project Environment, MonthKey, Display;\nlet envPivot = envPivotSrc | evaluate pivot(MonthKey, take_any(Display), Environment);\nlet grandRowSrc =\n    envMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by MonthKey, IsValidMonth\n    | extend Display = iff(IsValidMonth, FormatMoney(SumCost), "-")\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = iff(anyInvalidMonth, real(null), toscalar(totals | summarize sum(Total)));\nlet grandRow = grandPivot | extend Environment = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal));\nlet envRows =\n    envPivot\n    | join kind=inner totals on Environment\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | project-away Total;\nunion envRows, grandRow\n| order by iff(Environment == "Total", 1, 0) asc, Environment asc'

// ─── KQL: Service pivot grid (with Trend) ─────────────────────────────────────
// Rows: ServiceName values observed in the (environment-filtered) latest-run
// dataset (+ final "Total" row). Columns: 6 calendar months (YYYY-MM) + Total +
// Trend. Trend formula, thresholds, and noise floor are unchanged from the
// direct-Cost-API implementation:
//   - ordinary least-squares linear regression over the required trend months
//     only (current partial month excluded when Report Month is the current
//     month; all six months included when Report Month is historical);
//   - an absolute €10/month noise floor is applied before the percentage bands;
//   - Downward <= -3%, Stable -3%..+3%, Mild Upward +3%..+10%, Strong Upward >= +10%.
// New in this refactor: if ANY month required for the trend calculation lacks a
// valid snapshot, the trend is NOT computed by treating that month as zero —
// it fails closed to "Unavailable", which (like any string other than the three
// explicitly coloured values) renders with the grid formatter's neutral
// Default (no colour) case below, never a misleading colour. A missing
// current-month snapshot never triggers this, because the current month is
// already excluded from the required trend months whenever it is selected.

var kqlServiceGrid = '${baseSnapshotKql}${formatMoneyKql}let filtered = base | where "{Environment}" == "All" or Environment == "{Environment}";\nlet serviceList = filtered | summarize by ServiceName;\nlet serviceMonthGrid = serviceList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project ServiceName, MonthKey, IsValidMonth;\nlet serviceMonthActual =\n    serviceMonthGrid\n    | join kind=leftouter (filtered | summarize ActualCost = sum(Cost) by ServiceName, MonthKey) on ServiceName, MonthKey\n    | project ServiceName, MonthKey, IsValidMonth, RawCost = iff(IsValidMonth, coalesce(ActualCost, 0.0), real(null));\nlet requiredTrendMonths = monthList | where MonthOffset <= iff(isCurrentMonth, -1, 0);\nlet trendMonthsValid = toscalar(requiredTrendMonths | summarize countif(not(IsValidMonth))) == 0;\nlet trendMonthList = requiredTrendMonths | order by MonthOffset asc | serialize | extend x = row_number() - 1;\nlet trendBase =\n    serviceMonthActual\n    | join kind=inner trendMonthList on MonthKey\n    | where trendMonthsValid\n    | summarize N = count(), SumX = sum(x*1.0), SumY = sum(coalesce(RawCost,0.0)), SumXY = sum(x*1.0*coalesce(RawCost,0.0)), SumX2 = sum(x*1.0*x) by ServiceName\n    | extend Denom = N*SumX2 - SumX*SumX\n    | extend Slope = iff(Denom == 0, 0.0, (N*SumXY - SumX*SumY) / Denom)\n    | extend MeanCost = iff(N == 0, 0.0, SumY / N)\n    | extend NormalizedPct = iff(MeanCost == 0, 0.0, (Slope / MeanCost) * 100)\n    | extend Trend = case(\n        abs(Slope) < 10, "Stable",\n        NormalizedPct <= -3, "Downward",\n        NormalizedPct <= 3, "Stable",\n        NormalizedPct < 10, "Mild Upward",\n        "Strong Upward"\n      )\n    | project ServiceName, Trend;\nlet totals =\n    serviceMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by ServiceName\n    | extend Total = iff(anyInvalidMonth, real(null), SumCost)\n    | project ServiceName, Total;\nlet servicePivotSrc = serviceMonthActual | extend Display = iff(IsValidMonth, FormatMoney(RawCost), "-") | project ServiceName, MonthKey, Display;\nlet servicePivot = servicePivotSrc | evaluate pivot(MonthKey, take_any(Display), ServiceName);\nlet grandRowSrc =\n    serviceMonthActual\n    | summarize SumCost = sum(coalesce(RawCost, 0.0)) by MonthKey, IsValidMonth\n    | extend Display = iff(IsValidMonth, FormatMoney(SumCost), "-")\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = iff(anyInvalidMonth, real(null), toscalar(totals | summarize sum(Total)));\nlet grandRow = grandPivot | extend ServiceName = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal)), Trend = "";\nlet serviceRows =\n    servicePivot\n    | join kind=leftouter totals on ServiceName\n    | join kind=leftouter trendBase on ServiceName\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | extend Trend = coalesce(Trend, iff(trendMonthsValid, "Stable", "Unavailable"))\n    | project-away Total;\nunion serviceRows, grandRow\n| order by iff(ServiceName == "Total", 1, 0) asc, ServiceName asc'

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

          // Report Month: current month + previous 12 completed calendar months.
          // Calendar-month arithmetic (datetime_add) — never 30d/60d approximation.
          // Unchanged by this LAW migration: this query is synthetic (range/print
          // only) and never touches CostManagementSnapshot_CL, so it needs no
          // explicit timeContext.
          //
          // Default selection uses the query's own `selected` column (true only
          // for MonthOffset == 0, the current month) — the documented Azure
          // Workbook dropdown contract for a query-backed parameter's default
          // value — rather than a static `value: 'value::0'` override, which
          // depends on row order instead of an explicit selection flag.
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

          // Environment: filters the already-retrieved latest-run snapshot data
          // only, never re-selects which CollectionRunId/BillingMonth rows are
          // read. Choices are derived from subscriptionEnvironmentMappings, not
          // hard-coded, so this module stays reusable for a different
          // project/environment set.
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
        json: '# Cost Management Dashboard — {workloadName}\n\n| | |\n|---|---|\n| **Report month** | {ReportMonth} |\n| **Data source** | `CostManagementSnapshot_CL` (Log Analytics) — the newest complete collector snapshot for each month, not a live Cost Management API call |\n| **Window** | Report Month and the five preceding calendar months (six columns) |\n| **Trend basis** | Ordinary least-squares linear regression over completed months only — the current month-to-date is always excluded from trend |\n| **Trend bands** | ≤ -3% Downward · -3%..+3% Stable · +3%..+10% Mild Upward · ≥ +10% Strong Upward — absolute changes under €10/month are always Stable regardless of percentage |\n| **Zero vs. unavailable** | € 0,00 = a valid collected snapshot exists for that month with no cost for this row. "-" = no valid collector snapshot exists for that month yet |\n| **Trend unavailable** | Shown (no colour) instead of a coloured trend whenever any month required for the trend calculation has no valid snapshot |\n\nCost data is collected by a separate, manually-run process (see docs/operations.md) that writes normalized monthly snapshots into the existing central Log Analytics workspace. This workbook only reads the newest complete snapshot per month for **{workloadName}** — it never calls the Azure Cost Management API directly.'
      }
      name: 'text-title'
    }

    // ── Environment pivot grid ───────────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlEnvironmentGrid
        size: 0
        title: 'Cost per Environment'
        noDataMessage: 'No cost data returned for the selected Report Month.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          labelSettings: [
            { columnId: 'Environment',   label: 'Environment' }
            { columnId: 'TotalDisplay',  label: 'Total' }
          ]
        }
      }
      name: 'query-environment-grid'
    }

    // ── Service pivot grid (with Trend) ──────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlServiceGrid
        size: 0
        title: 'Cost per Service'
        noDataMessage: 'No cost data returned for the selected Report Month and Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          formatters: [
            {
              columnMatch: 'Trend'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: 'Downward',      representation: 'green',     text: '{0}{1}' }
                  { operator: '==', thresholdValue: 'Mild Upward',   representation: 'orange',    text: '{0}{1}' }
                  { operator: '==', thresholdValue: 'Strong Upward', representation: 'redBright', text: '{0}{1}' }
                  { operator: 'Default',                             representation: '',          text: '{0}{1}' }
                ]
              }
            }
          ]
          labelSettings: [
            { columnId: 'ServiceName',   label: 'Service' }
            { columnId: 'TotalDisplay',  label: 'Total' }
            { columnId: 'Trend',         label: 'Trend' }
          ]
        }
      }
      name: 'query-service-grid'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────
// Deterministic name derived from stable configuration inputs only — never from
// workbookDisplayName, so renaming the customer-facing title never changes the
// underlying resource identity. Unchanged by this LAW migration (still includes
// managementGroupId, purely for resource-identity stability — see that
// parameter's description above): this refactor must not orphan or duplicate
// the existing deployed workbook resource.

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

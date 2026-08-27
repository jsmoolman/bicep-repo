metadata description = 'Azure Monitor Workbook — Cost Management single-query pivot. One management-group-scoped Azure Cost Management (Actual Cost) query per selected Report Month drives an Environment pivot grid and a Service pivot grid, six calendar months wide. Environment selection filters already-retrieved data only — it never triggers a second Cost Management API call. Pivoting and trend classification (ordinary least-squares linear regression, €10/month noise floor) run as Log Analytics KQL against the supplied Log Analytics workspace, which is used purely as a stateless compute engine: no cost data is ingested, stored, or persisted there.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Used for parameter labelling and the deterministic workbook name seed.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Management group ID used as the scope for the Azure Cost Management query. The query still explicitly filters to only the configured subscriptionEnvironmentMappings — subscriptions are never dynamically enumerated from this management group.')
param managementGroupId string

@description('''Full ARM resource ID of an existing Log Analytics workspace, reused purely as a stateless KQL compute engine to pivot and trend the single Cost Management result. No Cost Management data is ingested into, stored in, or queried from this workspace — it never backs a Log Analytics table read as part of the cost calculation. Workbook viewers require read/query access to this workspace in addition to Cost Management access at the management-group scope; neither access is granted by this module.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. environment must be one of: mgt, dev, tst, acc, preprd, prd. These subscription IDs are also the explicit inclusion filter sent to the Cost Management query — subscriptions are never dynamically enumerated from the management group.''')
param subscriptionEnvironmentMappings array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Pinned API version ────────────────────────────────────────────────────
// Cost Management Query API — current stable version per Microsoft Learn
// (learn.microsoft.com/rest/api/cost-management/query) as of this implementation.
// Pinned here (not parameterised) so callers cannot silently drift to an
// unverified version.

var costManagementApiVersion = '2026-06-01'

// ─── Derived names ────────────────────────────────────────────────────────────

var subscriptionIds = [for m in subscriptionEnvironmentMappings: m.subscriptionId]

// ─── KQL: shared environment mapping datatable (embedded in both grid queries) ─

var envMapBody = join(
  map(subscriptionEnvironmentMappings, m => '"${toLower(m.subscriptionId)}", "${m.environment}"'),
  ', '
)
var envMapKql = 'let EnvironmentMap = datatable(SubscriptionId:string, Environment:string)[${envMapBody}];\n'

// ─── KQL: shared money-formatting helper (embedded in both grid queries) ──────
// Euro, two decimals, "." thousands separator, "," decimal separator — e.g. € 3.701,30.
// Renders "-" upstream (not inside this helper) whenever the underlying value is unavailable.

var formatMoneyKql = 'let FormatMoney = (v:double) {\n    let isNeg = v < 0;\n    let av = abs(v);\n    let cents = tostring(round((av - floor(av)) * 100, 0));\n    let cents2 = case(strlen(cents) == 0, "00", strlen(cents) == 1, strcat("0", cents), cents);\n    let intPart = tostring(toint(floor(av)));\n    let len = strlen(intPart);\n    let r = len % 3;\n    let head = iff(r == 0, "", substring(intPart, 0, r));\n    let remainder = substring(intPart, r);\n    let remLen = strlen(remainder);\n    let groups = remLen / 3;\n    let seg1 = iff(groups >= 1, substring(remainder, 0, 3), "");\n    let seg2 = iff(groups >= 2, substring(remainder, 3, 3), "");\n    let seg3 = iff(groups >= 3, substring(remainder, 6, 3), "");\n    let segCount = iff(r == 0, groups, groups + 1);\n    let grouped = case(\n        segCount <= 1, iff(r == 0, seg1, head),\n        segCount == 2, iff(r == 0, strcat(seg1, ".", seg2), strcat(head, ".", seg1)),\n        segCount == 3, iff(r == 0, strcat(seg1, ".", seg2, ".", seg3), strcat(head, ".", seg1, ".", seg2)),\n        strcat(head, ".", seg1, ".", seg2, ".", seg3)\n    );\n    strcat(iff(isNeg, "-", ""), "€ ", grouped, ",", cents2)\n};\n'

// ─── KQL: parse the single Cost Management result (embedded in both grid queries) ─
// CostDataJson is injected using the workbook parameter's documented "escapejson"
// formatter ({CostDataJson:escapejson}), not hand-written escaping — this is the
// safe, Microsoft-documented mechanism for embedding an arbitrary JSON-valued text
// parameter inside a KQL string literal (learn.microsoft.com/azure/azure-monitor/
// visualize/workbooks-parameters#parameter-formatting-options).
//
// Column indexes are resolved BY NAME from the response's own "properties.columns"
// metadata, not assumed from a fixed position. This is deliberate: a customer-side
// read-only commissioning probe proved the live column order is
// Cost, BillingMonth, SubscriptionId, ServiceName, Currency (BillingMonth at index 1,
// not a fixed "last column" as originally assumed) — but the parser must remain
// correct even if Azure returns the same named columns in a different order.
//
// hasData is false (fail closed — never a plausible-looking but wrong total) when:
//   - the ARM call genuinely failed to return a usable response shape (no
//     "columns" metadata) — a real Cost Management error, not a legitimate
//     zero-cost result; or
//   - any of the five required columns (Cost, BillingMonth, SubscriptionId,
//     ServiceName, Currency) is absent from "properties.columns" — the schema is
//     not as expected, so column positions cannot be trusted; or
//   - the response is paged (properties.nextLink present). This workbook
//     intentionally issues exactly one Cost Management request per Report Month
//     and never follows nextLink — pagination loops, additional queries, and
//     caching/state are all explicitly out of scope. A paged response therefore
//     fails closed: it is treated the same as "no usable data" so first-page
//     figures are never presented as complete totals.
// A legitimate empty "rows" array with all required "columns" present and no
// nextLink is a valid zero-cost answer and is zero-filled as € 0,00, not "-".
// BillingMonth is the authoritative calendar-month field for each row (proven live
// format "yyyy-MM-ddTHH:mm:ss", e.g. "2026-07-01T00:00:00") — it is parsed as a
// real datetime, never derived from array position or synthetic row numbering.

var parseCostDataKql = 'let raw = parse_json("{CostDataJson:escapejson}");\nlet hasColumns = isnotnull(raw.properties) and isnotnull(raw.properties.columns);\nlet colIndexTable =\n    print ColsArr = iff(hasColumns, raw.properties.columns, dynamic([]))\n    | mv-expand with_itemindex=ColIdx Col = ColsArr\n    | project ColName = tostring(Col.name), ColIdx = toint(ColIdx);\nlet requiredCols = dynamic(["Cost","BillingMonth","SubscriptionId","ServiceName","Currency"]);\nlet foundCols = toscalar(colIndexTable | summarize make_set(ColName));\nlet missingCols = set_difference(requiredCols, foundCols);\nlet hasAllRequiredCols = array_length(missingCols) == 0;\nlet nextLinkVal = tostring(raw.properties.nextLink);\nlet isPaged = isnotempty(nextLinkVal);\nlet hasData = hasColumns and hasAllRequiredCols and not(isPaged);\nlet idxCost           = coalesce(toscalar(colIndexTable | where ColName == "Cost" | project ColIdx), -1);\nlet idxBillingMonth   = coalesce(toscalar(colIndexTable | where ColName == "BillingMonth" | project ColIdx), -1);\nlet idxSubscriptionId = coalesce(toscalar(colIndexTable | where ColName == "SubscriptionId" | project ColIdx), -1);\nlet idxServiceName    = coalesce(toscalar(colIndexTable | where ColName == "ServiceName" | project ColIdx), -1);\nlet idxCurrency       = coalesce(toscalar(colIndexTable | where ColName == "Currency" | project ColIdx), -1);\nlet costRowsRaw = iff(hasData, raw.properties.rows, dynamic(null));\nlet costRows = iff(isnull(costRowsRaw), dynamic([]), costRowsRaw);\nlet base =\n    print RawRows = costRows\n    | mv-expand Row = RawRows\n    | project\n        Cost = todouble(Row[idxCost]),\n        SubId = tolower(tostring(Row[idxSubscriptionId])),\n        ServiceName = tostring(Row[idxServiceName]),\n        Currency = tostring(Row[idxCurrency]),\n        BillingMonthStr = tostring(Row[idxBillingMonth])\n    | extend MonthKey = format_datetime(todatetime(BillingMonthStr), "yyyy-MM")\n    | join kind=leftouter (EnvironmentMap | project SubId=SubscriptionId, Environment) on SubId\n    | where isnotempty(Environment);\nlet selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet isCurrentMonth = selectedMonth == startofmonth(now());\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM");\n'

// ─── KQL: data warning (hidden, visible-text signal only, no extra query) ─────
// Reuses the already-fetched CostDataJson and the same column-resolution/pagination
// logic as parseCostDataKql — does not add a second Cost Management request. Yields
// an empty string when the response is complete, correctly-shaped, and unpaged.

var kqlDataWarning = '${envMapKql}${parseCostDataKql}print Warning = case(\n    not(hasColumns), "Warning: The Cost Management response did not include the expected result metadata (properties.columns). Cost data is unavailable for this Report Month.",\n    not(hasAllRequiredCols), strcat("Warning: The Cost Management response is missing required column(s): ", strcat_array(missingCols, ", "), ". Cost data is unavailable for this Report Month."),\n    isPaged, "Warning: Cost Management returned a paged response for this Report Month (nextLink present). This workbook intentionally issues only one Cost Management request and does not follow pagination links, so the figures below are incomplete and shown as unavailable until this is resolved.",\n    ""\n  )'

// ─── KQL: Environment pivot grid ──────────────────────────────────────────────
// Rows: environments (+ final "Total" row). Columns: 6 calendar months (YYYY-MM) + Total.
// Environment selector filters this already-retrieved dataset only — no new
// Cost Management call is issued when it changes.
//
// The environment selection is applied to selectedEnvList BEFORE the month grid,
// totals, and grand Total row are built — every downstream aggregate (including
// the Total row) is therefore computed only from the selected subset, never from
// a pre-computed all-environment grand total that gets filtered afterwards. When
// Environment = All, selectedEnvList is every configured environment, so behavior
// is unchanged from the All case.

var kqlEnvironmentGrid = '${envMapKql}${formatMoneyKql}${parseCostDataKql}let selectedEnvList = (EnvironmentMap | summarize by Environment) | where "{Environment}" == "All" or Environment == "{Environment}";\nlet envMonthGrid = selectedEnvList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project Environment, MonthKey;\nlet envMonthActual =\n    envMonthGrid\n    | join kind=leftouter (base | summarize ActualCost=sum(Cost) by Environment, MonthKey) on Environment, MonthKey\n    | project Environment, MonthKey, RawCost = iff(hasData, coalesce(ActualCost, 0.0), real(null));\nlet totals = envMonthActual | summarize Total = iff(hasData, sum(coalesce(RawCost,0.0)), real(null)) by Environment;\nlet envPivotSrc = envMonthActual | extend Display = iff(isnull(RawCost), "-", FormatMoney(RawCost)) | project Environment, MonthKey, Display;\nlet envPivot = envPivotSrc | evaluate pivot(MonthKey, take_any(Display), Environment);\nlet grandRowSrc =\n    envMonthActual\n    | summarize RawCost = iff(hasData, sum(coalesce(RawCost,0.0)), real(null)) by MonthKey\n    | extend Display = iff(isnull(RawCost), "-", FormatMoney(RawCost))\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = toscalar(totals | summarize s = iff(hasData, sum(coalesce(Total,0.0)), real(null)));\nlet grandRow = grandPivot | extend Environment = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal));\nlet envRows =\n    envPivot\n    | join kind=inner totals on Environment\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | project-away Total;\nunion envRows, grandRow\n| order by iff(Environment == "Total", 1, 0) asc, Environment asc'

// ─── KQL: Service pivot grid (with Trend) ─────────────────────────────────────
// Rows: Cost Management ServiceName values observed in the (environment-filtered)
// dataset (+ final "Total" row). Columns: 6 calendar months (YYYY-MM) + Total + Trend.
// Trend: ordinary least-squares linear regression over completed months only
// (current partial month excluded), €10/month absolute noise floor applied first.

var kqlServiceGrid = '${envMapKql}${formatMoneyKql}${parseCostDataKql}let filtered = base | where "{Environment}" == "All" or Environment == "{Environment}";\nlet serviceList = filtered | summarize by ServiceName;\nlet serviceMonthGrid = serviceList | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project ServiceName, MonthKey;\nlet serviceMonthActual =\n    serviceMonthGrid\n    | join kind=leftouter (filtered | summarize ActualCost=sum(Cost) by ServiceName, MonthKey) on ServiceName, MonthKey\n    | project ServiceName, MonthKey, RawCost = iff(hasData, coalesce(ActualCost, 0.0), real(null));\nlet trendMonthList = monthList | where MonthOffset <= iff(isCurrentMonth, -1, 0) | order by MonthOffset asc | serialize | extend x = row_number() - 1;\nlet trendBase =\n    serviceMonthActual\n    | join kind=inner trendMonthList on MonthKey\n    | where hasData\n    | summarize N = count(), SumX = sum(x*1.0), SumY = sum(coalesce(RawCost,0.0)), SumXY = sum(x*1.0*coalesce(RawCost,0.0)), SumX2 = sum(x*1.0*x) by ServiceName\n    | extend Denom = N*SumX2 - SumX*SumX\n    | extend Slope = iff(Denom == 0, 0.0, (N*SumXY - SumX*SumY) / Denom)\n    | extend MeanCost = iff(N == 0, 0.0, SumY / N)\n    | extend NormalizedPct = iff(MeanCost == 0, 0.0, (Slope / MeanCost) * 100)\n    | extend Trend = case(\n        abs(Slope) < 10, "Stable",\n        NormalizedPct <= -3, "Downward",\n        NormalizedPct <= 3, "Stable",\n        NormalizedPct < 10, "Mild Upward",\n        "Strong Upward"\n      )\n    | project ServiceName, Trend;\nlet totals = serviceMonthActual | summarize Total = iff(hasData, sum(coalesce(RawCost,0.0)), real(null)) by ServiceName;\nlet servicePivotSrc = serviceMonthActual | extend Display = iff(isnull(RawCost), "-", FormatMoney(RawCost)) | project ServiceName, MonthKey, Display;\nlet servicePivot = servicePivotSrc | evaluate pivot(MonthKey, take_any(Display), ServiceName);\nlet grandRowSrc =\n    serviceMonthActual\n    | summarize RawCost = iff(hasData, sum(coalesce(RawCost,0.0)), real(null)) by MonthKey\n    | extend Display = iff(isnull(RawCost), "-", FormatMoney(RawCost))\n    | project MonthKey, Display;\nlet grandPivot = grandRowSrc | evaluate pivot(MonthKey, take_any(Display));\nlet grandTotalVal = toscalar(totals | summarize s = iff(hasData, sum(coalesce(Total,0.0)), real(null)));\nlet grandRow = grandPivot | extend ServiceName = "Total", TotalDisplay = iff(isnull(grandTotalVal), "-", FormatMoney(grandTotalVal)), Trend = "";\nlet serviceRows =\n    servicePivot\n    | join kind=leftouter totals on ServiceName\n    | join kind=leftouter trendBase on ServiceName\n    | extend TotalDisplay = iff(isnull(Total), "-", FormatMoney(Total))\n    | extend Trend = coalesce(Trend, "Stable")\n    | project-away Total;\nunion serviceRows, grandRow\n| order by iff(ServiceName == "Total", 1, 0) asc, ServiceName asc'

// ─── KQL: derived date-window parameters (drive the single Cost Management call) ─
// Only {ReportMonth} feeds these — {Environment} never appears here, so changing
// Environment cannot change the Cost Management request.

var kqlCostFromDate = 'print FromDate = strcat(format_datetime(datetime_add("month", -5, startofmonth(todatetime(strcat("{ReportMonth}", "-01")))), "yyyy-MM-ddTHH:mm:ss"), "Z")'

var kqlCostToDate = 'let selMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet curMonth = startofmonth(now());\nprint ToDate = strcat(format_datetime(iff(selMonth == curMonth, now(), endofmonth(selMonth)), "yyyy-MM-ddTHH:mm:ss"), "Z")'

// ─── ARM: the single Cost Management query definition ─────────────────────────
// Management-group scope. Explicit inclusion filter to only the configured
// subscription IDs — subscriptions are never dynamically enumerated from the
// management group. Two grouping dimensions (SubscriptionId, ServiceName) plus
// Monthly granularity is the maximum allowed (2) GroupBy clauses.

var costManagementRequestBody = {
  type: 'ActualCost'
  timeframe: 'Custom'
  timePeriod: {
    from: '{CostFromDate}'
    to: '{CostToDate}'
  }
  dataset: {
    granularity: 'Monthly'
    aggregation: {
      totalCost: {
        name: 'Cost'
        function: 'Sum'
      }
    }
    grouping: [
      {
        type: 'Dimension'
        name: 'SubscriptionId'
      }
      {
        type: 'Dimension'
        name: 'ServiceName'
      }
    ]
    filter: {
      dimensions: {
        name: 'SubscriptionId'
        operator: 'In'
        values: subscriptionIds
      }
    }
  }
}

var armCostQuery = {
  version: 'ARMEndpoint/1.0'
  data: null
  headers: []
  method: 'POST'
  path: '/providers/Microsoft.Management/managementGroups/${managementGroupId}/providers/Microsoft.CostManagement/query'
  body: string(costManagementRequestBody)
  urlParams: [
    {
      key: 'api-version'
      value: costManagementApiVersion
    }
  ]
  batchDisabled: false
}

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
          {
            id: guid(workloadName, 'p-reportMonth-cost')
            version: 'KqlParameterItem/1.0'
            name: 'ReportMonth'
            label: 'Report Month'
            type: 2
            isRequired: true
            query: 'range MonthOffset from 0 to 12 step 1\n| extend MonthStart = datetime_add("month", -MonthOffset, startofmonth(now()))\n| order by MonthStart desc\n| project value=format_datetime(MonthStart, "yyyy-MM"), label=strcat(format_datetime(MonthStart, "yyyy-MM"), iff(MonthOffset == 0, " (current, month-to-date)", ""))'
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            value: 'value::0'
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

          // Environment: filters already-retrieved data only, never re-queries Cost Management.
          {
            id: guid(workloadName, 'p-environment-cost')
            version: 'KqlParameterItem/1.0'
            name: 'Environment'
            label: 'Environment'
            type: 2
            isRequired: false
            jsonData: '["All","mgt","dev","tst","acc","preprd","prd"]'
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

    // ── Hidden internal computation bar (always hidden; still executes) ─────
    // Permanently-false conditionalVisibility: workloadName is never "__hidden__".
    // A single ARM Cost Management call executes here per selected Report Month;
    // Environment is not referenced by any parameter in this step.
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [

          {
            id: guid(workloadName, 'p-costFromDate')
            version: 'KqlParameterItem/1.0'
            name: 'CostFromDate'
            type: 1
            isRequired: true
            query: kqlCostFromDate
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
          }

          {
            id: guid(workloadName, 'p-costToDate')
            version: 'KqlParameterItem/1.0'
            name: 'CostToDate'
            type: 1
            isRequired: true
            query: kqlCostToDate
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
          }

          {
            id: guid(workloadName, 'p-costDataJson')
            version: 'KqlParameterItem/1.0'
            name: 'CostDataJson'
            type: 1
            isRequired: true
            query: string(armCostQuery)
            queryType: 12
          }

          // Computed after CostDataJson (parameters in this list execute in order and
          // may reference earlier ones). Empty string when the response is complete,
          // correctly-shaped, and unpaged; wired into the visible title text below so
          // an unexpected schema or a paged response produces a clear, visible
          // warning without a second Cost Management request.
          {
            id: guid(workloadName, 'p-dataWarning')
            version: 'KqlParameterItem/1.0'
            name: 'DataWarning'
            type: 1
            isRequired: false
            query: kqlDataWarning
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
          }

        ]
      }
      name: 'parameters-hidden-cost-source'
      conditionalVisibility: {
        parameterName: 'workloadName'
        comparison: 'isEqualTo'
        value: '__hidden__'
      }
    }

    // ── Title / methodology text ─────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '# Cost Management Dashboard — {workloadName}\n\n{DataWarning}\n\n| | |\n|---|---|\n| **Report month** | {ReportMonth} |\n| **Cost type** | Actual Cost (management-group scope) |\n| **Query scope** | One Cost Management query per Report Month — Environment selection filters the already-retrieved result only |\n| **Window** | Report Month and the five preceding calendar months (six columns) |\n| **Trend basis** | Ordinary least-squares linear regression over completed months only — the current month-to-date is always excluded from trend |\n| **Trend bands** | ≤ -3% Downward · -3%..+3% Stable · +3%..+10% Mild Upward · ≥ +10% Strong Upward — absolute changes under €10/month are always Stable regardless of percentage |\n| **Zero vs. unavailable** | € 0,00 = confirmed zero cost. "-" = cost data could not be determined |\n\nThis workbook currently queries costs at the **Tenant Root Group** as a query-scope decision only — the Cost Management query explicitly filters to the subscriptions configured for this project. RBAC for the costing security group is reviewed and applied separately; it is not part of this deployment.'
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
// underlying resource identity.

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

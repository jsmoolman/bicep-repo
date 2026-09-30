metadata description = 'Azure Monitor Workbook — Change Tracking & Inventory (CTI) Dashboard, reading exclusively from the existing ConfigurationChange and ConfigurationData Log Analytics tables populated by the CTI foundation (see modules/observability/change-tracking-inventory-foundation/main.bicep). Read-only reporting: creates or modifies no DCR, policy assignment, identity, VM extension, DCR association, or LAW configuration, and makes no ARM/Resource Graph API call.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Used for parameter labelling, the deterministic workbook name, and — via the workbook\'s own {workloadName} text substitution — as the Computer-name prefix in every KQL query (^{workloadName}-([^-]+)-). Must match the actual Computer naming prefix CTI reports for this workload.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Full ARM resource ID of the existing Log Analytics workspace that already receives CTI ConfigurationChange/ConfigurationData telemetry. This module creates no workspace, DCR, policy assignment, identity, VM extension, or DCR association.')
param workspaceResourceId string

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Explicit LAW query time contexts ─────────────────────────────────────────
// Two distinct contexts, so the Azure portal time-range control can never
// silently truncate either query family below its own KQL-enforced boundary.
//
// Historical (change-event) queries are bounded by explicit Report Month
// text substitution inside the KQL itself (MonthStart/MonthEnd) — this
// context only needs to be wide enough to cover every selectable Report
// Month (current month + previous 12 completed months, i.e. up to ~397
// days back in the worst case). 400 days gives a small, explicit margin
// without being unlimited.
var historicalQueryTimeContext = {
  durationMs: 34560000000 // 400 days
}

// Current-state (inventory/coverage/differences) queries are bounded by an
// explicit ago(30d) lookback inside the KQL itself — this context matches
// that same 30-day window so the portal time picker cannot cut it shorter.
var currentStateQueryTimeContext = {
  durationMs: 2592000000 // 30 days
}

// ─── KQL: shared fragments ────────────────────────────────────────────────────
// Every fragment below is a constant string: {workloadName}, {ReportMonth},
// and {Environment} are Azure Workbook *text-substitution* tokens (resolved
// by the workbook engine from the visible parameters at render time), not
// Bicep interpolation — so none of these fragments need a Bicep parameter
// reference.

// Environment multi-select substitution: the Environment parameter below is
// multiSelect with quote:"'"/delimiter:",", so {Environment} always expands
// to a quoted, comma-separated list (e.g. 'acc','preprd'). The synthetic "*"
// choice (label "All") is offered and selected by default; when present in
// the expanded list, every row matches regardless of its own Environment.
var environmentFilterKql = '| where \'*\' in ({Environment}) or Environment in ({Environment})\n'

// Computer -> Environment / Role derivation, validated against real CTI
// telemetry (see module description). Never a hard-coded environment list.
// The isnotempty(Environment) filter is load-bearing: it removes any row
// whose Computer does not match this workbook's {workloadName} prefix
// *before* the Environment-selection condition below is ever evaluated —
// otherwise such a row's blank Environment would incorrectly pass the "*"
// (All) branch of environmentFilterKql and leak unrelated-workload data
// into every query that reuses this fragment.
var envExtractKql = '| extend Environment = extract(@"^{workloadName}-([^-]+)-", 1, Computer)\n| where isnotempty(Environment)\n'
var roleCaseKql = '| extend Role = case(\n    Computer endswith "-001", "Application",\n    Computer endswith "-002", "SQL",\n    "Other")\n'

// Practical current-state lookback (Software Inventory, Service Inventory,
// Coverage, Configuration Differences). These sections intentionally ignore
// Report Month — see module description and docs/operations.md.
var currentStateLookbackKql = '| where TimeGenerated > ago(30d)\n'

// Explicit selected-month boundary for every historical (change-event) query
// — never the Azure Logs/workbook time picker.
var monthBoundaryKql = 'let MonthStart = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet MonthEnd = datetime_add("month", 1, MonthStart);\n'

// Genuine-change-event filter: some ConfigurationChange rows carry blank
// ConfigChangeType/ChangeCategory and must never be counted as a change.
var genuineChangeFilterKql = '| where isnotempty(ConfigChangeType)\n| where isnotempty(ChangeCategory)\n'

// ─── KQL: global parameter queries ────────────────────────────────────────────

// Report Month: current month + previous 12 completed calendar months,
// same style already used by the Cost Management and Backup & Restore
// workbooks. Default selection = current month via the query's own
// `selected` column.
var kqlReportMonthParameterQuery = 'range MonthOffset from 0 to 12 step 1\n| extend MonthStart = datetime_add("month", -MonthOffset, startofmonth(now()))\n| order by MonthStart desc\n| project value=format_datetime(MonthStart, "yyyy-MM"), label=strcat(format_datetime(MonthStart, "yyyy-MM"), iff(MonthOffset == 0, " (current, month-to-date)", "")), selected=(MonthOffset == 0)'

// Environment: populated dynamically from CTI data (never a hard-coded
// list), plus a synthetic "*"/"All" choice, selected by default. Query-
// backed multi-select dropdown contract: value, label, selected columns.
// Uses only an inline union of a literal print() row and a single non-
// tabular-let projection — not the named-tabular-let/union pattern that
// failed live validation for the peer-comparison queries below.
var kqlEnvironmentParameterQuery = 'union\n    (print value = "*", label = "All", selected = true),\n    (\n        ConfigurationData\n        | extend Environment = extract(@"^{workloadName}-([^-]+)-", 1, Computer)\n        | where isnotempty(Environment)\n        | summarize by Environment\n        | project value = Environment, label = Environment, selected = false\n    )\n| order by selected desc, value asc'

// ─── KQL: Overview headline tiles ─────────────────────────────────────────────
// Reporting VMs is coverage/freshness (ConfigurationData), never policy
// compliance. The other four are genuine-change-event counts for the
// selected Report Month (ConfigurationChange). Each metric is resolved to a
// scalar independently (toscalar on its own full inline chain) before the
// final union of print() rows — no named tabular let is combined via union.
var kqlOverviewTiles = '${monthBoundaryKql}let ReportingVMs = toscalar(\n    ConfigurationData\n    ${currentStateLookbackKql}${envExtractKql}${environmentFilterKql}| summarize by Computer\n    | count\n);\nlet ChangeEvents = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}${envExtractKql}${environmentFilterKql}| count\n);\nlet AffectedVMs = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}${envExtractKql}${environmentFilterKql}| summarize by Computer\n    | count\n);\nlet SoftwareEvents = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}| where ConfigChangeType == "Software"\n    ${envExtractKql}${environmentFilterKql}| count\n);\nlet ServiceEvents = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}| where ConfigChangeType == "WindowsServices"\n    ${envExtractKql}${environmentFilterKql}| count\n);\nprint Metric = "Reporting VMs", Value = ReportingVMs\n| union (print Metric = "Change Events", Value = ChangeEvents)\n| union (print Metric = "Affected VMs", Value = AffectedVMs)\n| union (print Metric = "Software Events", Value = SoftwareEvents)\n| union (print Metric = "Service Events", Value = ServiceEvents)'

// ─── KQL: Coverage/freshness grid ─────────────────────────────────────────────
// Independent latest-Software and latest-WindowsServices timestamps per VM
// (never one combined "latest ConfigurationData" snapshot). Age columns are
// plain durations; a 24h staleness convention is explained in the adjoining
// markdown text rather than as a compliance-style label or color.
var kqlCoverageGrid = 'ConfigurationData\n${currentStateLookbackKql}| summarize\n    SoftwareLastSeen = maxif(TimeGenerated, ConfigDataType == "Software"),\n    ServicesLastSeen = maxif(TimeGenerated, ConfigDataType == "WindowsServices"),\n    ResourceId = take_any(_ResourceId)\n    by Computer\n${envExtractKql}${roleCaseKql}| extend\n    SoftwareAge = now() - SoftwareLastSeen,\n    ServicesAge = now() - ServicesLastSeen\n${environmentFilterKql}| project\n    Environment,\n    Role,\n    Computer,\n    SoftwareLastSeen,\n    SoftwareAge,\n    ServicesLastSeen,\n    ServicesAge,\n    ResourceId\n| order by Environment asc, Role asc, Computer asc'

// ─── KQL: Daily change activity trend (shared — Overview & Change Activity) ───
// Reused unchanged by both sections (never a second, divergently-written
// copy). Validated series: Software/Added, Software/Removed,
// WindowsServices/Modified — derived, never a fixed taxonomy.
var kqlDailyTrend = '${monthBoundaryKql}ConfigurationChange\n| where TimeGenerated >= MonthStart\n| where TimeGenerated < MonthEnd\n${genuineChangeFilterKql}${envExtractKql}${environmentFilterKql}| extend EventType = strcat(ConfigChangeType, " / ", ChangeCategory)\n| summarize Events = count()\n    by Day = startofday(TimeGenerated), EventType\n| order by Day asc, EventType asc'

// ─── KQL: Change Activity summary tiles ───────────────────────────────────────
var kqlChangeActivityTiles = '${monthBoundaryKql}let ChangeEvents = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}${envExtractKql}${environmentFilterKql}| count\n);\nlet AffectedVMs = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}${envExtractKql}${environmentFilterKql}| summarize by Computer\n    | count\n);\nlet SoftwareAdded = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}| where ConfigChangeType == "Software" and ChangeCategory == "Added"\n    ${envExtractKql}${environmentFilterKql}| count\n);\nlet SoftwareRemoved = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}| where ConfigChangeType == "Software" and ChangeCategory == "Removed"\n    ${envExtractKql}${environmentFilterKql}| count\n);\nlet ServiceChanges = toscalar(\n    ConfigurationChange\n    | where TimeGenerated >= MonthStart\n    | where TimeGenerated < MonthEnd\n    ${genuineChangeFilterKql}| where ConfigChangeType == "WindowsServices"\n    ${envExtractKql}${environmentFilterKql}| count\n);\nprint Metric = "Change Events", Value = ChangeEvents\n| union (print Metric = "Affected VMs", Value = AffectedVMs)\n| union (print Metric = "Software Added", Value = SoftwareAdded)\n| union (print Metric = "Software Removed", Value = SoftwareRemoved)\n| union (print Metric = "Service Changes", Value = ServiceChanges)'

// ─── KQL: Recent Changes grid ─────────────────────────────────────────────────
// Validated normalization: Item/Previous/Current derived per ConfigChangeType
// (Software vs WindowsServices), Change Detail carries SvcChangeType where
// relevant. Additional source fields kept as hidden columns for drill-down
// rather than shown in the main 11-column grid.
var kqlRecentChangesGrid = '${monthBoundaryKql}ConfigurationChange\n| where TimeGenerated >= MonthStart\n| where TimeGenerated < MonthEnd\n${genuineChangeFilterKql}${envExtractKql}${roleCaseKql}${environmentFilterKql}| extend Item = case(\n    ConfigChangeType == "WindowsServices",\n        iff(isnotempty(SvcDisplayName), SvcDisplayName, SvcName),\n    ConfigChangeType == "Software",\n        SoftwareName,\n    ConfigChangeType)\n| extend PreviousValue = case(\n    ConfigChangeType == "WindowsServices" and SvcChangeType == "State",\n        SvcPreviousState,\n    ConfigChangeType == "WindowsServices" and SvcChangeType == "StartupType",\n        SvcPreviousStartupType,\n    ConfigChangeType == "Software",\n        Previous,\n    "")\n| extend CurrentValue = case(\n    ConfigChangeType == "WindowsServices" and SvcChangeType == "State",\n        SvcState,\n    ConfigChangeType == "WindowsServices" and SvcChangeType == "StartupType",\n        SvcStartupType,\n    ConfigChangeType == "Software",\n        Current,\n    "")\n| project\n    Time = TimeGenerated,\n    Environment,\n    Role,\n    Computer,\n    Type = ConfigChangeType,\n    Category = ChangeCategory,\n    Item,\n    Previous = PreviousValue,\n    Current = CurrentValue,\n    ["Change Detail"] = SvcChangeType,\n    Publisher,\n    SoftwareType,\n    SvcName,\n    SvcAccount,\n    SvcPath,\n    _ResourceId\n| top 100 by Time desc'

// ─── KQL: Software Inventory (current state — ignores Report Month) ─────────
// Local filters: SoftwareTypeFilter (All/Application/Patch) and
// SoftwareSearch (substring on SoftwareName). Independent latest-collection-
// burst logic per validated model — never unlimited-history arg_max().
var kqlSoftwareInventoryTiles = 'ConfigurationData\n| where ConfigDataType == "Software"\n${currentStateLookbackKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "Software"\n    ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, SoftwareName, CurrentVersion, Publisher, Architecture, Location\n${envExtractKql}${environmentFilterKql}| summarize\n    SoftwareTitles = dcount(SoftwareName),\n    ["Application Entries"] = countif(SoftwareType == "Application"),\n    ["Patch Entries"] = countif(SoftwareType == "Patch"),\n    Publishers = dcount(Publisher)\n| project Metric = "Software Titles", Value = SoftwareTitles\n| union (print Metric = "Application Entries", Value = toscalar(ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| join kind=inner (ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer) on Computer | where TimeGenerated between (LatestTime - 5m .. LatestTime) | summarize arg_max(TimeGenerated, *) by Computer, SoftwareName, CurrentVersion, Publisher, Architecture, Location ${envExtractKql}${environmentFilterKql}| where SoftwareType == "Application" | count))\n| union (print Metric = "Patch Entries", Value = toscalar(ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| join kind=inner (ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer) on Computer | where TimeGenerated between (LatestTime - 5m .. LatestTime) | summarize arg_max(TimeGenerated, *) by Computer, SoftwareName, CurrentVersion, Publisher, Architecture, Location ${envExtractKql}${environmentFilterKql}| where SoftwareType == "Patch" | count))\n| union (print Metric = "Publishers", Value = toscalar(ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| join kind=inner (ConfigurationData | where ConfigDataType == "Software" ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer) on Computer | where TimeGenerated between (LatestTime - 5m .. LatestTime) | summarize arg_max(TimeGenerated, *) by Computer, SoftwareName, CurrentVersion, Publisher, Architecture, Location ${envExtractKql}${environmentFilterKql}| summarize by Publisher | count))'

var kqlSoftwareInventoryGrid = 'ConfigurationData\n| where ConfigDataType == "Software"\n${currentStateLookbackKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "Software"\n    ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, SoftwareName, CurrentVersion, Publisher, Architecture, Location\n${envExtractKql}${roleCaseKql}${environmentFilterKql}| where "{SoftwareTypeFilter}" == "All" or SoftwareType == "{SoftwareTypeFilter}"\n| where isempty("{SoftwareSearch}") or SoftwareName has "{SoftwareSearch}"\n| project\n    Environment,\n    Role,\n    Computer,\n    Software = SoftwareName,\n    ["Version / Status"] = CurrentVersion,\n    Publisher,\n    Type = SoftwareType,\n    Architecture,\n    ["Last Observed"] = TimeGenerated,\n    Location,\n    SoftwareDescription\n| order by Environment asc, Role asc, Computer asc, Software asc'

// ─── KQL: Service Inventory (current state — ignores Report Month) ──────────
var kqlServiceInventoryTiles = 'ConfigurationData\n| where ConfigDataType == "WindowsServices"\n${currentStateLookbackKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "WindowsServices"\n    ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, SvcName\n${envExtractKql}${environmentFilterKql}| summarize\n    ServicesObserved = count(),\n    Running = countif(SvcState == "Running"),\n    Stopped = countif(SvcState == "Stopped"),\n    Automatic = countif(SvcStartupType in ("Auto", "Automatic")),\n    Disabled = countif(SvcStartupType == "Disabled")\n| project Metric = "Services Observed", Value = ServicesObserved\n| union (print Metric = "Running", Value = Running)\n| union (print Metric = "Stopped", Value = Stopped)\n| union (print Metric = "Automatic", Value = Automatic)\n| union (print Metric = "Disabled", Value = Disabled)'

var kqlServiceInventoryGrid = 'ConfigurationData\n| where ConfigDataType == "WindowsServices"\n${currentStateLookbackKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "WindowsServices"\n    ${currentStateLookbackKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, SvcName\n${envExtractKql}${roleCaseKql}${environmentFilterKql}| project\n    Environment,\n    Role,\n    Computer,\n    Service = SvcDisplayName,\n    ["Service Name"] = SvcName,\n    State = SvcState,\n    ["Startup Type"] = SvcStartupType,\n    Account = SvcAccount,\n    Path = SvcPath,\n    ["Last Observed"] = TimeGenerated,\n    SvcDescription\n| order by Environment asc, Role asc, Computer asc, Service asc'

// ─── KQL: Configuration Differences — peer comparison ────────────────────────
// Deliberately written as one continuous inline pipe chain per role, exactly
// matching the pattern manually validated against the live workspace — NOT
// as named intermediate tabular lets combined via union (that pattern
// failed live validation). softwareDiffKql()/serviceDiffKql() only
// parametrize the fixed role literal ("Application"/"SQL") at Bicep-compile
// time via a pure string template function; the emitted KQL text for each
// role is identical to writing it out by hand twice.

func softwareDiffKql(role string) string => 'ConfigurationData\n| where ConfigDataType == "Software"\n${currentStateLookbackKql}| where "{SoftwareDiffType}" == "All" or SoftwareType == "{SoftwareDiffType}"\n${envExtractKql}${roleCaseKql}| where Role == "${role}"\n${environmentFilterKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "Software"\n    ${currentStateLookbackKql}| where "{SoftwareDiffType}" == "All" or SoftwareType == "{SoftwareDiffType}"\n    ${envExtractKql}${roleCaseKql}| where Role == "${role}"\n    ${environmentFilterKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, Environment, SoftwareName, Publisher\n| summarize\n    Environments = make_set(Environment),\n    Versions = make_set(CurrentVersion),\n    Details = make_set(\n        strcat(\n            Environment,\n            ": ",\n            iff(isempty(CurrentVersion), "(blank)", CurrentVersion)\n        )\n    )\n    by Item = SoftwareName, Publisher\n| extend PresentPeers = array_length(Environments), JoinKey = 1\n| join kind=inner (\n    ConfigurationData\n    ${currentStateLookbackKql}${envExtractKql}${roleCaseKql}| where Role == "${role}"\n    ${environmentFilterKql}| summarize PeerCount = dcount(Environment)\n    | extend JoinKey = 1\n) on JoinKey\n| extend Status = case(\n    PresentPeers < PeerCount, "Missing from peer",\n    array_length(Versions) > 1, "Version differs",\n    "Same")\n| where "{SoftwareDiffOnly}" == "No" or Status != "Same"\n| project\n    Software = Item,\n    Publisher,\n    Status,\n    ["Present Peers"] = PresentPeers,\n    ["Expected Peers"] = PeerCount,\n    ["Environment Details"] = Details\n| order by Status asc, Software asc'

func serviceDiffKql(role string) string => 'ConfigurationData\n| where ConfigDataType == "WindowsServices"\n${currentStateLookbackKql}${envExtractKql}${roleCaseKql}| where Role == "${role}"\n${environmentFilterKql}| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "WindowsServices"\n    ${currentStateLookbackKql}${envExtractKql}${roleCaseKql}| where Role == "${role}"\n    ${environmentFilterKql}| summarize LatestTime = max(TimeGenerated) by Computer\n) on Computer\n| where TimeGenerated between (LatestTime - 5m .. LatestTime)\n| summarize arg_max(TimeGenerated, *)\n    by Computer, Environment, SvcName\n| summarize\n    Environments = make_set(Environment),\n    StartupTypes = make_set(SvcStartupType),\n    States = make_set(SvcState),\n    Details = make_set(\n        strcat(\n            Environment,\n            ": ",\n            SvcStartupType,\n            " / ",\n            SvcState\n        )\n    )\n    by Item = SvcDisplayName, ServiceName = SvcName\n| extend PresentPeers = array_length(Environments), JoinKey = 1\n| join kind=inner (\n    ConfigurationData\n    | where ConfigDataType == "WindowsServices"\n    ${currentStateLookbackKql}${envExtractKql}${roleCaseKql}| where Role == "${role}"\n    ${environmentFilterKql}| summarize PeerCount = dcount(Environment)\n    | extend JoinKey = 1\n) on JoinKey\n| extend Status = case(\n    PresentPeers < PeerCount,\n        "Missing from peer",\n    array_length(StartupTypes) > 1\n        and array_length(States) > 1,\n        "Startup type & state differ",\n    array_length(StartupTypes) > 1,\n        "Startup type differs",\n    array_length(States) > 1,\n        "State differs",\n    "Same")\n| project\n    Service = Item,\n    ["Service Name"] = ServiceName,\n    Status,\n    ["Present Peers"] = PresentPeers,\n    ["Expected Peers"] = PeerCount,\n    ["Environment Details"] = Details\n| order by Status asc, Service asc'

// ─── Workbook content ─────────────────────────────────────────────────────────

var compactItemSpacing = {
  margin: '0px 0px 8px 0px'
}

// Standard Azure Workbooks tab-bar idiom (LinkItem/1.0, style "tabs") since
// none of this repository's existing single-page workbooks have a multi-
// section navigation pattern to reuse. SelectedTab is a hidden parameter
// (default "Overview") that each link updates on click; each content group
// below shows only when SelectedTab matches its own value.
var tabLinks = [
  { id: guid(workloadName, 'tab-overview'), cellValue: 'SelectedTab', linkTarget: 'parameter', linkLabel: 'Overview', subTarget: 'Overview', style: 'link' }
  { id: guid(workloadName, 'tab-change-activity'), cellValue: 'SelectedTab', linkTarget: 'parameter', linkLabel: 'Change Activity', subTarget: 'ChangeActivity', style: 'link' }
  { id: guid(workloadName, 'tab-software-inventory'), cellValue: 'SelectedTab', linkTarget: 'parameter', linkLabel: 'Software Inventory', subTarget: 'SoftwareInventory', style: 'link' }
  { id: guid(workloadName, 'tab-service-inventory'), cellValue: 'SelectedTab', linkTarget: 'parameter', linkLabel: 'Service Inventory', subTarget: 'ServiceInventory', style: 'link' }
  { id: guid(workloadName, 'tab-config-differences'), cellValue: 'SelectedTab', linkTarget: 'parameter', linkLabel: 'Configuration Differences', subTarget: 'ConfigDifferences', style: 'link' }
]

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar: Workload -> Report Month -> Environment ─────
    // Also carries the hidden SelectedTab parameter that drives the tab bar.
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          {
            id: guid(workloadName, 'p-workloadName-cti')
            version: 'KqlParameterItem/1.0'
            name: 'workloadName'
            label: 'Workload'
            type: 1
            isRequired: true
            value: workloadName
          }
          {
            id: guid(workloadName, 'p-reportMonth-cti')
            version: 'KqlParameterItem/1.0'
            name: 'ReportMonth'
            label: 'Report Month'
            type: 2
            isRequired: true
            query: kqlReportMonthParameterQuery
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }
          {
            id: guid(workloadName, 'p-environment-cti')
            version: 'KqlParameterItem/1.0'
            name: 'Environment'
            label: 'Environment'
            type: 2
            isRequired: true
            multiSelect: true
            quote: '\''
            delimiter: ','
            query: kqlEnvironmentParameterQuery
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }
          {
            id: guid(workloadName, 'p-selectedTab-cti')
            version: 'KqlParameterItem/1.0'
            name: 'SelectedTab'
            type: 1
            isRequired: true
            isHiddenWhenLocked: true
            value: 'Overview'
          }
        ]
      }
      styleSettings: compactItemSpacing
      name: 'parameters-visible'
    }

    // ── Help / semantic text ─────────────────────────────────────────────────
    {
      type: 1
      content: {
        json: 'Report Month applies to historical change activity (Overview change tiles/trend, Change Activity, Recent Changes).\n\nSoftware Inventory, Service Inventory, Coverage, and Configuration Differences show the latest observed inventory state and ignore Report Month.\n\nPeer differences are factual comparisons and do not identify an authoritative or compliant environment.'
      }
      styleSettings: compactItemSpacing
      name: 'text-help'
    }

    // ── Navigation ────────────────────────────────────────────────────────────
    {
      type: 11
      content: {
        version: 'LinkItem/1.0'
        style: 'tabs'
        links: tabLinks
      }
      styleSettings: compactItemSpacing
      name: 'links-nav'
    }

    // ── Overview ──────────────────────────────────────────────────────────────
    {
      type: 12
      content: {
        version: 'NotebookGroup/1.0'
        groupType: 'editable'
        items: [
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlOverviewTiles
              size: 0
              visualization: 'tiles'
              tileSettings: {
                titleContent: { columnMatch: 'Metric', formatter: 1 }
                leftContent: { columnMatch: 'Value', formatter: 12, formatOptions: { palette: 'auto' } }
                showBorder: false
              }
              noDataMessage: 'No CTI telemetry returned for the selected Report Month and Environment.'
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: historicalQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-overview-tiles'
          }
          {
            type: 1
            content: {
              json: '**Coverage** — latest independent Software/WindowsServices collection burst per VM. "Age" older than 24h may indicate a VM has stopped reporting recently; this is a freshness observation, not a compliance state.'
            }
            styleSettings: compactItemSpacing
            name: 'text-coverage-note'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlCoverageGrid
              size: 1
              title: 'Coverage'
              noDataMessage: 'No CTI inventory telemetry found for the selected Environment.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
              gridSettings: {
                formatters: [
                  { columnMatch: 'ResourceId', formatter: 5 }
                ]
              }
            }
            styleSettings: compactItemSpacing
            name: 'query-coverage-grid'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlDailyTrend
              size: 1
              title: 'Daily Change Activity — {ReportMonth}'
              visualization: 'timechart'
              noDataMessage: 'No genuine change events for the selected Report Month and Environment.'
              showExportToExcel: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: historicalQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-overview-trend'
          }
        ]
      }
      conditionalVisibility: {
        parameterName: 'SelectedTab'
        comparison: 'isEqualTo'
        value: 'Overview'
      }
      name: 'group-overview'
    }

    // ── Change Activity ───────────────────────────────────────────────────────
    {
      type: 12
      content: {
        version: 'NotebookGroup/1.0'
        groupType: 'editable'
        items: [
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlChangeActivityTiles
              size: 0
              visualization: 'tiles'
              tileSettings: {
                titleContent: { columnMatch: 'Metric', formatter: 1 }
                leftContent: { columnMatch: 'Value', formatter: 12, formatOptions: { palette: 'auto' } }
                showBorder: false
              }
              noDataMessage: 'No genuine change events for the selected Report Month and Environment.'
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: historicalQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-change-activity-tiles'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlDailyTrend
              size: 1
              title: 'Daily Change Activity — {ReportMonth}'
              visualization: 'timechart'
              noDataMessage: 'No genuine change events for the selected Report Month and Environment.'
              showExportToExcel: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: historicalQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-change-activity-trend'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlRecentChangesGrid
              size: 1
              title: 'Recent Changes — {ReportMonth}'
              noDataMessage: 'No genuine change events for the selected Report Month and Environment.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: historicalQueryTimeContext
              gridSettings: {
                formatters: [
                  { columnMatch: 'SoftwareType', formatter: 5 }
                  { columnMatch: 'SvcName', formatter: 5 }
                  { columnMatch: 'SvcAccount', formatter: 5 }
                  { columnMatch: 'SvcPath', formatter: 5 }
                  { columnMatch: '_ResourceId', formatter: 5 }
                ]
              }
            }
            styleSettings: compactItemSpacing
            name: 'query-recent-changes-grid'
          }
        ]
      }
      conditionalVisibility: {
        parameterName: 'SelectedTab'
        comparison: 'isEqualTo'
        value: 'ChangeActivity'
      }
      name: 'group-change-activity'
    }

    // ── Software Inventory ────────────────────────────────────────────────────
    {
      type: 12
      content: {
        version: 'NotebookGroup/1.0'
        groupType: 'editable'
        items: [
          {
            type: 9
            content: {
              version: 'KqlParameterItem/1.0'
              parameters: [
                {
                  id: guid(workloadName, 'p-softwareTypeFilter-cti')
                  version: 'KqlParameterItem/1.0'
                  name: 'SoftwareTypeFilter'
                  label: 'Software Type'
                  type: 2
                  isRequired: true
                  jsonData: '["All","Application","Patch"]'
                  value: 'All'
                  typeSettings: {
                    additionalResourceOptions: []
                    showDefault: false
                  }
                }
                {
                  id: guid(workloadName, 'p-softwareSearch-cti')
                  version: 'KqlParameterItem/1.0'
                  name: 'SoftwareSearch'
                  label: 'Search'
                  type: 1
                  isRequired: false
                }
              ]
            }
            styleSettings: compactItemSpacing
            name: 'parameters-software-inventory'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlSoftwareInventoryTiles
              size: 0
              visualization: 'tiles'
              tileSettings: {
                titleContent: { columnMatch: 'Metric', formatter: 1 }
                leftContent: { columnMatch: 'Value', formatter: 12, formatOptions: { palette: 'auto' } }
                showBorder: false
              }
              noDataMessage: 'No current software inventory found for the selected Environment.'
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-software-inventory-tiles'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlSoftwareInventoryGrid
              size: 1
              title: 'Software Inventory'
              noDataMessage: 'No current software inventory found for the selected filters.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
              gridSettings: {
                formatters: [
                  { columnMatch: 'Location', formatter: 5 }
                  { columnMatch: 'SoftwareDescription', formatter: 5 }
                ]
              }
            }
            styleSettings: compactItemSpacing
            name: 'query-software-inventory-grid'
          }
        ]
      }
      conditionalVisibility: {
        parameterName: 'SelectedTab'
        comparison: 'isEqualTo'
        value: 'SoftwareInventory'
      }
      name: 'group-software-inventory'
    }

    // ── Service Inventory ─────────────────────────────────────────────────────
    {
      type: 12
      content: {
        version: 'NotebookGroup/1.0'
        groupType: 'editable'
        items: [
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlServiceInventoryTiles
              size: 0
              visualization: 'tiles'
              tileSettings: {
                titleContent: { columnMatch: 'Metric', formatter: 1 }
                leftContent: { columnMatch: 'Value', formatter: 12, formatOptions: { palette: 'auto' } }
                showBorder: false
              }
              noDataMessage: 'No current service inventory found for the selected Environment.'
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-service-inventory-tiles'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: kqlServiceInventoryGrid
              size: 1
              title: 'Service Inventory'
              noDataMessage: 'No current service inventory found for the selected Environment.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
              gridSettings: {
                formatters: [
                  { columnMatch: 'SvcDescription', formatter: 5 }
                ]
              }
            }
            styleSettings: compactItemSpacing
            name: 'query-service-inventory-grid'
          }
        ]
      }
      conditionalVisibility: {
        parameterName: 'SelectedTab'
        comparison: 'isEqualTo'
        value: 'ServiceInventory'
      }
      name: 'group-service-inventory'
    }

    // ── Configuration Differences ─────────────────────────────────────────────
    {
      type: 12
      content: {
        version: 'NotebookGroup/1.0'
        groupType: 'editable'
        items: [
          {
            type: 1
            content: {
              json: 'Factual differences between same-role LIMS environments (Application peers: Computer ending `-001`; SQL peers: Computer ending `-002`). No environment is treated as authoritative or a baseline — this is an observation, not a compliance result. Peer comparisons respect the selected Environment; "Expected Peers" is always the current count of participating peer environments, never a fixed number.'
            }
            styleSettings: compactItemSpacing
            name: 'text-differences-note'
          }
          {
            type: 9
            content: {
              version: 'KqlParameterItem/1.0'
              parameters: [
                {
                  id: guid(workloadName, 'p-softwareDiffType-cti')
                  version: 'KqlParameterItem/1.0'
                  name: 'SoftwareDiffType'
                  label: 'Software Type (comparison)'
                  type: 2
                  isRequired: true
                  jsonData: '["Application","Patch","All"]'
                  value: 'Application'
                  typeSettings: {
                    additionalResourceOptions: []
                    showDefault: false
                  }
                }
                {
                  id: guid(workloadName, 'p-softwareDiffOnly-cti')
                  version: 'KqlParameterItem/1.0'
                  name: 'SoftwareDiffOnly'
                  label: 'Differences only'
                  type: 2
                  isRequired: true
                  jsonData: '["Yes","No"]'
                  value: 'Yes'
                  typeSettings: {
                    additionalResourceOptions: []
                    showDefault: false
                  }
                }
              ]
            }
            styleSettings: compactItemSpacing
            name: 'parameters-software-differences'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: softwareDiffKql('Application')
              size: 1
              title: 'Software Differences — Application peers'
              noDataMessage: 'No software comparison data for the selected Environment/Software Type.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-software-diff-application'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: softwareDiffKql('SQL')
              size: 1
              title: 'Software Differences — SQL peers'
              noDataMessage: 'No software comparison data for the selected Environment/Software Type.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-software-diff-sql'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: serviceDiffKql('Application')
              size: 1
              title: 'Service Differences — Application peers'
              noDataMessage: 'No service comparison data for the selected Environment.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-service-diff-application'
          }
          {
            type: 3
            content: {
              version: 'KqlItem/1.0'
              query: serviceDiffKql('SQL')
              size: 1
              title: 'Service Differences — SQL peers'
              noDataMessage: 'No service comparison data for the selected Environment.'
              showExportToExcel: true
              showPin: true
              queryType: 0
              resourceType: 'microsoft.operationalinsights/workspaces'
              crossComponentResources: [workspaceResourceId]
              timeContext: currentStateQueryTimeContext
            }
            styleSettings: compactItemSpacing
            name: 'query-service-diff-sql'
          }
        ]
      }
      conditionalVisibility: {
        parameterName: 'SelectedTab'
        comparison: 'isEqualTo'
        value: 'ConfigDifferences'
      }
      name: 'group-config-differences'
    }

    // ── Footer ─────────────────────────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '---\nSource: CTI `ConfigurationChange`/`ConfigurationData` in Log Analytics (Azure Monitor Agent Change Tracking & Inventory). No Azure Resource Manager or Resource Graph call is made by this report.'
      }
      styleSettings: compactItemSpacing
      name: 'text-footer'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────
// Deterministic name derived from stable configuration inputs only — never
// from workbookDisplayName — so renaming the title never changes resource
// identity, and redeploying with the same inputs is idempotent.

resource workbook 'microsoft.insights/workbooks@2023-06-01' = {
  name: guid(workloadName, workspaceResourceId, 'change-tracking-inventory-workbook')
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

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed workbook.')
output workbookResourceId string = workbook.id

@description('GUID name of the deployed workbook resource.')
output workbookName string = workbook.name

@description('Display name of the deployed workbook.')
output workbookDisplayName string = workbook.properties.displayName

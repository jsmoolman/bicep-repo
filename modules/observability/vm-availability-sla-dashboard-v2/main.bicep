metadata description = 'Azure Monitor Workbook v2 — VM Availability SLA Dashboard. Service-window-aware: Mon–Fri 08:00–17:00 Europe/Amsterdam. Planned maintenance support: log windows to PlannedMaintenance_CL custom LAW table — those buckets are excluded from SLA downtime calculations and surfaced in the Notes / Maintenance Ref columns. Composite-AND availability — environment is Up only when every VM has a heartbeat. Per-environment SLA targets: prd=99.9%, all others=99.0%.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload short code (e.g. "contoso"). Used in the workbook display name and title.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Full ARM resource ID of the central Log Analytics Workspace that backs the workbook.')
param workspaceResourceId string

@description('Azure region for the workbook resource. Must match the LAW region.')
param location string = 'westeurope'

@description('Tags applied to the workbook resource.')
param tags object = {}

@description('''Array of subscription-to-environment mappings that drive the KQL datatable used by all queries.
Each element: { subscriptionId: string, environment: string }.
Example: [{ subscriptionId: "8ebb26a1-...", environment: "dev" }, { subscriptionId: "cd9bed50-...", environment: "mgt" }].
Subscription IDs are automatically lowercased to match the KQL normalisation applied on the Heartbeat SubscriptionId column.
The "mgt" environment is excluded from all SLA calculations — add it here for completeness only.''')
param subscriptionEnvironmentMappings array = []

// ─── Derived names ────────────────────────────────────────────────────────────

var workbookDisplayName = 'workbook-vm-availability-v2-${workloadName}-westeu'

// ─── KQL: shared environment mapping datatable ───────────────────────────────
// Builds:  let EnvironmentMap = datatable(SubscriptionId:string, Environment:string)[...];
// injected at the top of every query. Empty array → empty datatable (valid KQL).

var envMapBody = join(
  map(subscriptionEnvironmentMappings, m => '"${toLower(m.subscriptionId)}", "${m.environment}"'),
  ', '
)
var envMapKql = 'let EnvironmentMap = datatable(SubscriptionId:string, Environment:string)[${envMapBody}];\n'

// ─── Dropdown JSON for the environment filter (mgt excluded) ─────────────────

var nonMgtMappings    = filter(subscriptionEnvironmentMappings, m => m.environment != 'mgt')
var envDropdownValues = join(map(nonMgtMappings, m => '"${m.environment}"'), ',')
var envDropdownJson   = '["All",${envDropdownValues}]'

// ─── KQL: Monthly environment summary v2 ─────────────────────────────────────
//
// Service window: Mon–Fri, 08:00–17:00 Europe/Amsterdam.
//   swStartMinutes = 480 (8×60+0).
//   swEndMinutes   = 1020 (17×60+0).
//
// Planned maintenance:
//   PlannedMaintenance_CL custom LAW table.
//   union isfuzzy=true — query works even when the table has never been written.
//   Planned buckets are subtracted from DownBuckets for SLA purposes.
//   Reference numbers surfaced in the Notes column.
//
// Bucket model (unchanged from v1):
//   Up bucket   = ≥1 heartbeat received in the 5-minute slot.
//   Down bucket = no heartbeat in the slot.
//   Composite-AND: environment is Up only when every VM is Up in that slot.

var kqlMonthlySummary = '${envMapKql}let bucketSize     = 5m;\nlet swStartMinutes = 480;  // 08:00 Amsterdam (8*60)\nlet swEndMinutes   = 1020; // 17:00 Amsterdam (17*60)\nlet selectedMonth    = startofmonth(todatetime("{reportMonth}"));\nlet localPeriodStart = selectedMonth;\nlet localPeriodEnd   = iff(startofmonth(datetime_utc_to_local(now(), "Europe/Amsterdam")) == selectedMonth, datetime_utc_to_local(now() - 15m, "Europe/Amsterdam"), startofmonth(selectedMonth + 32d));\nlet periodStart = datetime_local_to_utc(localPeriodStart, "Europe/Amsterdam");\nlet periodEnd   = datetime_local_to_utc(localPeriodEnd,   "Europe/Amsterdam");\n// Working days in the full calendar month (informational column)\nlet monthStart      = startofmonth(localPeriodStart);\nlet nextMonthStart  = startofmonth(localPeriodStart + 32d);\nlet workDaysInMonth = toscalar(\n    range Day from monthStart to nextMonthStart - 1d step 1d\n    | where dayofweek(Day) between (1d .. 5d)\n    | count);\n// Full-month service-window buckets — drives budget columns (Max Allowed, Downtime, Remaining)\nlet monthStartUtc    = datetime_local_to_utc(monthStart, "Europe/Amsterdam");\nlet nextMonthUtc     = datetime_local_to_utc(nextMonthStart, "Europe/Amsterdam");\nlet fullMonthBuckets = toscalar(\n    range BucketTime from bin(monthStartUtc, bucketSize) to bin(nextMonthUtc, bucketSize) step bucketSize\n    | where BucketTime < nextMonthUtc\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | count);\n// Total expected service-window buckets for the elapsed period\nlet totalBuckets = toscalar(\n    range BucketTime from bin(periodStart, bucketSize) to bin(periodEnd, bucketSize) step bucketSize\n    | where BucketTime < periodEnd\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | count);\n// Planned maintenance windows — isfuzzy=true union handles missing table gracefully;\n// the empty datatable ensures the schema is always defined.\nlet PlannedWindows =\n    union isfuzzy=true\n        (PlannedMaintenance_CL\n         | where MaintenanceStart_t < periodEnd and MaintenanceEnd_t > periodStart\n         | project Environment=Environment_s, WinStart=MaintenanceStart_t, WinEnd=MaintenanceEnd_t, Ref=ReferenceNumber_s, Reason=Reason_s),\n        (datatable(Environment:string, WinStart:datetime, WinEnd:datetime, Ref:string, Reason:string)[]);\n// Count 5-min service-window buckets inside planned windows per environment\nlet plannedBucketsPerEnv =\n    PlannedWindows\n    | extend BucketTime = range(bin(WinStart, bucketSize), bin(WinEnd, bucketSize), bucketSize)\n    | mv-expand BucketTime to typeof(datetime)\n    | where BucketTime >= periodStart and BucketTime < periodEnd and BucketTime < WinEnd\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | summarize PlannedBuckets=dcount(BucketTime) by Environment;\n// Reference numbers per environment for the Notes column\nlet maintenanceNotes =\n    PlannedWindows\n    | where isnotempty(Ref)\n    | summarize Notes=strcat_array(make_set(strcat(Ref, " - ", Reason)), " | ") by Environment;\n// Heartbeat data — filtered to service window only\nlet HB =\n    Heartbeat\n    | where TimeGenerated >= periodStart and TimeGenerated < periodEnd\n    | extend BucketTime   = bin(TimeGenerated, bucketSize)\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | summarize Heartbeats=count() by NormSubId=tolower(tostring(SubscriptionId)), _ResourceId=tolower(_ResourceId), Computer, BucketTime\n    | join kind=leftouter (EnvironmentMap | project NormSubId=SubscriptionId, Environment) on NormSubId\n    | where isnotempty(Environment) and Environment != "mgt";\n// All environments from the mapping (excluding mgt)\nlet envList = EnvironmentMap | where Environment != "mgt" | summarize by Environment;\n// Distinct VM count per environment (for composite-AND check)\nlet envVmCounts = HB | summarize VmsInEnv=dcount(_ResourceId) by Environment;\n// Composite-AND: a bucket is Up for the environment only when every VM had >=1 heartbeat\nlet envComposite =\n    HB\n    | summarize UpVmCount=count() by Environment, BucketTime\n    | join kind=inner envVmCounts on Environment\n    | where UpVmCount == VmsInEnv\n    | summarize CompositeUpBuckets=count() by Environment;\n// Final result — every environment shown; zero-data environments show 0%\nenvList\n| extend SlaTargetPct = iff(Environment == "prd", 99.9, 99.0)\n| join kind=leftouter envComposite on Environment\n| join kind=leftouter plannedBucketsPerEnv on Environment\n| join kind=leftouter maintenanceNotes on Environment\n| extend CompositeUpBuckets  = coalesce(CompositeUpBuckets, 0)\n| extend PlannedBuckets      = coalesce(PlannedBuckets, 0)\n| extend Notes               = coalesce(Notes, "")\n| extend TotalServiceWindowBuckets = totalBuckets\n| extend UpBucketsTotal      = iff(CompositeUpBuckets > totalBuckets, totalBuckets, CompositeUpBuckets)\n| extend DownBucketsTotal    = TotalServiceWindowBuckets - UpBucketsTotal\n| extend PlannedDownBuckets  = iff(PlannedBuckets > DownBucketsTotal, DownBucketsTotal, PlannedBuckets)\n| extend UnplannedDownBuckets = DownBucketsTotal - PlannedDownBuckets\n| extend AdjustedUpBuckets   = UpBucketsTotal + PlannedDownBuckets\n| extend AvailabilityPct     = iff(TotalServiceWindowBuckets == 0, 0.0, round(todouble(AdjustedUpBuckets) / todouble(TotalServiceWindowBuckets) * 100, 3))\n| extend MaxUnavailabilityBucketsAllowed = toint(todouble(fullMonthBuckets) * (1.0 - SlaTargetPct / 100.0))\n| extend DowntimeMinutesAllowed          = MaxUnavailabilityBucketsAllowed * 5\n| extend CurrentUnavailabilityBuckets    = UnplannedDownBuckets\n| extend CurrentDowntimeMinutes          = CurrentUnavailabilityBuckets * 5\n| extend PlannedDowntimeMinutes          = PlannedDownBuckets * 5\n| extend RemainingUnavailabilityBuckets  = MaxUnavailabilityBucketsAllowed - CurrentUnavailabilityBuckets\n| extend SlaStatus                       = iff(AvailabilityPct >= SlaTargetPct, "Met", "Breached")\n| extend SlaMinutesForMonth   = toint(fullMonthBuckets) * 5\n| extend ElapsedSlaMinutes    = toint(totalBuckets) * 5\n| extend CurrentUptimeMinutes = AdjustedUpBuckets * 5\n| where "{environment}" == "All" or Environment == "{environment}"\n| project Environment, AvailabilityPct, SlaTargetPct, SlaStatus, WorkDaysInMonth=workDaysInMonth, SlaMinutesForMonth, ElapsedSlaMinutes, CurrentUptimeMinutes, CurrentDowntimeMinutes, PlannedDowntimeMinutes, DowntimeMinutesAllowed, Notes, TotalServiceWindowBuckets, MaxUnavailabilityBucketsAllowed, UpBucketsTotal, DownBucketsTotal, CurrentUnavailabilityBuckets, RemainingUnavailabilityBuckets\n| order by Environment asc'

// ─── KQL: VM Daily Breakdown v2 ──────────────────────────────────────────────
// One row per VM per Amsterdam calendar day (Mon–Fri, service window only).
// Planned maintenance buckets are subtracted from DownBuckets and shown in
// PlannedMinutes / MaintenanceRef columns. UnavailableTime/RecoveryTime still
// reflect the actual heartbeat gap (informational — even planned gaps are shown).

var kqlVmDaily = '${envMapKql}let bucketSize     = 5m;\nlet swStartMinutes = 480;  // 08:00 Amsterdam (8*60)\nlet swEndMinutes   = 1020; // 17:00 Amsterdam (17*60)\nlet selectedMonth    = startofmonth(todatetime("{reportMonth}"));\nlet localPeriodStart = selectedMonth;\nlet localPeriodEnd   = iff(startofmonth(datetime_utc_to_local(now(), "Europe/Amsterdam")) == selectedMonth, datetime_utc_to_local(now() - 15m, "Europe/Amsterdam"), startofmonth(selectedMonth + 32d));\nlet periodStart = datetime_local_to_utc(localPeriodStart, "Europe/Amsterdam");\nlet periodEnd   = datetime_local_to_utc(localPeriodEnd,   "Europe/Amsterdam");\n// Heartbeat buckets — service window only, grouped by Amsterdam calendar day\nlet HB =\n    Heartbeat\n    | where TimeGenerated >= periodStart and TimeGenerated < periodEnd\n    | extend BucketTime   = bin(TimeGenerated, bucketSize)\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | extend DayDate = startofday(LocalDt)\n    | summarize FirstHB=min(TimeGenerated), LastHB=max(TimeGenerated) by NormSubId=tolower(tostring(SubscriptionId)), _ResourceId=tolower(_ResourceId), Computer, BucketTime, DayDate\n    | join kind=leftouter (EnvironmentMap | project NormSubId=SubscriptionId, Environment) on NormSubId\n    | where isnotempty(Environment) and Environment != "mgt";\n// Detect first bucket where each VM became unavailable (mid-day gap via serialize+prev)\nlet firstGap =\n    HB\n    | summarize Buckets=make_set(BucketTime) by _ResourceId, DayDate\n    | mv-expand BucketTime=Buckets to typeof(datetime)\n    | order by _ResourceId asc, DayDate asc, BucketTime asc\n    | serialize\n    | extend PrevTime = prev(BucketTime), PrevId = prev(_ResourceId), PrevDay = prev(DayDate)\n    | where _ResourceId == PrevId and DayDate == PrevDay\n    | where BucketTime > PrevTime + bucketSize\n    | summarize FirstGapAt=min(PrevTime + bucketSize), FirstRecoveryAt=min(BucketTime) by _ResourceId, DayDate;\n// Planned maintenance — per environment per Amsterdam calendar day\nlet plannedByDay =\n    union isfuzzy=true\n        (PlannedMaintenance_CL\n         | where MaintenanceStart_t < periodEnd and MaintenanceEnd_t > periodStart\n         | project Environment=Environment_s, WinStart=MaintenanceStart_t, WinEnd=MaintenanceEnd_t, Ref=ReferenceNumber_s),\n        (datatable(Environment:string, WinStart:datetime, WinEnd:datetime, Ref:string)[])\n    | extend BucketTime = range(bin(WinStart, bucketSize), bin(WinEnd, bucketSize), bucketSize)\n    | mv-expand BucketTime to typeof(datetime)\n    | where BucketTime >= periodStart and BucketTime < periodEnd and BucketTime < WinEnd\n    | extend LocalDt      = datetime_utc_to_local(BucketTime, "Europe/Amsterdam")\n    | extend TimeOfDayMin = toint((LocalDt - startofday(LocalDt)) / 1min)\n    | where TimeOfDayMin >= swStartMinutes and TimeOfDayMin < swEndMinutes\n    | where dayofweek(LocalDt) between (1d .. 5d)\n    | extend DayDate = startofday(LocalDt)\n    | summarize PlannedBuckets=dcount(BucketTime), PlannedRefs=strcat_array(make_set(Ref), " | ") by Environment, DayDate;\n// Per-VM per-day: up bucket count + partial-day expected buckets\nHB\n| summarize UpBuckets=count(), FirstHB=min(FirstHB), LastHB=max(LastHB) by Environment, _ResourceId, Computer, DayDate\n| extend DayStartUtc    = datetime_local_to_utc(DayDate, "Europe/Amsterdam")\n| extend ActualStartUtc = iff(DayStartUtc + toint(swStartMinutes) * 1m > periodStart, DayStartUtc + toint(swStartMinutes) * 1m, periodStart)\n| extend ActualEndUtc   = iff(DayStartUtc + toint(swEndMinutes) * 1m - bucketSize < periodEnd, DayStartUtc + toint(swEndMinutes) * 1m - bucketSize, periodEnd)\n| extend ExpectedBuckets = toint((bin(ActualEndUtc, bucketSize) - bin(ActualStartUtc, bucketSize)) / bucketSize) + 1\n| join kind=leftouter firstGap on _ResourceId, DayDate\n| join kind=leftouter plannedByDay on Environment, DayDate\n| extend PlannedBuckets     = coalesce(PlannedBuckets, 0)\n| extend PlannedRefs        = coalesce(PlannedRefs, "")\n| extend UpBuckets          = iff(UpBuckets > ExpectedBuckets, ExpectedBuckets, UpBuckets)\n| extend DownBuckets        = ExpectedBuckets - UpBuckets\n| extend PlannedDownBuckets  = iff(PlannedBuckets > DownBuckets, DownBuckets, PlannedBuckets)\n| extend UnplannedDownBuckets = DownBuckets - PlannedDownBuckets\n| extend AdjustedUpBuckets   = UpBuckets + PlannedDownBuckets\n| extend EarlyGap       = iff(bin(FirstHB, bucketSize) > ActualStartUtc, ActualStartUtc, datetime(null))\n| extend TailGap        = iff(DownBuckets > 0 and isnull(FirstGapAt) and isnull(EarlyGap), bin(LastHB, bucketSize) + bucketSize, datetime(null))\n| extend GapUtc         = iff(isnotempty(EarlyGap), EarlyGap, iff(isnotempty(FirstGapAt), FirstGapAt, TailGap))\n| extend AvailabilityPct = iff(ExpectedBuckets == 0, 0.0, round(todouble(AdjustedUpBuckets) / todouble(ExpectedBuckets) * 100, 3))\n| extend SlaTargetPct    = iff(Environment == "prd", 99.9, 99.0)\n| extend SlaStatus       = iff(AvailabilityPct >= SlaTargetPct, "Met", "Breached")\n| extend DaySlaMinutes   = ExpectedBuckets * 5\n| extend UpMinutes       = AdjustedUpBuckets * 5\n| extend DownMinutes     = UnplannedDownBuckets * 5\n| extend PlannedMinutes  = PlannedDownBuckets * 5\n| extend FirstHeartbeat  = format_datetime(datetime_utc_to_local(FirstHB, "Europe/Amsterdam"), "yyyy-MM-dd HH:mm")\n| extend LastHeartbeat   = format_datetime(datetime_utc_to_local(LastHB,  "Europe/Amsterdam"), "yyyy-MM-dd HH:mm")\n| extend UnavailableTime = iff(DownBuckets > 0 and isnotempty(GapUtc), format_datetime(datetime_utc_to_local(GapUtc, "Europe/Amsterdam"), "yyyy-MM-dd HH:mm"), "")\n| extend RecoveryUtc     = iff(isnotempty(EarlyGap), bin(FirstHB, bucketSize), iff(isnotempty(FirstGapAt) and isnotempty(FirstRecoveryAt), FirstRecoveryAt, datetime(null)))\n| extend RecoveryTime    = iff(DownBuckets > 0 and isnotempty(RecoveryUtc), format_datetime(datetime_utc_to_local(RecoveryUtc, "Europe/Amsterdam"), "yyyy-MM-dd HH:mm"), iff(isnotempty(TailGap), "Still down at EoW", ""))\n| where "{environment}" == "All" or Environment == "{environment}"\n| project Date=format_datetime(DayDate, "yyyy-MM-dd"), Environment, Computer, AvailabilityPct, SlaTargetPct, SlaStatus, DaySlaMinutes, UpMinutes, DownMinutes, PlannedMinutes, MaintenanceRef=PlannedRefs, FirstHeartbeat, LastHeartbeat, UnavailableTime, RecoveryTime, ResourceId=_ResourceId\n| order by Date desc, Environment asc, Computer asc'

// ─── Number format helpers ────────────────────────────────────────────────────

var nfPct3dp = {
  unit: 0
  options: {
    style: 'decimal'
    minimumFractionDigits: 2
    maximumFractionDigits: 3
  }
}

var nfPct1dp = {
  unit: 0
  options: {
    style: 'decimal'
    minimumFractionDigits: 1
    maximumFractionDigits: 1
  }
}

// ─── Workbook content ─────────────────────────────────────────────────────────

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Parameters bar ──────────────────────────────────────────────────────
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [

          // workloadName: pre-filled, editable label
          {
            id: guid(workloadName, 'p-workloadName-v2')
            version: 'KqlParameterItem/1.0'
            name: 'workloadName'
            label: 'Workload'
            type: 1
            isRequired: true
            value: workloadName
          }

          // reportMonth: dropdown showing the last 12 months (current month pre-selected).
          {
            id: guid(workloadName, 'p-reportMonth-v2')
            version: 'KqlParameterItem/1.0'
            name: 'reportMonth'
            label: 'Report Month'
            type: 2
            isRequired: true
            query: 'range MonthOffset from 0 to 11 step 1 | extend MonthStart = startofmonth(datetime_utc_to_local(now(), "Europe/Amsterdam") - MonthOffset * 30d) | order by MonthStart desc | project value=format_datetime(MonthStart, "yyyy-MM-dd"), label=strcat(format_datetime(MonthStart, "yyyy-MM"), iff(MonthOffset == 0, " (current, live)", ""))'
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            value: 'value::1'
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

          // environment: single-select filter; "All" shows every environment
          {
            id: guid(workloadName, 'p-environment-v2')
            version: 'KqlParameterItem/1.0'
            name: 'environment'
            label: 'Environment'
            type: 2
            isRequired: false
            jsonData: envDropdownJson
            value: 'All'
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

        ]
      }
      name: 'parameters'
    }

    // ── Section 1: Title / description ──────────────────────────────────────
    {
      type: 1
      content: {
        json: '# VM Availability SLA Dashboard v2 — {workloadName}\n\n| | |\n|---|---|\n| **Report month** | {reportMonth} |\n| **Service window** | Mon–Fri, 08:00–17:00 Europe/Amsterdam |\n| **Data source** | Heartbeat table — central Log Analytics Workspace |\n| **Bucket size** | 5 minutes |\n| **Up bucket** | ≥1 heartbeat received in the 5-minute slot |\n| **Down bucket** | No heartbeat in the slot |\n| **Env availability** | Composite-AND — environment is Up only when every VM is Up in the same slot |\n| **SLA targets** | Production: 99.9% — All other environments: 99.0% |\n| **Planned maintenance** | Log windows to `PlannedMaintenance_CL` in this LAW — those buckets are excluded from SLA downtime and shown in the **Notes** / **Maintenance Ref** columns |'
      }
      name: 'text-title'
    }

    // ── Section 2: Monthly environment summary ───────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlMonthlySummary
        size: 0
        title: 'Monthly Environment Summary — Service Window: Mon–Fri 08:00–17:00'
        noDataMessage: 'No heartbeat data found for the selected period. Verify AMA/DCR deployment and that the subscription-environment mappings in the workbook parameters are correct.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        gridSettings: {
          formatters: [

            // Availability % — horizontal progress bar; red = low, green = high
            {
              columnMatch: 'AvailabilityPct'
              formatter: 8
              formatOptions: {
                palette: 'redGreen'
                customColumnWidthSetting: '130px'
              }
              numberFormat: nfPct3dp
            }

            // SLA Target % — plain decimal (1dp)
            {
              columnMatch: 'SlaTargetPct'
              formatter: 0
              numberFormat: nfPct1dp
            }

            // SLA Status — background colour: green = Met, red = Breached
            {
              columnMatch: 'SlaStatus'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: 'Met',      representation: 'green',    text: '{0}{1}' }
                  { operator: 'Default',                         representation: 'redBright', text: '{0}{1}' }
                ]
              }
            }

            // Current Downtime Minutes (unplanned) — green = 0, orange = any
            {
              columnMatch: 'CurrentDowntimeMinutes'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: '0', representation: 'green',  text: '{0}{1}' }
                  { operator: 'Default',                  representation: 'orange', text: '{0}{1}' }
                ]
              }
            }

            // Planned Downtime Minutes — green = 0, blue = planned maintenance happened
            {
              columnMatch: 'PlannedDowntimeMinutes'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: '0', representation: 'green', text: '{0}{1}' }
                  { operator: 'Default',                  representation: 'blue',  text: '{0}{1}' }
                ]
              }
            }

            // Notes — plain text (populated from PlannedMaintenance_CL reference numbers)
            {
              columnMatch: 'Notes'
              formatter: 1
            }

            // Hidden columns — retained for Excel export, not displayed in the grid
            { columnMatch: 'TotalServiceWindowBuckets',       formatter: 5 }
            { columnMatch: 'MaxUnavailabilityBucketsAllowed', formatter: 5 }
            { columnMatch: 'UpBucketsTotal',                  formatter: 5 }
            { columnMatch: 'DownBucketsTotal',                formatter: 5 }
            { columnMatch: 'CurrentUnavailabilityBuckets',    formatter: 5 }
            { columnMatch: 'RemainingUnavailabilityBuckets',  formatter: 5 }

          ]
          labelSettings: [
            // ── Visible columns ────────────────────────────────────────────
            { columnId: 'Environment',              label: 'Environment' }
            { columnId: 'AvailabilityPct',          label: 'Availability %' }
            { columnId: 'SlaTargetPct',             label: 'SLA Target %' }
            { columnId: 'SlaStatus',                label: 'SLA Status' }
            { columnId: 'WorkDaysInMonth',          label: 'Work Days in Month' }
            { columnId: 'SlaMinutesForMonth',       label: 'SLA Minutes for Month' }
            { columnId: 'ElapsedSlaMinutes',        label: 'Elapsed SLA Minutes' }
            { columnId: 'CurrentUptimeMinutes',     label: 'Current Uptime Minutes' }
            { columnId: 'CurrentDowntimeMinutes',   label: 'Unplanned Downtime Minutes' }
            { columnId: 'PlannedDowntimeMinutes',   label: 'Planned Downtime Minutes' }
            { columnId: 'DowntimeMinutesAllowed',   label: 'Downtime Minutes Allowed' }
            { columnId: 'Notes',                    label: 'Notes' }
            // ── Hidden columns (available in Excel export) ─────────────────
            { columnId: 'TotalServiceWindowBuckets',       label: 'Total Service Window Buckets in Month' }
            { columnId: 'MaxUnavailabilityBucketsAllowed', label: 'Max Unavailability Buckets Allowed' }
            { columnId: 'UpBucketsTotal',                  label: 'Up Buckets Total' }
            { columnId: 'DownBucketsTotal',                label: 'Down Buckets Total' }
            { columnId: 'CurrentUnavailabilityBuckets',    label: 'Current Unavailability Buckets Total' }
            { columnId: 'RemainingUnavailabilityBuckets',  label: 'Remaining Unavailability Buckets' }
          ]
        }
      }
      name: 'query-monthly'
    }

    // ── Section 3: VM Daily Breakdown ────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlVmDaily
        size: 0
        title: 'VM Daily Breakdown — Mon–Fri 08:00–17:00 (newest date first)'
        noDataMessage: 'No VM heartbeat data found for the selected period and environment. Try selecting a specific environment using the filter above.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        gridSettings: {
          formatters: [

            // Availability % — progress bar
            {
              columnMatch: 'AvailabilityPct'
              formatter: 8
              formatOptions: {
                palette: 'redGreen'
                customColumnWidthSetting: '130px'
              }
              numberFormat: nfPct3dp
            }

            // SLA Target % — plain decimal (1dp)
            {
              columnMatch: 'SlaTargetPct'
              formatter: 0
              numberFormat: nfPct1dp
            }

            // SLA Status — background colour: green = Met, red = Breached
            {
              columnMatch: 'SlaStatus'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: 'Met',  representation: 'green',    text: '{0}{1}' }
                  { operator: 'Default',                     representation: 'redBright', text: '{0}{1}' }
                ]
              }
            }

            // Down Minutes (unplanned) — green = 0, orange = any unplanned downtime
            {
              columnMatch: 'DownMinutes'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: '0', representation: 'green',  text: '{0}{1}' }
                  { operator: 'Default',                  representation: 'orange', text: '{0}{1}' }
                ]
              }
            }

            // Planned Minutes — green = 0, blue = planned maintenance happened
            {
              columnMatch: 'PlannedMinutes'
              formatter: 18
              formatOptions: {
                thresholdsOptions: 'colors'
                thresholdsGrid: [
                  { operator: '==', thresholdValue: '0', representation: 'green', text: '{0}{1}' }
                  { operator: 'Default',                  representation: 'blue',  text: '{0}{1}' }
                ]
              }
            }

            // MaintenanceRef — plain text (reference numbers from PlannedMaintenance_CL)
            {
              columnMatch: 'MaintenanceRef'
              formatter: 1
            }

            // Resource ID — hidden, available in Excel export
            { columnMatch: 'ResourceId', formatter: 5 }

          ]
          labelSettings: [
            { columnId: 'Date',            label: 'Date' }
            { columnId: 'Environment',     label: 'Environment' }
            { columnId: 'Computer',        label: 'Computer' }
            { columnId: 'AvailabilityPct', label: 'Availability %' }
            { columnId: 'SlaTargetPct',    label: 'SLA Target %' }
            { columnId: 'SlaStatus',       label: 'SLA Status' }
            { columnId: 'DaySlaMinutes',   label: 'Day SLA Minutes' }
            { columnId: 'UpMinutes',       label: 'Up Minutes' }
            { columnId: 'DownMinutes',     label: 'Unplanned Down Minutes' }
            { columnId: 'PlannedMinutes',  label: 'Planned Minutes' }
            { columnId: 'MaintenanceRef',  label: 'Maintenance Ref' }
            { columnId: 'FirstHeartbeat',  label: 'First Heartbeat' }
            { columnId: 'LastHeartbeat',   label: 'Last Heartbeat' }
            { columnId: 'UnavailableTime', label: 'Unavailable Time' }
            { columnId: 'RecoveryTime',    label: 'Recovery Time' }
            { columnId: 'ResourceId',      label: 'Resource ID' }
          ]
        }
      }
      name: 'query-vm-daily'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────

resource workbook 'microsoft.insights/workbooks@2023-06-01' = {
  name: guid(workloadName, workspaceResourceId, 'vm-availability-workbook-v2')
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

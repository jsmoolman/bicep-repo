metadata description = 'Azure Monitor Workbook — Backup & Restore dashboard, reading exclusively from three existing Azure Backup Log Analytics tables (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy). Creates or modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity resource, and makes no ARM/Resource Graph/Recovery Services API call.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code. Used for parameter labelling and as a deterministic workbook name/GUID seed input; not used to filter any LAW table.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('Full ARM resource ID of the existing Log Analytics workspace that already receives Azure Backup diagnostic telemetry. This module creates no table, Data Collection Rule, or diagnostic setting.')
param workspaceResourceId string

@description('''Array of { subscriptionId, environment } mappings. The three Azure Backup LAW tables have no Environment column of their own; every query derives Environment by matching each row against tolower(coalesce(_SubscriptionId, SubscriptionId, extract(...ResourceId...))). A resolved ID not present here is retained and labelled Unmapped for job/restore telemetry, but excluded from Protected Estate and Backup Policy Evidence.''')
param subscriptionEnvironmentMappings array = []

@description('Optional allowlist of AddonAzureBackupPolicy PolicyName values shown in Backup Policy Evidence. Empty (default) applies no filter. Presentation filtering only — never asserts per-item/database policy assignment.')
param agreedPolicyNames array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Derived configuration (no hard-coded environment names) ─────────────────
// Environment values shown/zero-filled in grids and offered in the Environment
// selector come only from subscriptionEnvironmentMappings, never a literal list.

var allEnvironmentValues = [for m in subscriptionEnvironmentMappings: m.environment]
var configuredEnvironments = union([], allEnvironmentValues)
var configuredEnvironmentsKqlBody = join(map(configuredEnvironments, e => '"${e}"'), ', ')

// Subscription -> Environment KQL mapping body, consumed by every grid below via
// a shared datatable(SubscriptionId:string, Environment:string).
var subscriptionEnvironmentMapKqlBody = join(map(subscriptionEnvironmentMappings, m => '"${m.subscriptionId}", "${m.environment}"'), ', ')

// Agreed Backup Policy Evidence allowlist -> KQL dynamic([...]) array body.
// Empty means no filter is applied (see kqlPolicyGrid).
var agreedPolicyNamesKqlBody = join(map(agreedPolicyNames, n => '"${n}"'), ', ')

// ─── Explicit LAW query time context ──────────────────────────────────────────
// Explicit 730-day window on every query item so the Azure portal time picker
// can never silently truncate backup history.

var lawQueryTimeContext = {
  durationMs: 63072000000
}

// ─── KQL: shared Subscription -> Environment mapping fragment ────────────────
// resolvedSubscriptionIdExpr is the single subscription-resolution expression
// used by every query below against AddonAzureBackupJobs, CoreAzureBackup, or
// AddonAzureBackupPolicy. tolower(coalesce(...)) so GUID casing never causes a
// missed match; _SubscriptionId is checked first since it is the populated
// field on these tables, with SubscriptionId and a ResourceId-parsed GUID as
// fallbacks only.
//
// subscriptionEnvironmentMapJoinKql is the shared join target: SubscriptionId
// from SubscriptionEnvironmentMap, tolower()-normalized, aliased to
// ResolvedSubscriptionId.

var resolvedSubscriptionIdExpr = 'tolower(coalesce(_SubscriptionId, SubscriptionId, extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, ResourceId), extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, _ResourceId)))'
var subscriptionEnvironmentMapJoinKql = '(SubscriptionEnvironmentMap | project ResolvedSubscriptionId = tolower(SubscriptionId), Environment)'

var subEnvMapKql = 'let SubscriptionEnvironmentMap = datatable(SubscriptionId:string, Environment:string) [${subscriptionEnvironmentMapKqlBody}];\n'

// ─── KQL: shared normalized-jobs fragment (AddonAzureBackupJobs) ─────────────
// Sole data-access path into AddonAzureBackupJobs for the hero, six-month, and
// failures grids. arg_max(TimeGenerated, *) by JobUniqueId keeps the newest
// record per job. LEFT OUTER join to Environment: a job whose subscription is
// not configured is retained as "Unmapped" rather than dropped, visible under
// Environment = All. Backup classes: VM Backup = IaaSVM+Backup; SQL Full /
// Differential / Log = AzureWorkload+Backup with matching JobOperationSubType;
// anything else gets Class = "" and is excluded from grids grouped by Class.
// Succeeded requires JobStatus =~ "Completed" AND JobFailureCode =~ "Success";
// Failed requires JobStatus =~ "Failed" only. MonthKey buckets by
// JobStartDateTime (business time), not ingestion time. TelemetryPresence
// records which (Environment, MonthKey) pairs have at least one row, used to
// distinguish a genuinely empty month (Unavailable) from a real zero.

var normalizedJobsKql = '${subEnvMapKql}let NormalizedJobs =\n    AddonAzureBackupJobs\n    | summarize arg_max(TimeGenerated, *) by JobUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=leftouter ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | extend Environment = coalesce(Environment, "Unmapped")\n    | extend Class = case(\n        BackupManagementType == "IaaSVM" and JobOperation == "Backup", "VM Backup",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Full", "SQL Full",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Differential", "SQL Differential",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Log", "SQL Log",\n        "")\n    | extend IsSucceeded = (JobStatus =~ "Completed" and JobFailureCode =~ "Success")\n    | extend IsFailed = (JobStatus =~ "Failed")\n    | extend MonthKey = format_datetime(startofmonth(JobStartDateTime), "yyyy-MM");\nlet TelemetryPresence = NormalizedJobs | summarize by Environment, MonthKey;\n'

// ─── KQL: shared six-month window fragment ────────────────────────────────────
// Report Month + five preceding calendar months (datetime_add, calendar-
// accurate). IsValidMonth is evaluated per (selected Environment, month)
// against TelemetryPresence: a month with no source telemetry for the
// selection renders Unavailable ("-"), never a fabricated zero.

var monthWindowKql = 'let selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet telemetryMonthsForSelectedEnvironment =\n    TelemetryPresence\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | summarize by MonthKey;\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (telemetryMonthsForSelectedEnvironment | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\n'

// ─── KQL: shared "current job base" fragment ──────────────────────────────────
// execBase (tracked classes only, selected Environment only) is shared by the
// Hero, Six-Month, and Failures grids, so Failures always reconciles with the
// Hero grid's own Failed values. BackupClasses is the fixed four-class
// reporting taxonomy, always shown even at zero.

var execCommonKql = '${normalizedJobsKql}${monthWindowKql}let execBase = NormalizedJobs | where Class != "" | where "{Environment}" == "All" or Environment == "{Environment}";\nlet BackupClasses = datatable(Class:string) ["VM Backup", "SQL Full", "SQL Differential", "SQL Log"];\n'

// ─── KQL: shared Success % formatting helper (Hero + Six-Month grids) ────────
// Exact "100%" only when SucceededCount == ExecutedCount (caller guarantees
// ExecutedCount > 0). Otherwise rounds to 2 decimals, always padded (e.g.
// "95.00%"). The `capped` guard prevents standard rounding from promoting a
// value genuinely below 100 up to "100.00%" (e.g. 99.995 -> 100.00): a
// non-exact match is capped at "99.99%" instead, so "100%" can only appear
// when Succeeded literally equals Executed.

var formatSuccessPctKql = 'let FormatSuccessPct = (SucceededCount:long, ExecutedCount:long) {\n    let isExactMatch = SucceededCount == ExecutedCount;\n    let pct = 100.0 * SucceededCount / ExecutedCount;\n    let rounded = round(pct, 2);\n    let capped = iff(not(isExactMatch) and rounded >= 100.0, 99.99, rounded);\n    let s = tostring(capped);\n    let dotIdx = indexof(s, ".");\n    let wholePart = iff(dotIdx == -1, s, substring(s, 0, dotIdx));\n    let fracRaw = iff(dotIdx == -1, "", substring(s, dotIdx + 1));\n    let fracPadded = case(strlen(fracRaw) == 0, "00", strlen(fracRaw) == 1, strcat(fracRaw, "0"), substring(fracRaw, 0, 2));\n    iff(isExactMatch, "100%", strcat(wholePart, ".", fracPadded, "%"))\n};\n'

// ─── KQL: Hero grid — Backup Activity for the selected Report Month only ─────
// Metric rows (Executed/Succeeded/Failed/Success %) x Class columns (VM
// Backup/SQL Full/SQL Differential/SQL Log) — melt-then-pivot pattern.
// isValidSelectedMonth reuses monthList's own MonthOffset == 0 row so this
// grid's validity decision can never drift from the Six-Month grid's own.
// No telemetry for the month -> all four fields render "-"; telemetry with
// zero executions of a class -> real "0" counts and "-" Success % (never a
// fabricated "100%"); otherwise all four render real computed values. No
// Trend row. The final project enforces column order VM Backup / SQL Full /
// SQL Differential / SQL Log, matching Agreed Backup Strategy above.

var kqlHeroGrid = '${execCommonKql}${formatSuccessPctKql}let selectedMonthCounts = execBase | where MonthKey == "{ReportMonth}" | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Class;\nlet isValidSelectedMonth = toscalar(monthList | where MonthOffset == 0 | project IsValidMonth);\nlet heroRows =\n    BackupClasses\n    | join kind=leftouter selectedMonthCounts on Class\n    | extend Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0), Failed = coalesce(Failed, 0)\n    | extend ExecutedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Executed))\n    | extend SucceededDisplay = iff(not(isValidSelectedMonth), "-", tostring(Succeeded))\n    | extend FailedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Failed))\n    | extend SuccessPctDisplay = iff(not(isValidSelectedMonth) or Executed == 0, "-", FormatSuccessPct(Succeeded, Executed))\n    | project Class, ExecutedDisplay, SucceededDisplay, FailedDisplay, SuccessPctDisplay;\nlet heroLong =\n    heroRows | project Class, Metric = "Executed", Value = ExecutedDisplay, MetricOrder = 1\n    | union (heroRows | project Class, Metric = "Succeeded", Value = SucceededDisplay, MetricOrder = 2)\n    | union (heroRows | project Class, Metric = "Failed", Value = FailedDisplay, MetricOrder = 3)\n    | union (heroRows | project Class, Metric = "Success %", Value = SuccessPctDisplay, MetricOrder = 4);\nheroLong\n| evaluate pivot(Class, take_any(Value), Metric, MetricOrder)\n| order by MetricOrder asc\n| project-away MetricOrder\n| project Metric, ["VM Backup"], ["SQL Full"], ["SQL Differential"], ["SQL Log"]'

// ─── KQL: Six-Month Backup Performance ────────────────────────────────────────
// Month rows x Class columns; each cell is that class's Success % for the
// month ("-" when unavailable or zero executions that month). Same
// melt-then-pivot pattern and column order (VM Backup / SQL Full / SQL
// Differential / SQL Log) as the Hero grid.

var kqlSixMonthGrid = '${execCommonKql}${formatSuccessPctKql}let sixMonthActual =\n    BackupClasses\n    | extend _j = 1\n    | join kind=inner (monthList | extend _j = 1) on _j\n    | project Class, MonthKey, IsValidMonth\n    | join kind=leftouter (execBase | summarize Executed = count(), Succeeded = countif(IsSucceeded) by Class, MonthKey) on Class, MonthKey\n    | project Class, MonthKey, IsValidMonth, Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0);\nlet sixMonthDisplay =\n    sixMonthActual\n    | extend Display = iff(not(IsValidMonth), "-", iff(Executed == 0, "-", FormatSuccessPct(Succeeded, Executed)))\n    | project Class, MonthKey, Display;\nsixMonthDisplay\n| evaluate pivot(Class, take_any(Display), MonthKey)\n| order by MonthKey asc\n| project MonthKey, ["VM Backup"], ["SQL Full"], ["SQL Differential"], ["SQL Log"]'

// ─── KQL: Backup Failures — selected-month exception report ──────────────────
// One row per Failed job, built from the same execBase as the Hero grid, so
// the row count always equals the sum of the Hero grid's own Failed values.
// Columns: Time, Environment, Backup Class, Failure Reason only.
// FormatFailureReason humanizes known JobFailureCode values; any other code
// displays its own raw text rather than being hidden.

var formatFailureReasonKql = 'let FormatFailureReason = (code:string) {\n    case(\n        code =~ "UserErrorOpeningSQLConnection", "Unable to open SQL connection",\n        code =~ "UserErrorOperationFailedTargetSQLServerInSingleUserMode", "SQL Server was in single-user mode",\n        code\n    )\n};\n'

var kqlFailuresGrid = '${execCommonKql}${formatFailureReasonKql}let selectedMonthFailures =\n    execBase\n    | where MonthKey == "{ReportMonth}"\n    | where IsFailed\n    | project Time = JobStartDateTime, Environment, ["Backup Class"] = Class, ["Failure Reason"] = FormatFailureReason(JobFailureCode)\n    | order by Time desc;\nselectedMonthFailures'

// ─── KQL: Protected Estate (current, by Environment) ──────────────────────────
// Latest CoreAzureBackup "BackupItem" record per BackupItemUniqueId
// (arg_max). SQL host count uses ProtectedContainerUniqueId; VM and SQL
// database counts use dcount(BackupItemUniqueId), scoped by
// BackupManagementType. A protected item on an unconfigured subscription is
// excluded (inner join). Zero-filled per configured Environment before the
// Environment selector filters the final rows, so a selection with no
// protected items still shows "0" rather than an absent row.

var kqlInventoryGrid = '${subEnvMapKql}let ConfiguredEnvironments = datatable(Environment:string) [${configuredEnvironmentsKqlBody}];\nlet CoreItemsLatest =\n    CoreAzureBackup\n    | where OperationName == "BackupItem"\n    | summarize arg_max(TimeGenerated, *) by BackupItemUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=inner ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId;\nlet ProtectedVMs = CoreItemsLatest | where BackupManagementType == "IaaSVM";\nlet ProtectedSqlDatabases = CoreItemsLatest | where BackupManagementType == "AzureWorkload";\nlet vmCounts = ProtectedVMs | summarize ProtectedVMs = dcount(BackupItemUniqueId) by Environment;\nlet sqlHostCounts = ProtectedSqlDatabases | summarize SqlHosts = dcount(ProtectedContainerUniqueId) by Environment;\nlet sqlDbCounts = ProtectedSqlDatabases | summarize ProtectedSqlDatabases = dcount(BackupItemUniqueId) by Environment;\nConfiguredEnvironments\n| join kind=leftouter vmCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlHostCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlDbCounts on Environment\n| project-away Environment1\n| extend ProtectedVMs = coalesce(ProtectedVMs, 0), SqlHosts = coalesce(SqlHosts, 0), ProtectedSqlDatabases = coalesce(ProtectedSqlDatabases, 0)\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| order by Environment asc'

// ─── KQL: Backup Policy Evidence (simplified, filtered to agreed policies) ────
// Policy-LEVEL evidence only — never a per-item/database policy assignment
// claim, since AddonAzureBackupPolicy carries no usable item/database
// identity field. Filtered to agreedPolicyNames when non-empty, so unrelated
// built-in/unused policies never clutter this business-facing grid; empty
// allowlist applies no filter.
//
// Schedule/Retention are normalized from raw AddonAzureBackupPolicy text.
// CleanText() takes a string parameter — every call site wraps its source
// column in tostring() first, since several source fields are integer-typed.
// CleanText() strips brace-wrapped array text (e.g. "{Friday}") and
// normalizes the literal "null" text to empty. FormatTime24() converts
// recognized 12-hour clock text to 24-hour "HH:MM UTC" by locating the time
// pattern via regex anywhere in the input (so a date-shaped prefix can't
// corrupt the result), falling back to cleaned raw text + " UTC" when no
// time pattern matches. FormatDays()/DayAbbrev() render a single day by its
// full name and a multi-day list as an abbreviated First-Last range.
// FormatRetentionPart() attaches the correct unit word to each retention
// count.
//
// Backup Type is "SQL Backup" for AzureWorkload, "Management VM" for an
// IaaSVM policy resolved to Environment "mgt", "VM Backup" otherwise. The
// long Azure PolicyName is never shown. Column spelling
// "DiffBackupDaysofTheWeek" (lowercase "of") matches the live schema exactly.
// Subscription resolution is the same standardized expression used by
// Protected Estate.

var kqlPolicyGrid = '${subEnvMapKql}let AgreedPolicyNames = dynamic([${agreedPolicyNamesKqlBody}]);\nlet CleanText = (v:string) {\n    let noBraces = replace_string(replace_string(v, "{", ""), "}", "");\n    iff(isempty(noBraces) or tolower(noBraces) == "null", "", noBraces)\n};\nlet FormatTime24 = (raw:string) {\n    let timePattern = @"([0-9]{1,2}):([0-9]{2}):[0-9]{2}[ ]*(AM|PM)";\n    let hhRaw = extract(timePattern, 1, raw);\n    let mm = extract(timePattern, 2, raw);\n    let ampmPart = toupper(tostring(extract(timePattern, 3, raw)));\n    let hh = toint(hhRaw);\n    let hh24 = case(ampmPart == "PM" and hh != 12, hh + 12, ampmPart == "AM" and hh == 12, 0, hh);\n    let hhStr = iff(hh24 < 10, strcat("0", tostring(hh24)), tostring(hh24));\n    let parsed = strcat(hhStr, ":", mm, " UTC");\n    case(isempty(raw), "", isnotempty(hhRaw) and isnotempty(mm) and isnotempty(ampmPart), parsed, strcat(raw, " UTC"))\n};\nlet DayAbbrev = (day:string) { substring(day, 0, 3) };\nlet FormatDays = (cleanedDays:string) {\n    let dayList = split(cleanedDays, ", ");\n    let dayCount = array_length(dayList);\n    case(\n        isempty(cleanedDays), "",\n        dayCount == 1, cleanedDays,\n        strcat(DayAbbrev(tostring(dayList[0])), "-", DayAbbrev(tostring(dayList[dayCount - 1])))\n    )\n};\nlet FormatRetentionPart = (raw:string, label:string, unit:string) { iff(isempty(raw), "", strcat(iff(strlen(label) > 0, strcat(label, " "), ""), raw, " ", unit)) };\nAddonAzureBackupPolicy\n| where OperationName == "Policy"\n| summarize arg_max(TimeGenerated, *) by PolicyUniqueId\n| extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n| join kind=inner ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| where array_length(AgreedPolicyNames) == 0 or PolicyName in (AgreedPolicyNames)\n| extend BackupType = case(BackupManagementType == "IaaSVM" and Environment == "mgt", "Management VM", BackupManagementType == "IaaSVM", "VM Backup", "SQL Backup")\n| extend CleanFrequency = CleanText(tostring(BackupFrequency))\n| extend CleanDays = FormatDays(CleanText(tostring(BackupDaysOfTheWeek)))\n| extend CleanTime = FormatTime24(CleanText(tostring(BackupTimes)))\n| extend CleanDiffDays = FormatDays(CleanText(tostring(DiffBackupDaysofTheWeek)))\n| extend CleanDiffTime = FormatTime24(CleanText(tostring(DiffBackupTime)))\n| extend CleanLogFreq = CleanText(tostring(LogBackupFrequency))\n| extend VmSchedule = case(\n    isempty(CleanFrequency), "-",\n    CleanFrequency =~ "Weekly" and isnotempty(CleanDays), strcat("Weekly ", CleanDays, iff(isnotempty(CleanTime), strcat(" ", CleanTime), "")),\n    strcat(CleanFrequency, iff(isnotempty(CleanTime), strcat(" ", CleanTime), ""))\n  )\n| extend SqlFullSchedule = iff(isnotempty(CleanDays) or isnotempty(CleanTime), strcat("Full: ", CleanDays, iff(isnotempty(CleanTime), strcat(" ", CleanTime), "")), "")\n| extend SqlDiffSchedule = iff(isnotempty(CleanDiffDays) or isnotempty(CleanDiffTime), strcat("Differential: ", CleanDiffDays, iff(isnotempty(CleanDiffTime), strcat(" ", CleanDiffTime), "")), "")\n| extend SqlLogSchedule = iff(isnotempty(CleanLogFreq), strcat("Log: every ", CleanLogFreq, " minutes"), "")\n| extend _sch0 = ""\n| extend _sch1 = iff(isnotempty(SqlFullSchedule), strcat(_sch0, iff(strlen(_sch0) > 0, "; ", ""), SqlFullSchedule), _sch0)\n| extend _sch2 = iff(isnotempty(SqlDiffSchedule), strcat(_sch1, iff(strlen(_sch1) > 0, "; ", ""), SqlDiffSchedule), _sch1)\n| extend _sch3 = iff(isnotempty(SqlLogSchedule), strcat(_sch2, iff(strlen(_sch2) > 0, "; ", ""), SqlLogSchedule), _sch2)\n| extend SqlScheduleCombined = iff(strlen(_sch3) > 0, _sch3, "-")\n| extend Schedule = iff(BackupType == "SQL Backup", SqlScheduleCombined, VmSchedule)\n| extend RetDaily = FormatRetentionPart(CleanText(tostring(DailyRetentionDuration)), "Daily", "days")\n| extend RetWeekly = FormatRetentionPart(CleanText(tostring(WeeklyRetentionDuration)), "Weekly", "weeks")\n| extend RetMonthly = FormatRetentionPart(CleanText(tostring(MonthlyRetentionDuration)), "Monthly", "months")\n| extend RetYearly = FormatRetentionPart(CleanText(tostring(YearlyRetentionDuration)), "Yearly", "years")\n| extend RetDiff = FormatRetentionPart(CleanText(tostring(DiffBackupRetentionDuration)), "", "days")\n| extend RetLog = FormatRetentionPart(CleanText(tostring(LogBackupRetentionDuration)), "", "days")\n| extend _rs0 = ""\n| extend _rs1 = iff(isnotempty(RetDaily), strcat(_rs0, iff(strlen(_rs0) > 0, "; ", ""), RetDaily), _rs0)\n| extend _rs2 = iff(isnotempty(RetWeekly), strcat(_rs1, iff(strlen(_rs1) > 0, "; ", ""), RetWeekly), _rs1)\n| extend _rs3 = iff(isnotempty(RetMonthly), strcat(_rs2, iff(strlen(_rs2) > 0, "; ", ""), RetMonthly), _rs2)\n| extend _rs4 = iff(isnotempty(RetYearly), strcat(_rs3, iff(strlen(_rs3) > 0, "; ", ""), RetYearly), _rs3)\n| extend RetentionSemi = _rs4\n| extend _rd0 = ""\n| extend _rd1 = iff(isnotempty(RetDaily), strcat(_rd0, iff(strlen(_rd0) > 0, " / ", ""), RetDaily), _rd0)\n| extend _rd2 = iff(isnotempty(RetWeekly), strcat(_rd1, iff(strlen(_rd1) > 0, " / ", ""), RetWeekly), _rd1)\n| extend _rd3 = iff(isnotempty(RetMonthly), strcat(_rd2, iff(strlen(_rd2) > 0, " / ", ""), RetMonthly), _rd2)\n| extend _rd4 = iff(isnotempty(RetYearly), strcat(_rd3, iff(strlen(_rd3) > 0, " / ", ""), RetYearly), _rd3)\n| extend RetentionSlash = _rd4\n| extend SqlFullRetentionSegment = iff(isnotempty(RetentionSlash), strcat("Full: ", RetentionSlash), "")\n| extend SqlDiffRetentionSegment = iff(isnotempty(RetDiff), strcat("Differential: ", RetDiff), "")\n| extend SqlLogRetentionSegment = iff(isnotempty(RetLog), strcat("Log: ", RetLog), "")\n| extend _rc0 = ""\n| extend _rc1 = iff(isnotempty(SqlFullRetentionSegment), strcat(_rc0, iff(strlen(_rc0) > 0, "; ", ""), SqlFullRetentionSegment), _rc0)\n| extend _rc2 = iff(isnotempty(SqlDiffRetentionSegment), strcat(_rc1, iff(strlen(_rc1) > 0, "; ", ""), SqlDiffRetentionSegment), _rc1)\n| extend _rc3 = iff(isnotempty(SqlLogRetentionSegment), strcat(_rc2, iff(strlen(_rc2) > 0, "; ", ""), SqlLogRetentionSegment), _rc2)\n| extend SqlRetentionCombined = iff(strlen(_rc3) > 0, _rc3, "-")\n| extend Retention = iff(BackupType == "SQL Backup", SqlRetentionCombined, iff(strlen(RetentionSemi) > 0, RetentionSemi, "-"))\n| order by Environment asc, PolicyName asc\n| project Environment, ["Backup Type"] = BackupType, Schedule, Retention, State'

// ─── KQL: shared restore/recovery jobs fragment ───────────────────────────────
// AddonAzureBackupJobs rows where JobOperation in ("Restore", "Recovery"),
// deduplicated by JobUniqueId (arg_max). Same standardized subscription
// resolution and "Unmapped" retention (left outer join) as NormalizedJobs.

var restoreJobsKql = '${subEnvMapKql}let RestoreJobs =\n    AddonAzureBackupJobs\n    | where JobOperation in~ ("Restore", "Recovery")\n    | summarize arg_max(TimeGenerated, *) by JobUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=leftouter ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | extend Environment = coalesce(Environment, "Unmapped")\n    | extend MonthKey = format_datetime(startofmonth(JobStartDateTime), "yyyy-MM")\n    | extend IsSucceeded = (JobStatus =~ "Completed" and JobFailureCode =~ "Success")\n    | extend IsFailed = (JobStatus =~ "Failed");\n'

// ─── KQL: Restore Activity — selected-month summary ───────────────────────────
// Metric rows (Executed/Succeeded/Failed) x restore-category columns, where
// categories are derived only from JobOperation values that actually
// occurred that month — never a fixed taxonomy. No restore/recovery evidence
// for the selection means zero rows returned; the item's own noDataMessage
// renders instead of a fabricated all-zero row.

var kqlRestoreActivityGrid = '${restoreJobsKql}let selectedMonthRestoreJobs = RestoreJobs | where "{Environment}" == "All" or Environment == "{Environment}" | where MonthKey == "{ReportMonth}";\nlet restoreCounts = selectedMonthRestoreJobs | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Category = JobOperation;\nlet restoreLong =\n    restoreCounts | project Category, Metric = "Executed", Value = tostring(Executed), MetricOrder = 1\n    | union (restoreCounts | project Category, Metric = "Succeeded", Value = tostring(Succeeded), MetricOrder = 2)\n    | union (restoreCounts | project Category, Metric = "Failed", Value = tostring(Failed), MetricOrder = 3);\nrestoreLong\n| evaluate pivot(Category, take_any(Value), Metric, MetricOrder)\n| order by MetricOrder asc\n| project-away MetricOrder'

// ─── KQL: Restore Details ──────────────────────────────────────────────────────
// One row per restore/recovery job for the selected month/Environment, same
// RestoreJobs base and filters as Restore Activity, so row count reconciles
// with that summary's Executed total. Item/Destination falls back through
// BackupItemFriendlyName -> DatasourceFriendlyName -> RecoveryJobDestination
// -> "-".

var kqlRestoreDetailsGrid = '${restoreJobsKql}let selectedMonthRestoreDetails =\n    RestoreJobs\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | where MonthKey == "{ReportMonth}"\n    | extend Item = case(isnotempty(BackupItemFriendlyName), BackupItemFriendlyName, isnotempty(DatasourceFriendlyName), DatasourceFriendlyName, isnotempty(RecoveryJobDestination), RecoveryJobDestination, "-")\n    | extend FailureReason = iff(IsFailed, JobFailureCode, "-")\n    | project Time = JobStartDateTime, Environment, ["Restore Type"] = JobOperation, ["Item / Destination"] = Item, Status = JobStatus, ["Failure Reason"] = FailureReason\n    | order by Time desc;\nselectedMonthRestoreDetails'

// ─── KQL: hidden "restore data present" parameter query ──────────────────────
// Drives Restore Details' conditionalVisibility below, so a month/Environment
// with no restore/recovery evidence shows only Restore Activity's own
// no-data message, with Restore Details hidden entirely rather than showing
// a second, duplicate message. Same RestoreJobs base and filter as both
// restore grids. Not part of the visible parameter bar (isHiddenWhenLocked).

var kqlRestoreDataPresentQuery = '${restoreJobsKql}RestoreJobs\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| where MonthKey == "{ReportMonth}"\n| count\n| project Value = iff(Count > 0, "Yes", "No")'

// ─── KQL: Environment parameter — dynamic, conditional "Unmapped" choice ──────
// "All" and every configured environment are always offered. "Unmapped" is
// added only when AddonAzureBackupJobs actually contains at least one row
// whose resolved subscription is not configured — never unconditionally.
// Query-backed (not a static list) so this conditional choice can exist only
// when the underlying data exists. "All" is the default via the query's own
// `selected` column.
//
// The Azure Workbook dropdown contract for a query-backed parameter requires
// result columns in exactly this order: value, label, selected — enforced by
// the final `project value, label, selected`.

var kqlEnvironmentParameterQuery = '${subEnvMapKql}let ConfiguredEnvironmentChoices = datatable(EnvChoice:string) [${configuredEnvironmentsKqlBody}];\nlet HasUnmapped = toscalar(\n    AddonAzureBackupJobs\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | summarize by ResolvedSubscriptionId\n    | join kind=leftanti ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | count\n) > 0;\nunion (print EnvChoice = "All"), (ConfiguredEnvironmentChoices), (print EnvChoice = "Unmapped" | where HasUnmapped)\n| extend value = EnvChoice, label = EnvChoice, selected = (EnvChoice == "All")\n| project value, label, selected'

// ─── Workbook content ─────────────────────────────────────────────────────────

// Uniform compact margin applied to every visible item via the documented,
// schema-supported per-item styleSettings.margin property.
var compactItemSpacing = {
  margin: '0px 0px 8px 0px'
}

// Visible section order: Parameters -> Agreed Backup Strategy -> Backup
// Policy Evidence -> Backup Activity -> Backup Failures -> Six-Month Backup
// Performance -> Restore Activity -> Restore Details -> Protected Estate ->
// footer.

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar: Workload -> Report Month -> Environment ─────
    // Also carries one hidden parameter (RestoreDataPresent) used only to
    // drive Restore Details' conditionalVisibility below.
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [

          {
            id: guid(workloadName, 'p-workloadName-backup')
            version: 'KqlParameterItem/1.0'
            name: 'workloadName'
            label: 'Workload'
            type: 1
            isRequired: true
            value: workloadName
          }

          // Report Month: current month + previous 12 completed calendar months
          // (calendar-accurate datetime_add). Default = current month via the
          // query's own `selected` column.
          {
            id: guid(workloadName, 'p-reportMonth-backup')
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

          // Environment: "All" + configured environments, plus a conditional
          // "Unmapped" choice (see kqlEnvironmentParameterQuery above).
          // Default = "All" via the query's own `selected` column.
          {
            id: guid(workloadName, 'p-environment-backup')
            version: 'KqlParameterItem/1.0'
            name: 'Environment'
            label: 'Environment'
            type: 2
            isRequired: false
            query: kqlEnvironmentParameterQuery
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            typeSettings: {
              additionalResourceOptions: []
              showDefault: false
            }
          }

          // Hidden (isHiddenWhenLocked) "Yes"/"No" parameter used only by
          // Restore Details' conditionalVisibility below.
          {
            id: guid(workloadName, 'p-restoreDataPresent-backup')
            version: 'KqlParameterItem/1.0'
            name: 'RestoreDataPresent'
            type: 1
            isRequired: true
            isHiddenWhenLocked: true
            query: kqlRestoreDataPresentQuery
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [workspaceResourceId]
            timeContext: lawQueryTimeContext
          }

        ]
      }
      styleSettings: compactItemSpacing
      name: 'parameters-visible'
    }

    // ── Agreed Backup Strategy (hard-coded, accepted for this MVP) ──────────
    // Hard-coded business configuration, not derived from LAW — represents
    // the agreed strategy; Backup Policy Evidence below shows what is
    // technically configured.
    {
      type: 1
      content: {
        json: '## Agreed Backup Strategy\n\n| Backup workload | Scope | Schedule | Retention |\n|---|---|---|---|\n| VM Backup | mgt | Weekly Friday 22:00 UTC | Instant restore 5 days; Weekly 8 weeks |\n| VM Backup | dev / tst / acc / preprd / prd | Daily 22:00 UTC | Instant restore 1 day; Daily 30 days; Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Full | dev / tst / acc / preprd / prd | Weekly Friday 22:00 UTC | Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Differential | dev / tst / acc / preprd / prd | Monday-Thursday 22:00 UTC | 7 days |\n| SQL Log | dev / tst / acc / preprd / prd | Every 15 minutes | 7 days |\n\n*This is the customer-agreed backup configuration. It does not itself prove technical compliance — see Backup Policy Evidence below for what is actually configured in Azure Backup.*'
      }
      styleSettings: compactItemSpacing
      name: 'text-strategy'
    }

    // ── Backup Policy Evidence ───────────────────────────────────────────────
    // Explicit per-column widths so Schedule/Retention render at a usable
    // width by default.
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlPolicyGrid
        size: 0
        title: 'Backup Policy Evidence'
        noDataMessage: 'No agreed policy definitions found for the selected Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          formatters: [
            { columnMatch: 'Environment',    formatter: 0, formatOptions: { customColumnWidthSetting: '8%' } }
            { columnMatch: 'Backup Type',    formatter: 0, formatOptions: { customColumnWidthSetting: '12%' } }
            { columnMatch: 'Schedule',       formatter: 0, formatOptions: { customColumnWidthSetting: '35%' } }
            { columnMatch: 'Retention',      formatter: 0, formatOptions: { customColumnWidthSetting: '38%' } }
            { columnMatch: 'State',          formatter: 0, formatOptions: { customColumnWidthSetting: '7%' } }
          ]
        }
      }
      styleSettings: compactItemSpacing
      name: 'query-policy-grid'
    }

    // ── Hero grid: Backup Activity for the selected Report Month ────────────
    // Always exactly 4 rows, so Small size is sufficient.
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlHeroGrid
        size: 0
        title: 'Backup Activity — {ReportMonth}'
        noDataMessage: 'No backup activity data returned for the selected Report Month and Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      styleSettings: compactItemSpacing
      name: 'query-hero-grid'
    }

    // ── Backup Failures — exception report ────────────────────────────────────
    // Medium size: row count is real failure data, not a fixed small taxonomy.
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlFailuresGrid
        size: 1
        title: 'Backup Failures — {ReportMonth}'
        noDataMessage: 'No failed backup jobs for the selected month and environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      styleSettings: compactItemSpacing
      name: 'query-failures-grid'
    }

    // ── Six-Month Backup Performance ──────────────────────────────────────────
    // Always exactly 6 rows (one per calendar month in the window).
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlSixMonthGrid
        size: 0
        title: 'Six-Month Backup Performance'
        noDataMessage: 'No backup performance data returned for the selected Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          labelSettings: [
            { columnId: 'MonthKey', label: 'Month' }
          ]
        }
      }
      styleSettings: compactItemSpacing
      name: 'query-six-month-grid'
    }

    // ── Restore Activity — selected-month summary ─────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlRestoreActivityGrid
        size: 0
        title: 'Restore Activity — {ReportMonth}'
        noDataMessage: 'No restore/recovery activity recorded for the selected month and environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      styleSettings: compactItemSpacing
      name: 'query-restore-activity-grid'
    }

    // ── Restore Details — only rendered when restore rows actually exist ────
    // Rendered only when RestoreDataPresent = Yes (conditionalVisibility);
    // otherwise Restore Activity's own no-data message is sufficient.
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlRestoreDetailsGrid
        size: 0
        title: 'Restore Details'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      styleSettings: compactItemSpacing
      conditionalVisibility: {
        parameterName: 'RestoreDataPresent'
        comparison: 'isEqualTo'
        value: 'Yes'
      }
      name: 'query-restore-details-grid'
    }

    // ── Protected Estate ──────────────────────────────────────────────────────
    // One row per configured environment.
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlInventoryGrid
        size: 0
        title: 'Protected Estate'
        noDataMessage: 'No protected items found for the selected Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
        gridSettings: {
          labelSettings: [
            { columnId: 'ProtectedVMs',          label: 'Protected VMs' }
            { columnId: 'SqlHosts',              label: 'SQL Hosts' }
            { columnId: 'ProtectedSqlDatabases', label: 'Protected SQL Databases' }
          ]
        }
      }
      styleSettings: compactItemSpacing
      name: 'query-inventory-grid'
    }

    // ── Footer ─────────────────────────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '---\nSource: Azure Backup diagnostic telemetry in Log Analytics (`AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy`). No Azure Resource Manager, Azure Resource Graph, Cost Management, or Recovery Services API call is made by this report.'
      }
      styleSettings: compactItemSpacing
      name: 'text-footer'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────
// Deterministic name derived from stable configuration inputs only — never
// from workbookDisplayName — so renaming the title never changes resource
// identity.

resource workbook 'microsoft.insights/workbooks@2023-06-01' = {
  name: guid(workloadName, workspaceResourceId, 'backup-restore-workbook')
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

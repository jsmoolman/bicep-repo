metadata description = 'Azure Monitor Workbook — Backup & Restore dashboard for LIMS, reading exclusively from the three existing Azure Backup Log Analytics resource-specific tables (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy). This workbook makes no ARM/Azure Resource Graph/Cost Management/Recovery Services API calls, and creates/modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity resource — it only reads already-flowing diagnostic telemetry as KQL. Content is a concise, business-facing MVP intended for screenshot-driven monthly customer reporting; the underlying data model, subscription resolution, and validity rules are unchanged from the earlier technical revision.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('''Workload/project short code (e.g. "lims"). Used for parameter labelling and as one of the deterministic workbook name/GUID seed inputs (see the resource below). This workbook does not filter any LAW table by a "Project" column — the backup tables have no such column — Environment is instead derived entirely from subscriptionEnvironmentMappings below.''')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name. Free to change without affecting the deterministic resource name.')
param workbookDisplayName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('''Full ARM resource ID of the existing central Log Analytics workspace that already receives Azure Backup diagnostic telemetry (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy) via existing Recovery Services Vault diagnostic settings. This workbook queries those three tables directly and exclusively — it creates no table, no Data Collection Rule, and no diagnostic setting; the diagnostic settings that populate these tables already exist and are entirely outside this workbook's authority.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. The three Azure Backup LAW tables carry no Environment column of their own — every query in this module derives Environment by matching each row''s effective subscription ID against this configuration. This resolution is standardized across all three tables (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy) as ResolvedSubscriptionId = tolower(coalesce(_SubscriptionId, SubscriptionId, extract(...ResourceId...), extract(..._ResourceId...))), joined only to tolower(SubscriptionEnvironmentMap.SubscriptionId) — never a friendly/display name, and never dependent on GUID casing (ARM ResourceId values, and _SubscriptionId itself, may use uppercase subscription GUID text). _SubscriptionId is the primary source everywhere per proven live schema: AddonAzureBackupJobs''s own SubscriptionId column is observed 0% populated while _SubscriptionId is observed 100% populated (11,210/11,210 rows, 6 distinct values); the same 0%/populated pattern is proven for AddonAzureBackupPolicy''s PolicyAssociation rows. For the AddonAzureBackupJobs-driven job/restore grids, a resolved ID not present in this array is never silently discarded: it is retained and labelled Environment = "Unmapped" so it remains visible under Environment = All, filterable on its own once actually present; Protected Estate and Backup Policy Evidence continue to exclude an unmapped subscription''s rows via their existing, unmodified inner-join selection logic (only the subscription-resolution expression feeding that join was standardized).
Known LIMS values are pre-populated in config/nfi/lims/observability/backup-restore-workbook.bicepparam.''')
param subscriptionEnvironmentMappings array = []

@description('''Optional allowlist of exact AddonAzureBackupPolicy PolicyName values to show in the Backup Policy Evidence grid. When empty (the default), no name filter is applied. This parameter exists so the module itself stays environment/workload-neutral (per repository rule: modules must not contain hardcoded environment or workload names) while still allowing a caller — e.g. the LIMS bicepparam file — to restrict the grid to its own agreed policy set and hide unrelated built-in/unused policies (e.g. DefaultPolicy, EnhancedPolicy, HourlyLogBackup) that would otherwise clutter a business-facing view. This is presentation filtering only — it never implies or asserts per-item/database policy assignment (see the Backup Policy Evidence query comment below).''')
param agreedPolicyNames array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Derived configuration (no hard-coded environment names) ─────────────────
// Identical mechanism to modules/observability/cost-management-workbook/main.bicep:
// the set of Environment values shown/zero-filled in grids, and offered in the
// Environment selector, comes only from the caller's subscriptionEnvironmentMappings
// configuration — never a literal list — so this module stays reusable for a
// different project with a different environment set.

var allEnvironmentValues = [for m in subscriptionEnvironmentMappings: m.environment]
var configuredEnvironments = union([], allEnvironmentValues)
var configuredEnvironmentsKqlBody = join(map(configuredEnvironments, e => '"${e}"'), ', ')

// Subscription -> Environment KQL mapping body: one "subscriptionId", "environment"
// pair per configured mapping entry, consumed by every grid below via a shared
// `datatable(SubscriptionId:string, Environment:string) [...]` — the single place
// this repository's SubscriptionId -> Environment configuration is translated into
// KQL.
var subscriptionEnvironmentMapKqlBody = join(map(subscriptionEnvironmentMappings, m => '"${m.subscriptionId}", "${m.environment}"'), ', ')

// Agreed Backup Policy Evidence allowlist -> KQL `dynamic([...])` array body.
// Empty when agreedPolicyNames is empty, which the query below treats as
// "no filter applied" (see kqlPolicyGrid).
var agreedPolicyNamesKqlBody = join(map(agreedPolicyNames, n => '"${n}"'), ', ')

// ─── Explicit LAW query time context ──────────────────────────────────────────
// Every LAW-backed query item below sets this exact 730-day window explicitly via
// `timeContext` rather than relying on any workbook-level default time-range
// control, so the Azure portal time picker can never silently truncate backup
// history — identical rationale and value to the Cost Management workbook.

var lawQueryTimeContext = {
  durationMs: 63072000000
}

// ─── KQL: shared Subscription -> Environment mapping fragment ────────────────
// Prepended to every grid query below that reads a raw backup table.
//
// resolvedSubscriptionIdExpr is the single, standardized subscription
// resolution expression used by EVERY query below that consumes
// AddonAzureBackupJobs, CoreAzureBackup, or AddonAzureBackupPolicy — one
// definition, never a per-table variant. It is a coalesce(...) chain wrapped
// in tolower() so GUID casing can never cause a missed match (ARM ResourceId
// values, and _SubscriptionId itself, may use uppercase GUID text).
// _SubscriptionId is deliberately first, per proven live schema:
//   - AddonAzureBackupJobs: SubscriptionId is observed 0% populated on this
//     table; _SubscriptionId is observed 100% populated (11,210/11,210 rows,
//     6 distinct values).
//   - AddonAzureBackupPolicy's PolicyAssociation rows: the same pattern is
//     proven — _SubscriptionId populated, SubscriptionId empty (261/261 rows).
// SubscriptionId (should it ever be populated for a given table/row) and the
// GUID parsed out of ResourceId/_ResourceId are defensive fallbacks only,
// evaluated in that order, never the primary source.
//
// subscriptionEnvironmentMapJoinKql is the single, standardized join
// right-hand side every one of those queries joins ResolvedSubscriptionId
// against — SubscriptionEnvironmentMap's own SubscriptionId column,
// tolower()-normalized to match, aliased to ResolvedSubscriptionId. Reused
// as-is for inner and leftouter joins alike.

var resolvedSubscriptionIdExpr = 'tolower(coalesce(_SubscriptionId, SubscriptionId, extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, ResourceId), extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, _ResourceId)))'
var subscriptionEnvironmentMapJoinKql = '(SubscriptionEnvironmentMap | project ResolvedSubscriptionId = tolower(SubscriptionId), Environment)'

var subEnvMapKql = 'let SubscriptionEnvironmentMap = datatable(SubscriptionId:string, Environment:string) [${subscriptionEnvironmentMapKqlBody}];\n'

// ─── KQL: shared normalized-jobs fragment (AddonAzureBackupJobs) ─────────────
//
// This is the sole data-access path into AddonAzureBackupJobs for the hero,
// six-month, and failures grids. There is no ARM/Azure Resource Graph/Cost
// Management/Recovery Services API call anywhere in this module.
//
// JobUniqueId defensive normalization (per known telemetry facts, there are
// currently zero duplicate JobUniqueId emissions, but this is applied
// unconditionally): `summarize arg_max(TimeGenerated, *) by JobUniqueId`
// keeps only the newest ingested record per job, exactly as documented by
// Microsoft's own Backup Reports sample queries.
//
// Environment is derived from ResolvedSubscriptionId, tolower()-normalized on
// both sides of the join. This is a LEFT OUTER join, deliberately: a job
// whose ResolvedSubscriptionId is not present in subscriptionEnvironmentMappings
// is retained with Environment coalesced to "Unmapped" rather than silently
// discarded — it stays visible under Environment = All (and is itself
// individually selectable once the Environment parameter's own query below
// detects it exists). A named, configured Environment selection (e.g. "dev")
// still filters to exactly that environment's own configured subscription IDs
// only.
//
// Backup classes (Class column) follow the exact canonical definitions:
//   VM Backup        = BackupManagementType == "IaaSVM" and JobOperation == "Backup"
//   SQL Full         = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Full"
//   SQL Differential = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Differential"
//   SQL Log          = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Log"
// Any job matching none of these (ConfigureBackup and other administrative
// operations) gets Class == "" and is excluded from every grid below that
// groups by Class. IsSucceeded/IsFailed use the exact canonical
// case-insensitive (=~) definitions: Succeeded requires BOTH
// JobStatus =~ "Completed" AND JobFailureCode =~ "Success"; Failed requires
// only JobStatus =~ "Failed". Any other status counts toward Executed but is
// neither Succeeded nor Failed.
//
// MonthKey buckets every job by JobStartDateTime (business event time), never
// TimeGenerated (ingestion time).
//
// TelemetryPresence is the (Environment, MonthKey) pairs that have AT LEAST
// ONE raw job row, of any class, computed live from LAW every render — the
// precise, per-environment/month presence check the six-month window
// fragment below uses to decide IsValidMonth: a month with genuinely zero
// telemetry for that environment/month pair renders Unavailable ("-"), while
// a month WITH telemetry but a genuinely zero metric renders as a real zero.

var normalizedJobsKql = '${subEnvMapKql}let NormalizedJobs =\n    AddonAzureBackupJobs\n    | summarize arg_max(TimeGenerated, *) by JobUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=leftouter ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | extend Environment = coalesce(Environment, "Unmapped")\n    | extend Class = case(\n        BackupManagementType == "IaaSVM" and JobOperation == "Backup", "VM Backup",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Full", "SQL Full",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Differential", "SQL Differential",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Log", "SQL Log",\n        "")\n    | extend IsSucceeded = (JobStatus =~ "Completed" and JobFailureCode =~ "Success")\n    | extend IsFailed = (JobStatus =~ "Failed")\n    | extend MonthKey = format_datetime(startofmonth(JobStartDateTime), "yyyy-MM");\nlet TelemetryPresence = NormalizedJobs | summarize by Environment, MonthKey;\n'

// ─── KQL: shared six-month window fragment ────────────────────────────────────
// Report Month + the five preceding calendar months, calendar-accurate
// (datetime_add), never a 30/60-day approximation.
//
// IsValidMonth is evaluated per (currently selected Environment, month)
// against TelemetryPresence above: when a specific Environment is selected, a
// month is valid only if THAT environment has at least one raw job row that
// month; when Environment = All is selected, a month is valid if ANY
// environment (including "Unmapped") has at least one raw job row that
// month. A month/environment combination with genuinely no source telemetry
// always renders Unavailable ("-"), never a fabricated zero.
// anyInvalidMonth is true whenever any of the six displayed months lacks
// telemetry for the selected Environment.

var monthWindowKql = 'let selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet isCurrentMonth = selectedMonth == startofmonth(now());\nlet telemetryMonthsForSelectedEnvironment =\n    TelemetryPresence\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | summarize by MonthKey;\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (telemetryMonthsForSelectedEnvironment | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\n'

// ─── KQL: shared "current job base" fragment ──────────────────────────────────
// execBase is the single filtered view of NormalizedJobs — tracked classes
// only (Class != ""), selected-Environment only — that both the Hero grid,
// the Six-Month grid, and the Backup Failures grid build on. Using one shared
// base for all three is what guarantees the Backup Failures row count always
// reconciles with the Hero grid's own Failed values: both are derived from
// identical filtering with no divergent dedup/selection logic.
// BackupClasses is the fixed four-class reporting taxonomy — always shown,
// even at zero, because these four classes ARE the reporting taxonomy, not
// observed data.

var execCommonKql = '${normalizedJobsKql}${monthWindowKql}let execBase = NormalizedJobs | where Class != "" | where "{Environment}" == "All" or Environment == "{Environment}";\nlet BackupClasses = datatable(Class:string) ["VM Backup", "SQL Full", "SQL Differential", "SQL Log"];\n'

// ─── KQL: shared Success % formatting helper (Hero + Six-Month grids) ────────
// Exact "100%" (no decimals) is returned ONLY when SucceededCount ==
// ExecutedCount (and the caller has already guaranteed ExecutedCount > 0 —
// this function is never invoked otherwise, exactly like FormatMoney in the
// Cost Management workbook, which likewise renders "-" upstream rather than
// inside the helper). Every other case is rounded to exactly 2 decimal
// places and always padded to 2 digits (e.g. "95.00%", never "95.0%" or a
// bare "95%").
//
// The explicit `capped` guard exists because standard round(x, 2) can round
// a value that is genuinely below 100 UP TO 100.00 — e.g. 99.995 rounds to
// 100.00 — which would silently reintroduce the exact live defect this
// change fixes (a class with real failures/non-successful executions
// displaying "100%"). Whenever rounding would produce >= 100.00 for a
// non-exact match, the displayed value is capped at "99.99%" instead, so
// "100%" can only ever appear when Succeeded literally equals Executed.
// Known live example: SQL Log with 10810 succeeded / 10817 executed must
// display "99.94%", never "100%" (see the fixture-level regression
// assertions recorded in the commit message / operations log for this
// change).

var formatSuccessPctKql = 'let FormatSuccessPct = (SucceededCount:long, ExecutedCount:long) {\n    let isExactMatch = SucceededCount == ExecutedCount;\n    let pct = 100.0 * SucceededCount / ExecutedCount;\n    let rounded = round(pct, 2);\n    let capped = iff(not(isExactMatch) and rounded >= 100.0, 99.99, rounded);\n    let s = tostring(capped);\n    let dotIdx = indexof(s, ".");\n    let wholePart = iff(dotIdx == -1, s, substring(s, 0, dotIdx));\n    let fracRaw = iff(dotIdx == -1, "", substring(s, dotIdx + 1));\n    let fracPadded = case(strlen(fracRaw) == 0, "00", strlen(fracRaw) == 1, strcat(fracRaw, "0"), substring(fracRaw, 0, 2));\n    iff(isExactMatch, "100%", strcat(wholePart, ".", fracPadded, "%"))\n};\n'

// ─── KQL: Hero grid — Backup Activity for the selected Report Month only ─────
//
// Business orientation required: Metric as rows (Executed/Succeeded/Failed/
// Success %/Trend), backup classes as columns (VM Backup/SQL Full/SQL
// Differential/SQL Log) — the opposite orientation from the six-month grid
// below. Built by first computing one row per Class (heroBase, heroRows),
// then "melting" that wide shape into a long (Class, Metric, Value) shape,
// then pivoting Class back out into columns grouped by Metric — the standard
// KQL transpose pattern.
//
// isValidSelectedMonth reuses monthList's own MonthOffset == 0 row (the
// selected Report Month is always monthList's last element) rather than a
// second, independently-computed validity check, so the Hero grid's
// zero-vs-Unavailable decision can never drift out of sync with the
// Six-Month grid's own per-cell validity check.
//
// Zero-vs-Unavailable, exactly as required:
//   - Selected Environment/month has NO telemetry at all (isValidSelectedMonth
//     false): Executed/Succeeded/Failed/Success % all render "-".
//   - Selected Environment/month HAS telemetry but a class had zero executions
//     that month: Executed/Succeeded/Failed render the real "0"; Success %
//     alone renders "-" (0/0 is not a meaningful percentage — never fabricated
//     as "100%", which was the live-observed defect this corrects).
//   - Selected Environment/month HAS telemetry and Executed > 0: all four
//     render real computed values — Success % via FormatSuccessPct (see
//     above), which itself guarantees "100%" can only appear when Succeeded
//     literally equals Executed, never merely due to 2-decimal rounding.
// All four Display fields are derived from the exact same Executed value and
// the exact same isValidSelectedMonth flag in one place, so Success % can
// never show a percentage while the count columns show "-", or vice versa.
//
// Trend reuses the identical OLS-regression definition already proven live
// (current partial month excluded from the regression when Report Month is
// current; "Unavailable" when fewer than the required number of usable
// historical months exist; otherwise Improving/Stable/Degrading via the same
// statistical dead-band). This is unchanged from the prior revision — only
// its presentation (as a row instead of a column) has changed.

var kqlHeroGrid = '${execCommonKql}${formatSuccessPctKql}let selectedMonthCounts = execBase | where MonthKey == "{ReportMonth}" | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Class;\nlet isValidSelectedMonth = toscalar(monthList | where MonthOffset == 0 | project IsValidMonth);\nlet heroBase =\n    BackupClasses\n    | join kind=leftouter selectedMonthCounts on Class\n    | extend Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0), Failed = coalesce(Failed, 0)\n    | extend ExecutedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Executed))\n    | extend SucceededDisplay = iff(not(isValidSelectedMonth), "-", tostring(Succeeded))\n    | extend FailedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Failed))\n    | extend SuccessPctDisplay = iff(not(isValidSelectedMonth) or Executed == 0, "-", FormatSuccessPct(Succeeded, Executed))\n    | project Class, ExecutedDisplay, SucceededDisplay, FailedDisplay, SuccessPctDisplay;\nlet requiredTrendMonths = monthList | where MonthOffset <= iff(isCurrentMonth, -1, 0);\nlet requiredTrendMonthCount = toscalar(requiredTrendMonths | count);\nlet trendMonthList = requiredTrendMonths | order by MonthOffset asc | serialize | extend x = row_number() - 1;\nlet execMonthActual =\n    BackupClasses\n    | extend _j = 1\n    | join kind=inner (monthList | extend _j = 1) on _j\n    | project Class, MonthKey, IsValidMonth\n    | join kind=leftouter (execBase | summarize Executed = count(), Succeeded = countif(IsSucceeded) by Class, MonthKey) on Class, MonthKey\n    | project Class, MonthKey, IsValidMonth, Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0);\nlet trendBase =\n    execMonthActual\n    | where IsValidMonth and Executed > 0\n    | join kind=inner trendMonthList on MonthKey\n    | extend SuccessPctForTrend = 100.0 * Succeeded / Executed\n    | summarize N = count(), SumX = sum(x * 1.0), SumY = sum(SuccessPctForTrend), SumXY = sum(x * 1.0 * SuccessPctForTrend), SumX2 = sum(x * 1.0 * x) by Class\n    | extend Denom = N * SumX2 - SumX * SumX\n    | extend Slope = iff(Denom == 0 or N < 2, 0.0, (N * SumXY - SumX * SumY) / Denom)\n    | extend Trend = case(\n        N < requiredTrendMonthCount, "Unavailable",\n        abs(Slope) < 1.0, "Stable",\n        Slope > 0, "Improving",\n        "Degrading"\n      )\n    | project Class, Trend;\nlet heroRows =\n    heroBase\n    | join kind=leftouter trendBase on Class\n    | extend TrendDisplay = coalesce(Trend, "Unavailable")\n    | project-away Class1;\nlet heroLong =\n    heroRows | project Class, Metric = "Executed", Value = ExecutedDisplay, MetricOrder = 1\n    | union (heroRows | project Class, Metric = "Succeeded", Value = SucceededDisplay, MetricOrder = 2)\n    | union (heroRows | project Class, Metric = "Failed", Value = FailedDisplay, MetricOrder = 3)\n    | union (heroRows | project Class, Metric = "Success %", Value = SuccessPctDisplay, MetricOrder = 4)\n    | union (heroRows | project Class, Metric = "Trend", Value = TrendDisplay, MetricOrder = 5);\nheroLong\n| evaluate pivot(Class, take_any(Value), Metric, MetricOrder)\n| order by MetricOrder asc\n| project-away MetricOrder'

// ─── KQL: Six-Month Backup Performance ────────────────────────────────────────
//
// Business orientation required: Month as rows, backup classes as columns —
// each cell is that class's Success % for that calendar month (never
// Executed/Succeeded/Failed totals, which are available by selecting an
// older Report Month on the Hero grid instead). "-" for a month outside
// available telemetry for the selected Environment, or a valid month with
// zero executions of that class — a 0/0 percentage is not a meaningful
// number. Built with the same melt-then-pivot pattern as the Hero grid,
// pivoting on MonthKey (grouped by Class) instead of Class (grouped by
// Metric).

var kqlSixMonthGrid = '${execCommonKql}${formatSuccessPctKql}let sixMonthActual =\n    BackupClasses\n    | extend _j = 1\n    | join kind=inner (monthList | extend _j = 1) on _j\n    | project Class, MonthKey, IsValidMonth\n    | join kind=leftouter (execBase | summarize Executed = count(), Succeeded = countif(IsSucceeded) by Class, MonthKey) on Class, MonthKey\n    | project Class, MonthKey, IsValidMonth, Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0);\nlet sixMonthDisplay =\n    sixMonthActual\n    | extend Display = iff(not(IsValidMonth), "-", iff(Executed == 0, "-", FormatSuccessPct(Succeeded, Executed)))\n    | project Class, MonthKey, Display;\nsixMonthDisplay\n| evaluate pivot(Class, take_any(Display), MonthKey)\n| order by MonthKey asc'

// ─── KQL: Backup Failures — selected-month exception report ──────────────────
//
// One row per individually FAILED job (canonical Failed definition only),
// built from the exact same execBase used by the Hero grid — the same
// Class != "" / selected-Environment filtering, no divergent dedup — so the
// row count here is guaranteed to equal the sum of the Hero grid's own
// "Failed" values for the same Report Month/Environment selection. Concise,
// business-relevant columns only: technical identifiers (JobUniqueId,
// AdHocOrScheduledJob, the now-redundant JobOperationSubType — already
// encoded in Class — and the always-"Failed" JobStatus) are all dropped.
// Item falls back through BackupItemFriendlyName then DatasourceFriendlyName
// (using isnotempty(), not coalesce(), because an unpopulated LAW string
// column returns "" rather than null — coalesce() alone would not fall
// through on an empty string) to "-" when neither is available, rather than
// ever exposing a long technical unique ID.

var kqlFailuresGrid = '${execCommonKql}let selectedMonthFailures =\n    execBase\n    | where MonthKey == "{ReportMonth}"\n    | where IsFailed\n    | extend Item = case(isnotempty(BackupItemFriendlyName), BackupItemFriendlyName, isnotempty(DatasourceFriendlyName), DatasourceFriendlyName, "-")\n    | project Time = JobStartDateTime, Environment, ["Backup Class"] = Class, ["Backup Item / Datasource"] = Item, ["Failure Reason"] = JobFailureCode\n    | order by Time desc;\nselectedMonthFailures'

// ─── KQL: Protected Estate (current, by Environment) ──────────────────────────
// Uses CoreAzureBackup's "BackupItem" operation only, latest record per
// BackupItemUniqueId via arg_max(TimeGenerated, *) — the canonical current-item
// selection.
//
// SQL host identification uses ProtectedContainerUniqueId — the actual
// protected-item container identity already present in LAW for AzureWorkload
// items (the SQL Server host machine's container record) — never a guess
// parsed out of a database's display name. Protected VMs and protected SQL
// databases are both counted via dcount(BackupItemUniqueId) (the actual
// protected-item identity), scoped by BackupManagementType (IaaSVM vs
// AzureWorkload). None of these three counts are hard-coded; they are computed
// fresh from CoreAzureBackup every time this query runs.
//
// Three independent leftouter joins on "Environment" each independently
// duplicate that join-key column (Kusto behavior) — each is explicitly
// projected away immediately after its own join, before the next join runs,
// so no duplicate ever accumulates or cascades.
//
// Subscription resolution uses the standardized resolvedSubscriptionIdExpr /
// subscriptionEnvironmentMapJoinKql — the inner join is unchanged: a
// protected item on a subscription absent from subscriptionEnvironmentMappings
// is still excluded from this grid.
//
// Environment filtering (Environment = All -> every configured environment;
// a named Environment -> that one row only) is applied as the final step,
// after the zero-fill against every configured environment, so a specific
// Environment selection still shows "0" (not an absent row) when it happens
// to have no protected items.

var kqlInventoryGrid = '${subEnvMapKql}let ConfiguredEnvironments = datatable(Environment:string) [${configuredEnvironmentsKqlBody}];\nlet CoreItemsLatest =\n    CoreAzureBackup\n    | where OperationName == "BackupItem"\n    | summarize arg_max(TimeGenerated, *) by BackupItemUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=inner ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId;\nlet ProtectedVMs = CoreItemsLatest | where BackupManagementType == "IaaSVM";\nlet ProtectedSqlDatabases = CoreItemsLatest | where BackupManagementType == "AzureWorkload";\nlet vmCounts = ProtectedVMs | summarize ProtectedVMs = dcount(BackupItemUniqueId) by Environment;\nlet sqlHostCounts = ProtectedSqlDatabases | summarize SqlHosts = dcount(ProtectedContainerUniqueId) by Environment;\nlet sqlDbCounts = ProtectedSqlDatabases | summarize ProtectedSqlDatabases = dcount(BackupItemUniqueId) by Environment;\nConfiguredEnvironments\n| join kind=leftouter vmCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlHostCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlDbCounts on Environment\n| project-away Environment1\n| extend ProtectedVMs = coalesce(ProtectedVMs, 0), SqlHosts = coalesce(SqlHosts, 0), ProtectedSqlDatabases = coalesce(ProtectedSqlDatabases, 0)\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| order by Environment asc'

// ─── KQL: Backup Policy Evidence (simplified, filtered to agreed policies) ────
//
// Purpose: show that the expected policy definitions actually exist in Azure
// Backup telemetry — policy-LEVEL evidence only. Never a per-item/database
// policy assignment claim (see the SQL Log discussion removed from this
// module: live evidence proved AddonAzureBackupPolicy's PolicyAssociation
// rows carry no usable item/database identity field, so no such correlation
// is attempted anywhere in this module).
//
// Filtered to AgreedPolicyNames (the agreedPolicyNames parameter) when
// non-empty, so unrelated built-in/unused policies (DefaultPolicy,
// EnhancedPolicy, HourlyLogBackup, etc.) never clutter this business-facing
// grid. When agreedPolicyNames is empty (a caller that has not configured an
// allowlist), no name filter is applied — see the parameter's own
// description for why this filtering lives here as a parameter rather than a
// hard-coded LIMS policy-name list inside this reusable module.
//
// Schedule/Retention are built as compact, human-readable strings from
// whichever of the raw AddonAzureBackupPolicy fields are actually populated
// on a given policy row (a single AzureWorkload/SQL policy row typically
// carries Full + Differential + Log schedule/retention fields together, a
// single IaaSVM/VM policy row typically carries only the Full-equivalent
// fields) — every value is wrapped in tostring() defensively, since this
// module has not proven the exact underlying value shape (plain string vs.
// a structured `dynamic` retention-duration object) for every field, so it
// can never crash or silently drop a populated field regardless of its
// actual runtime type. Uses the exact discovered schema spelling
// "DiffBackupDaysofTheWeek" (lowercase "of"), matching Microsoft's own
// published AddonAzureBackupPolicy column reference — NOT
// "DiffBackupDaysOfTheWeek". Subscription resolution uses the standardized
// resolvedSubscriptionIdExpr / subscriptionEnvironmentMapJoinKql, same as
// Protected Estate.

var kqlPolicyGrid = '${subEnvMapKql}let AgreedPolicyNames = dynamic([${agreedPolicyNamesKqlBody}]);\nAddonAzureBackupPolicy\n| where OperationName == "Policy"\n| summarize arg_max(TimeGenerated, *) by PolicyUniqueId\n| extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n| join kind=inner ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| where array_length(AgreedPolicyNames) == 0 or PolicyName in (AgreedPolicyNames)\n| extend BackupType = iff(BackupManagementType == "IaaSVM", "VM Backup", "SQL")\n| extend _s0 = ""\n| extend _s1 = iff(isnotempty(BackupFrequency), strcat(_s0, iff(strlen(_s0) > 0, "; ", ""), "Full: ", tostring(BackupFrequency), iff(isnotempty(BackupDaysOfTheWeek), strcat(" ", tostring(BackupDaysOfTheWeek)), ""), iff(isnotempty(BackupTimes), strcat(" @ ", tostring(BackupTimes)), "")), _s0)\n| extend _s2 = iff(isnotempty(DiffBackupDaysofTheWeek) or isnotempty(DiffBackupTime), strcat(_s1, iff(strlen(_s1) > 0, "; ", ""), "Diff: ", tostring(DiffBackupDaysofTheWeek), iff(isnotempty(DiffBackupTime), strcat(" @ ", tostring(DiffBackupTime)), "")), _s1)\n| extend _s3 = iff(isnotempty(LogBackupFrequency), strcat(_s2, iff(strlen(_s2) > 0, "; ", ""), "Log: every ", tostring(LogBackupFrequency), " min"), _s2)\n| extend Schedule = iff(strlen(_s3) > 0, _s3, "-")\n| extend _r0 = ""\n| extend _r1 = iff(isnotempty(DailyRetentionDuration), strcat(_r0, iff(strlen(_r0) > 0, "; ", ""), "Daily ", tostring(DailyRetentionDuration)), _r0)\n| extend _r2 = iff(isnotempty(WeeklyRetentionDuration), strcat(_r1, iff(strlen(_r1) > 0, "; ", ""), "Weekly ", tostring(WeeklyRetentionDuration)), _r1)\n| extend _r3 = iff(isnotempty(MonthlyRetentionDuration), strcat(_r2, iff(strlen(_r2) > 0, "; ", ""), "Monthly ", tostring(MonthlyRetentionDuration)), _r2)\n| extend _r4 = iff(isnotempty(YearlyRetentionDuration), strcat(_r3, iff(strlen(_r3) > 0, "; ", ""), "Yearly ", tostring(YearlyRetentionDuration)), _r3)\n| extend _r5 = iff(isnotempty(DiffBackupRetentionDuration), strcat(_r4, iff(strlen(_r4) > 0, "; ", ""), "Diff ", tostring(DiffBackupRetentionDuration)), _r4)\n| extend _r6 = iff(isnotempty(LogBackupRetentionDuration), strcat(_r5, iff(strlen(_r5) > 0, "; ", ""), "Log ", tostring(LogBackupRetentionDuration)), _r5)\n| extend Retention = iff(strlen(_r6) > 0, _r6, "-")\n| order by Environment asc, PolicyName asc\n| project Environment, ["Policy / Backup Type"] = strcat(BackupType, " — ", PolicyName), Schedule, Retention, State'

// ─── KQL: shared restore/recovery jobs fragment ───────────────────────────────
// Searches raw AddonAzureBackupJobs directly (not through the Class/Success
// taxonomy above, which is Backup-operation-specific) for
// JobOperation in~ ("Restore", "Recovery") — the already-existing detection
// logic, unchanged. JobUniqueId defensive normalization (arg_max by
// JobUniqueId) is applied here too, for the same reason it is applied to
// NormalizedJobs above — these are rows from the same AddonAzureBackupJobs
// table, so the same defensive, always-applied dedup principle extends
// naturally to restore/recovery rows. Same standardized subscription
// resolution and "Unmapped" retention (left outer join) as NormalizedJobs —
// a restore/recovery job from an unmapped ResolvedSubscriptionId is retained
// and labelled "Unmapped", never silently discarded.

var restoreJobsKql = '${subEnvMapKql}let RestoreJobs =\n    AddonAzureBackupJobs\n    | where JobOperation in~ ("Restore", "Recovery")\n    | summarize arg_max(TimeGenerated, *) by JobUniqueId\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | join kind=leftouter ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | extend Environment = coalesce(Environment, "Unmapped")\n    | extend MonthKey = format_datetime(startofmonth(JobStartDateTime), "yyyy-MM")\n    | extend IsSucceeded = (JobStatus =~ "Completed" and JobFailureCode =~ "Success")\n    | extend IsFailed = (JobStatus =~ "Failed");\n'

// ─── KQL: Restore Activity — selected-month summary ───────────────────────────
//
// Same business pattern as the Hero grid (Metric rows: Executed/Succeeded/
// Failed), but restore CATEGORY columns are derived only from JobOperation
// values that actually occurred in the selected month/Environment — never a
// fixed/fabricated taxonomy, per "only classify restore types that existing
// telemetry can support without guessing". When there is no restore/recovery
// evidence for the selected month/Environment, selectedMonthRestoreJobs (and
// therefore every downstream step) is empty, so this query legitimately
// returns zero rows — the workbook's own noDataMessage (set on the item
// below) renders instead of a fabricated all-zero row; absence of restore
// activity is never treated as a compliance failure.

var kqlRestoreActivityGrid = '${restoreJobsKql}let selectedMonthRestoreJobs = RestoreJobs | where "{Environment}" == "All" or Environment == "{Environment}" | where MonthKey == "{ReportMonth}";\nlet restoreCounts = selectedMonthRestoreJobs | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Category = JobOperation;\nlet restoreLong =\n    restoreCounts | project Category, Metric = "Executed", Value = tostring(Executed), MetricOrder = 1\n    | union (restoreCounts | project Category, Metric = "Succeeded", Value = tostring(Succeeded), MetricOrder = 2)\n    | union (restoreCounts | project Category, Metric = "Failed", Value = tostring(Failed), MetricOrder = 3);\nrestoreLong\n| evaluate pivot(Category, take_any(Value), Metric, MetricOrder)\n| order by MetricOrder asc\n| project-away MetricOrder'

// ─── KQL: Restore Details ──────────────────────────────────────────────────────
// One row per observed restore/recovery job for the selected month/
// Environment — the exact same RestoreJobs base and filters as the Restore
// Activity summary above, so this grid's row count always reconciles with
// the sum of that summary's own "Executed" values. GUIDs and
// implementation-only fields are dropped; Item/Destination falls back
// through BackupItemFriendlyName -> DatasourceFriendlyName ->
// RecoveryJobDestination -> "-", the same isnotempty()-based fallback
// pattern used by the Backup Failures grid.

var kqlRestoreDetailsGrid = '${restoreJobsKql}let selectedMonthRestoreDetails =\n    RestoreJobs\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | where MonthKey == "{ReportMonth}"\n    | extend Item = case(isnotempty(BackupItemFriendlyName), BackupItemFriendlyName, isnotempty(DatasourceFriendlyName), DatasourceFriendlyName, isnotempty(RecoveryJobDestination), RecoveryJobDestination, "-")\n    | extend FailureReason = iff(IsFailed, JobFailureCode, "-")\n    | project Time = JobStartDateTime, Environment, ["Restore Type"] = JobOperation, ["Item / Destination"] = Item, Status = JobStatus, ["Failure Reason"] = FailureReason\n    | order by Time desc;\nselectedMonthRestoreDetails'

// ─── KQL: Environment parameter — dynamic, conditional "Unmapped" choice ──────
// "All" and every configured environment (mgt/dev/tst/acc/preprd/prd for LIMS)
// are always offered. "Unmapped" is a live, conditional third category: it is
// added to the selector's own choices only when AddonAzureBackupJobs actually
// contains at least one row whose resolved subscription is not present in
// subscriptionEnvironmentMappings — never unconditionally, and never as a
// permanent configured environment. This parameter is query-backed (queryType
// 0 against the same LAW workspace) rather than a static jsonData list,
// because a static list cannot express "this choice only exists if the
// underlying data actually exists". "All" remains the default selection via
// the query's own `selected` column.
//
// HasUnmapped resolves ResolvedSubscriptionId via the same standardized
// resolvedSubscriptionIdExpr / subscriptionEnvironmentMapJoinKql as
// NormalizedJobs (_SubscriptionId first, tolower()-normalized) — critically,
// NOT the raw SubscriptionId column, which is proven 0% populated on
// AddonAzureBackupJobs.
//
// The Azure Workbook dropdown contract for a query-backed parameter requires
// its result columns in this EXACT order: value, label, selected. EnvChoice is
// carried through as an internal sort/identity column only and is explicitly
// dropped before the final projection below — the query ends with
// `| project value, label, selected` (bare column names, that exact order).

var kqlEnvironmentParameterQuery = '${subEnvMapKql}let ConfiguredEnvironmentChoices = datatable(EnvChoice:string) [${configuredEnvironmentsKqlBody}];\nlet HasUnmapped = toscalar(\n    AddonAzureBackupJobs\n    | extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n    | summarize by ResolvedSubscriptionId\n    | join kind=leftanti ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n    | count\n) > 0;\nunion (print EnvChoice = "All"), (ConfiguredEnvironmentChoices), (print EnvChoice = "Unmapped" | where HasUnmapped)\n| extend value = EnvChoice, label = EnvChoice, selected = (EnvChoice == "All")\n| project value, label, selected'

// ─── Workbook content ─────────────────────────────────────────────────────────

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar: Workload -> Report Month -> Environment ─────
    // Standardized pattern (shared with the Cost Management workbook).
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

          // Report Month: current month + previous 12 completed calendar months.
          // Calendar-month arithmetic (datetime_add) — never 30d/60d approximation.
          // Default selection uses the query's own `selected` column (true only
          // for MonthOffset == 0, the current month) — never a static
          // `value: 'value::0'` override.
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

          // Environment: "All" + choices derived from
          // subscriptionEnvironmentMappings, plus a live, conditional
          // "Unmapped" choice (see kqlEnvironmentParameterQuery above).
          // Default selection is "All" via the query's own `selected` column.
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

        ]
      }
      name: 'parameters-visible'
    }

    // ── Title + Agreed Backup Strategy (hard-coded, accepted for this MVP) ──
    // The agreed strategy is intentionally hard-coded business configuration,
    // not derived from LAW — it represents what has been agreed with the
    // customer, not what is technically observed (see Backup Policy Evidence
    // immediately below for the technical observation).
    {
      type: 1
      content: {
        json: '# Backup & Restore — {workloadName}\n\n## Agreed Backup Strategy\n\n| Backup workload | Scope | Schedule | Retention |\n|---|---|---|---|\n| VM Backup | mgt | Weekly Friday 22:00 UTC | Instant restore 5 days; Weekly 8 weeks |\n| VM Backup | dev / tst / acc / preprd / prd | Daily 22:00 UTC | Instant restore 1 day; Daily 30 days; Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Full | dev / tst / acc / preprd / prd | Weekly Friday 22:00 UTC | Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Differential | dev / tst / acc / preprd / prd | Monday-Thursday 22:00 UTC | 7 days |\n| SQL Log | dev / tst / acc / preprd / prd | Every 15 minutes | 7 days |\n\n*This is the customer-agreed backup configuration. It does not itself prove technical compliance — see Backup Policy Evidence below for what is actually configured in Azure Backup.*'
      }
      name: 'text-strategy'
    }

    // ── Backup Policy Evidence ───────────────────────────────────────────────
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
      }
      name: 'query-policy-grid'
    }

    // ── Protected Estate ──────────────────────────────────────────────────────
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
      name: 'query-inventory-grid'
    }

    // ── Hero grid: Backup Activity for the selected Report Month ────────────
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
      name: 'query-hero-grid'
    }

    // ── Six-Month Backup Performance ──────────────────────────────────────────
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
      name: 'query-six-month-grid'
    }

    // ── Backup Failures — exception report ────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlFailuresGrid
        size: 0
        title: 'Backup Failures — {ReportMonth}'
        noDataMessage: 'No failed backup jobs for the selected month and environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-failures-grid'
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
      name: 'query-restore-activity-grid'
    }

    // ── Restore Details ────────────────────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlRestoreDetailsGrid
        size: 0
        title: 'Restore Details'
        noDataMessage: 'No restore/recovery activity recorded for the selected month and environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-restore-details-grid'
    }

    // ── Footer ─────────────────────────────────────────────────────────────────
    {
      type: 1
      content: {
        json: '---\nSource: Azure Backup diagnostic telemetry in Log Analytics (`AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy`). No Azure Resource Manager, Azure Resource Graph, Cost Management, or Recovery Services API call is made by this report.'
      }
      name: 'text-footer'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────
// Deterministic name derived from stable configuration inputs only — never from
// workbookDisplayName, so renaming the customer-facing title never changes the
// underlying resource identity. Unchanged from the prior revision — this
// presentation refactor does not touch resource identity.

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

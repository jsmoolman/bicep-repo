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

var monthWindowKql = 'let selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet telemetryMonthsForSelectedEnvironment =\n    TelemetryPresence\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | summarize by MonthKey;\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (telemetryMonthsForSelectedEnvironment | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\n'

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
// Success %), backup classes as columns (VM Backup/SQL Full/SQL
// Differential/SQL Log) — the opposite orientation from the six-month grid
// below. Built by first computing one row per Class (heroRows), then
// "melting" that wide shape into a long (Class, Metric, Value) shape, then
// pivoting Class back out into columns grouped by Metric — the standard KQL
// transpose pattern.
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
// No Trend row (business-presentation MVP decision): the Six-Month Backup
// Performance grid immediately below now provides the historical context
// this grid previously carried via an OLS-regression Trend row. That
// regression computation (requiredTrendMonths/trendMonthList/execMonthActual/
// trendBase and the join that produced TrendDisplay) has been removed
// entirely from this query, not merely hidden from the rendered grid, since
// it became fully unused dead KQL once the Trend row was dropped.
//
// The final explicit `project` enforces the required visible column order —
// VM Backup, SQL Full, SQL Differential, SQL Log — matching the Agreed
// Backup Strategy table above, regardless of the alphabetical/first-seen
// order `evaluate pivot()` would otherwise produce. BackupClasses always
// contributes all four classes into heroRows/heroLong, so all four pivot
// columns are always present for this projection to select.

var kqlHeroGrid = '${execCommonKql}${formatSuccessPctKql}let selectedMonthCounts = execBase | where MonthKey == "{ReportMonth}" | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Class;\nlet isValidSelectedMonth = toscalar(monthList | where MonthOffset == 0 | project IsValidMonth);\nlet heroRows =\n    BackupClasses\n    | join kind=leftouter selectedMonthCounts on Class\n    | extend Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0), Failed = coalesce(Failed, 0)\n    | extend ExecutedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Executed))\n    | extend SucceededDisplay = iff(not(isValidSelectedMonth), "-", tostring(Succeeded))\n    | extend FailedDisplay = iff(not(isValidSelectedMonth), "-", tostring(Failed))\n    | extend SuccessPctDisplay = iff(not(isValidSelectedMonth) or Executed == 0, "-", FormatSuccessPct(Succeeded, Executed))\n    | project Class, ExecutedDisplay, SucceededDisplay, FailedDisplay, SuccessPctDisplay;\nlet heroLong =\n    heroRows | project Class, Metric = "Executed", Value = ExecutedDisplay, MetricOrder = 1\n    | union (heroRows | project Class, Metric = "Succeeded", Value = SucceededDisplay, MetricOrder = 2)\n    | union (heroRows | project Class, Metric = "Failed", Value = FailedDisplay, MetricOrder = 3)\n    | union (heroRows | project Class, Metric = "Success %", Value = SuccessPctDisplay, MetricOrder = 4);\nheroLong\n| evaluate pivot(Class, take_any(Value), Metric, MetricOrder)\n| order by MetricOrder asc\n| project-away MetricOrder\n| project Metric, ["VM Backup"], ["SQL Full"], ["SQL Differential"], ["SQL Log"]'

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
//
// The final explicit `project` enforces the same required visible column
// order as the Hero grid — VM Backup, SQL Full, SQL Differential, SQL Log —
// for the same reason (BackupClasses always contributes all four classes,
// so all four pivot columns are always present to select).

var kqlSixMonthGrid = '${execCommonKql}${formatSuccessPctKql}let sixMonthActual =\n    BackupClasses\n    | extend _j = 1\n    | join kind=inner (monthList | extend _j = 1) on _j\n    | project Class, MonthKey, IsValidMonth\n    | join kind=leftouter (execBase | summarize Executed = count(), Succeeded = countif(IsSucceeded) by Class, MonthKey) on Class, MonthKey\n    | project Class, MonthKey, IsValidMonth, Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0);\nlet sixMonthDisplay =\n    sixMonthActual\n    | extend Display = iff(not(IsValidMonth), "-", iff(Executed == 0, "-", FormatSuccessPct(Succeeded, Executed)))\n    | project Class, MonthKey, Display;\nsixMonthDisplay\n| evaluate pivot(Class, take_any(Display), MonthKey)\n| order by MonthKey asc\n| project MonthKey, ["VM Backup"], ["SQL Full"], ["SQL Differential"], ["SQL Log"]'

// ─── KQL: Backup Failures — selected-month exception report ──────────────────
//
// One row per individually FAILED job (canonical Failed definition only),
// built from the exact same execBase used by the Hero grid — the same
// Class != "" / selected-Environment filtering, no divergent dedup — so the
// row count here is guaranteed to equal the sum of the Hero grid's own
// "Failed" values for the same Report Month/Environment selection. Concise,
// business-relevant columns only: Time, Environment, Backup Class, Failure
// Reason. "Backup Item / Datasource" has been removed from this business
// presentation — it added no reconciliation value versus the Hero grid and
// was frequently "-" in practice; technical identifiers (JobUniqueId,
// AdHocOrScheduledJob, JobOperationSubType — already encoded in Class — and
// the always-"Failed" JobStatus) remain dropped as before.
//
// FormatFailureReason humanizes the two JobFailureCode values proven live to
// date; any other/future code is displayed as its own raw JobFailureCode
// text — never hidden — per "do not hide unknown errors".

var formatFailureReasonKql = 'let FormatFailureReason = (code:string) {\n    case(\n        code =~ "UserErrorOpeningSQLConnection", "Unable to open SQL connection",\n        code =~ "UserErrorOperationFailedTargetSQLServerInSingleUserMode", "SQL Server was in single-user mode",\n        code\n    )\n};\n'

var kqlFailuresGrid = '${execCommonKql}${formatFailureReasonKql}let selectedMonthFailures =\n    execBase\n    | where MonthKey == "{ReportMonth}"\n    | where IsFailed\n    | project Time = JobStartDateTime, Environment, ["Backup Class"] = Class, ["Failure Reason"] = FormatFailureReason(JobFailureCode)\n    | order by Time desc;\nselectedMonthFailures'

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
// Schedule/Retention are normalized into business-readable text from
// whichever of the raw AddonAzureBackupPolicy fields are actually populated
// on a given policy row (a single AzureWorkload/SQL policy row typically
// carries Full + Differential + Log schedule/retention fields together, a
// single IaaSVM/VM policy row typically carries only the Full-equivalent
// fields). CleanText() takes a `string` parameter, never `dynamic` — the
// live schema proves several of these fields (the six retention-duration
// fields and LogBackupFrequency) are integer-typed, and Kusto's dynamic
// cast operator rejects an integer value passed into a `dynamic`-typed
// function parameter ("Cast operator: dynamic casting expects string type
// values"), which is exactly the error observed live. Every call site below
// therefore explicitly wraps its source column in tostring() before calling
// CleanText(...), rather than relying on any implicit argument casting.
// Three proven live raw-data quirks are corrected here, not merely
// passed through:
//   - Array-shaped fields (BackupDaysOfTheWeek, DiffBackupDaysofTheWeek,
//     BackupTimes, DiffBackupTime) render via tostring() as brace-wrapped
//     text, e.g. a single day as "{Friday}" and multiple days as
//     "{Monday}, {Tuesday}, {Wednesday}, {Thursday}" — CleanText() strips
//     every "{"/"}" character rather than assuming array vs. scalar shape.
//   - An unpopulated field (e.g. BackupDaysOfTheWeek on a Daily-frequency
//     policy) is observed to contain the literal four-character text "null",
//     not a true empty value — CleanText() also normalizes that literal
//     text (case-insensitively) to "", so it is never concatenated into the
//     visible string.
//   - BackupTimes/DiffBackupTime render in 12-hour clock text (observed:
//     "10:00:00 PM") — FormatTime24() converts a recognized "H:MM:SS AM/PM"
//     shape to 24-hour "HH:MM UTC" (e.g. "22:00 UTC"); anything not matching
//     that exact recognized shape falls back to the cleaned raw text with
//     " UTC" appended, per "fall back to readable raw content rather than
//     dropping the row" — it is never dropped or left brace-wrapped.
// FormatDays()/DayAbbrev() render a single configured day using its full
// name (e.g. "Friday", matching the Agreed Backup Strategy's own wording)
// and a multi-day list as an abbreviated First-Last range (e.g. the proven
// live four-day Monday-Thursday differential list becomes "Mon-Thu") —
// abbreviation via substring(day, 0, 3), which is correct for all seven
// English weekday names. FormatRetentionPart() attaches the correct unit
// word (days/weeks/months/years) to each raw retention count, which is
// proven to be a plain number with no unit of its own.
//
// Backup Type is "SQL Backup" for any AzureWorkload policy, "Management VM"
// specifically for an IaaSVM policy resolved to the "mgt" Environment (the
// only environment whose Agreed Backup Strategy VM schedule differs — weekly
// vs. daily — from every other environment's VM policy), and "VM Backup" for
// every other IaaSVM policy. The long Azure PolicyName is never included in
// the visible output — see the parameter's own description for why it
// remains available for internal allowlist filtering/sort order only.
//
// Uses the exact discovered schema spelling "DiffBackupDaysofTheWeek"
// (lowercase "of"), matching Microsoft's own published AddonAzureBackupPolicy
// column reference — NOT "DiffBackupDaysOfTheWeek". Subscription resolution
// uses the standardized resolvedSubscriptionIdExpr /
// subscriptionEnvironmentMapJoinKql, same as Protected Estate.
//
// If a policy's raw values do not match any of the shapes above (e.g. an
// unrecognized future field format), the incremental string-building below
// degrades to whatever cleaned/partial text it can assemble rather than
// ever throwing or silently dropping the row — consistent with "fall back
// to readable raw content rather than dropping the row".

var kqlPolicyGrid = '${subEnvMapKql}let AgreedPolicyNames = dynamic([${agreedPolicyNamesKqlBody}]);\nlet CleanText = (v:string) {\n    let noBraces = replace_string(replace_string(v, "{", ""), "}", "");\n    iff(isempty(noBraces) or tolower(noBraces) == "null", "", noBraces)\n};\nlet FormatTime24 = (raw:string) {\n    let looksLikeSimpleTime = strlen(raw) > 0 and countof(raw, ":") == 2 and not(raw contains ",") and (raw endswith "AM" or raw endswith "PM");\n    let parts = split(raw, " ");\n    let timePart = tostring(parts[0]);\n    let ampmPart = toupper(tostring(parts[1]));\n    let timeParts = split(timePart, ":");\n    let hh = toint(tostring(timeParts[0]));\n    let mm = tostring(timeParts[1]);\n    let hh24 = case(ampmPart == "PM" and hh != 12, hh + 12, ampmPart == "AM" and hh == 12, 0, hh);\n    let hhStr = iff(hh24 < 10, strcat("0", tostring(hh24)), tostring(hh24));\n    let parsed = strcat(hhStr, ":", mm, " UTC");\n    case(isempty(raw), "", looksLikeSimpleTime, parsed, strcat(raw, " UTC"))\n};\nlet DayAbbrev = (day:string) { substring(day, 0, 3) };\nlet FormatDays = (cleanedDays:string) {\n    let dayList = split(cleanedDays, ", ");\n    let dayCount = array_length(dayList);\n    case(\n        isempty(cleanedDays), "",\n        dayCount == 1, cleanedDays,\n        strcat(DayAbbrev(tostring(dayList[0])), "-", DayAbbrev(tostring(dayList[dayCount - 1])))\n    )\n};\nlet FormatRetentionPart = (raw:string, label:string, unit:string) { iff(isempty(raw), "", strcat(iff(strlen(label) > 0, strcat(label, " "), ""), raw, " ", unit)) };\nAddonAzureBackupPolicy\n| where OperationName == "Policy"\n| summarize arg_max(TimeGenerated, *) by PolicyUniqueId\n| extend ResolvedSubscriptionId = ${resolvedSubscriptionIdExpr}\n| join kind=inner ${subscriptionEnvironmentMapJoinKql} on ResolvedSubscriptionId\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| where array_length(AgreedPolicyNames) == 0 or PolicyName in (AgreedPolicyNames)\n| extend BackupType = case(BackupManagementType == "IaaSVM" and Environment == "mgt", "Management VM", BackupManagementType == "IaaSVM", "VM Backup", "SQL Backup")\n| extend CleanFrequency = CleanText(tostring(BackupFrequency))\n| extend CleanDays = FormatDays(CleanText(tostring(BackupDaysOfTheWeek)))\n| extend CleanTime = FormatTime24(CleanText(tostring(BackupTimes)))\n| extend CleanDiffDays = FormatDays(CleanText(tostring(DiffBackupDaysofTheWeek)))\n| extend CleanDiffTime = FormatTime24(CleanText(tostring(DiffBackupTime)))\n| extend CleanLogFreq = CleanText(tostring(LogBackupFrequency))\n| extend VmSchedule = case(\n    isempty(CleanFrequency), "-",\n    CleanFrequency =~ "Weekly" and isnotempty(CleanDays), strcat("Weekly ", CleanDays, iff(isnotempty(CleanTime), strcat(" ", CleanTime), "")),\n    strcat(CleanFrequency, iff(isnotempty(CleanTime), strcat(" ", CleanTime), ""))\n  )\n| extend SqlFullSchedule = iff(isnotempty(CleanDays) or isnotempty(CleanTime), strcat("Full: ", CleanDays, iff(isnotempty(CleanTime), strcat(" ", CleanTime), "")), "")\n| extend SqlDiffSchedule = iff(isnotempty(CleanDiffDays) or isnotempty(CleanDiffTime), strcat("Differential: ", CleanDiffDays, iff(isnotempty(CleanDiffTime), strcat(" ", CleanDiffTime), "")), "")\n| extend SqlLogSchedule = iff(isnotempty(CleanLogFreq), strcat("Log: every ", CleanLogFreq, " minutes"), "")\n| extend _sch0 = ""\n| extend _sch1 = iff(isnotempty(SqlFullSchedule), strcat(_sch0, iff(strlen(_sch0) > 0, "; ", ""), SqlFullSchedule), _sch0)\n| extend _sch2 = iff(isnotempty(SqlDiffSchedule), strcat(_sch1, iff(strlen(_sch1) > 0, "; ", ""), SqlDiffSchedule), _sch1)\n| extend _sch3 = iff(isnotempty(SqlLogSchedule), strcat(_sch2, iff(strlen(_sch2) > 0, "; ", ""), SqlLogSchedule), _sch2)\n| extend SqlScheduleCombined = iff(strlen(_sch3) > 0, _sch3, "-")\n| extend Schedule = iff(BackupType == "SQL Backup", SqlScheduleCombined, VmSchedule)\n| extend RetDaily = FormatRetentionPart(CleanText(tostring(DailyRetentionDuration)), "Daily", "days")\n| extend RetWeekly = FormatRetentionPart(CleanText(tostring(WeeklyRetentionDuration)), "Weekly", "weeks")\n| extend RetMonthly = FormatRetentionPart(CleanText(tostring(MonthlyRetentionDuration)), "Monthly", "months")\n| extend RetYearly = FormatRetentionPart(CleanText(tostring(YearlyRetentionDuration)), "Yearly", "years")\n| extend RetDiff = FormatRetentionPart(CleanText(tostring(DiffBackupRetentionDuration)), "", "days")\n| extend RetLog = FormatRetentionPart(CleanText(tostring(LogBackupRetentionDuration)), "", "days")\n| extend _rs0 = ""\n| extend _rs1 = iff(isnotempty(RetDaily), strcat(_rs0, iff(strlen(_rs0) > 0, "; ", ""), RetDaily), _rs0)\n| extend _rs2 = iff(isnotempty(RetWeekly), strcat(_rs1, iff(strlen(_rs1) > 0, "; ", ""), RetWeekly), _rs1)\n| extend _rs3 = iff(isnotempty(RetMonthly), strcat(_rs2, iff(strlen(_rs2) > 0, "; ", ""), RetMonthly), _rs2)\n| extend _rs4 = iff(isnotempty(RetYearly), strcat(_rs3, iff(strlen(_rs3) > 0, "; ", ""), RetYearly), _rs3)\n| extend RetentionSemi = _rs4\n| extend _rd0 = ""\n| extend _rd1 = iff(isnotempty(RetDaily), strcat(_rd0, iff(strlen(_rd0) > 0, " / ", ""), RetDaily), _rd0)\n| extend _rd2 = iff(isnotempty(RetWeekly), strcat(_rd1, iff(strlen(_rd1) > 0, " / ", ""), RetWeekly), _rd1)\n| extend _rd3 = iff(isnotempty(RetMonthly), strcat(_rd2, iff(strlen(_rd2) > 0, " / ", ""), RetMonthly), _rd2)\n| extend _rd4 = iff(isnotempty(RetYearly), strcat(_rd3, iff(strlen(_rd3) > 0, " / ", ""), RetYearly), _rd3)\n| extend RetentionSlash = _rd4\n| extend SqlFullRetentionSegment = iff(isnotempty(RetentionSlash), strcat("Full: ", RetentionSlash), "")\n| extend SqlDiffRetentionSegment = iff(isnotempty(RetDiff), strcat("Differential: ", RetDiff), "")\n| extend SqlLogRetentionSegment = iff(isnotempty(RetLog), strcat("Log: ", RetLog), "")\n| extend _rc0 = ""\n| extend _rc1 = iff(isnotempty(SqlFullRetentionSegment), strcat(_rc0, iff(strlen(_rc0) > 0, "; ", ""), SqlFullRetentionSegment), _rc0)\n| extend _rc2 = iff(isnotempty(SqlDiffRetentionSegment), strcat(_rc1, iff(strlen(_rc1) > 0, "; ", ""), SqlDiffRetentionSegment), _rc1)\n| extend _rc3 = iff(isnotempty(SqlLogRetentionSegment), strcat(_rc2, iff(strlen(_rc2) > 0, "; ", ""), SqlLogRetentionSegment), _rc2)\n| extend SqlRetentionCombined = iff(strlen(_rc3) > 0, _rc3, "-")\n| extend Retention = iff(BackupType == "SQL Backup", SqlRetentionCombined, iff(strlen(RetentionSemi) > 0, RetentionSemi, "-"))\n| order by Environment asc, PolicyName asc\n| project Environment, ["Backup Type"] = BackupType, Schedule, Retention, State'

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

// ─── KQL: hidden "restore data present" parameter query ──────────────────────
// Drives the Restore Details item's conditionalVisibility below, so a
// selected month/Environment with no restore/recovery evidence shows the
// Restore Activity summary's single no-data message only — Restore Details
// is hidden entirely (its own query never runs — see Azure Workbooks
// conditional-visibility semantics) rather than also rendering a second,
// duplicate no-data message. This is the same RestoreJobs base and the same
// month/Environment filter as both restore grids above, so visibility can
// never disagree with what Restore Activity/Restore Details would otherwise
// show. No new data source: still AddonAzureBackupJobs only.
//
// This parameter is intentionally NOT part of the visible parameter bar —
// it is declared inside the same top parameters item as workloadName/
// ReportMonth/Environment, marked isHiddenWhenLocked so it is invisible in
// normal (locked/reading) mode, the mode this workbook is always viewed in
// once deployed.

var kqlRestoreDataPresentQuery = '${restoreJobsKql}RestoreJobs\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| where MonthKey == "{ReportMonth}"\n| count\n| project Value = iff(Count > 0, "Yes", "No")'

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

// Uniform, tight inter-item spacing for this screenshot-driven MVP — every
// visible item below sets the same small explicit margin via the
// documented, schema-supported per-item `styleSettings.margin` property
// (https://github.com/Microsoft/Application-Insights-Workbooks schema
// `definitions/styleSettings`), so sections visually follow each other
// compactly without clipping any grid row or introducing scrolling. No
// unsupported/invented workbook JSON property is used.
var compactItemSpacing = {
  margin: '0px 0px 8px 0px'
}

// ─── Workbook content ─────────────────────────────────────────────────────────
//
// Visible section order (business narrative, per this revision): Parameters
// -> Agreed Backup Strategy -> Backup Policy Evidence -> Backup Activity ->
// Backup Failures -> Six-Month Backup Performance -> Restore Activity ->
// Restore Details -> Protected Estate -> footer. Protected Estate has moved
// to immediately before the footer (previously right after Policy
// Evidence); every other item's own query/logic is unchanged — only order,
// spacing, and the items documented above (Policy Evidence, Hero, Failures,
// Restore Details visibility) changed in this revision.

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar: Workload -> Report Month -> Environment ─────
    // Standardized pattern (shared with the Cost Management workbook). Also
    // carries one hidden, non-visible parameter (RestoreDataPresent) used
    // only to drive Restore Details' conditionalVisibility below.
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

          // Hidden (isHiddenWhenLocked): "Yes"/"No" text parameter, never
          // shown in the visible parameter bar in normal reading mode, used
          // only by Restore Details' conditionalVisibility below — see
          // kqlRestoreDataPresentQuery's own comment for why this is the
          // preferred mechanism over a duplicate no-data message.
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
    // The agreed strategy is intentionally hard-coded business configuration,
    // not derived from LAW — it represents what has been agreed with the
    // customer, not what is technically observed (see Backup Policy Evidence
    // immediately below for the technical observation). The workbook's own
    // display name already identifies it as "Backup & Restore" (shown above
    // the parameter bar), so this text starts directly at "## Agreed Backup
    // Strategy" rather than repeating a large redundant title heading.
    {
      type: 1
      content: {
        json: '## Agreed Backup Strategy\n\n| Backup workload | Scope | Schedule | Retention |\n|---|---|---|---|\n| VM Backup | mgt | Weekly Friday 22:00 UTC | Instant restore 5 days; Weekly 8 weeks |\n| VM Backup | dev / tst / acc / preprd / prd | Daily 22:00 UTC | Instant restore 1 day; Daily 30 days; Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Full | dev / tst / acc / preprd / prd | Weekly Friday 22:00 UTC | Weekly 8 weeks; Monthly 6 months; Yearly 3 years |\n| SQL Differential | dev / tst / acc / preprd / prd | Monday-Thursday 22:00 UTC | 7 days |\n| SQL Log | dev / tst / acc / preprd / prd | Every 15 minutes | 7 days |\n\n*This is the customer-agreed backup configuration. It does not itself prove technical compliance — see Backup Policy Evidence below for what is actually configured in Azure Backup.*'
      }
      styleSettings: compactItemSpacing
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
      styleSettings: compactItemSpacing
      name: 'query-policy-grid'
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
      styleSettings: compactItemSpacing
      name: 'query-hero-grid'
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
      styleSettings: compactItemSpacing
      name: 'query-failures-grid'
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
    // conditionalVisibility (documented Azure Workbooks item property) hides
    // this item — and skips running its query entirely — whenever the hidden
    // RestoreDataPresent parameter above resolves to "No" for the selected
    // Report Month/Environment, so a month with no restore/recovery evidence
    // shows the Restore Activity summary's single no-data message only, with
    // no second, duplicate message and no space consumed by this item at all.
    // When restore data DOES exist, this item renders normally and its row
    // count reconciles with Restore Activity's own Executed total (same
    // RestoreJobs base and filters).
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

    // ── Protected Estate — moved to immediately before the footer ───────────
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

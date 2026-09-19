metadata description = 'Azure Monitor Workbook — Backup & Restore dashboard for LIMS, reading exclusively from the three existing Azure Backup Log Analytics resource-specific tables (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy). This workbook makes no ARM/Azure Resource Graph/Cost Management/Recovery Services API calls, and creates/modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity resource — it only reads already-flowing diagnostic telemetry as KQL.'

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

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. The three Azure Backup LAW tables carry no Environment column of their own — every query in this module derives Environment strictly by matching each row''s own SubscriptionId (or, where a table''s SubscriptionId field is not populated, the subscription segment parsed out of its own ResourceId column — never a friendly/display name) against this configuration. For the raw job-telemetry grids (Execution, Failures, SQL Log Continuity, Restore/Recovery), a SubscriptionId not present in this array is never silently discarded: it is retained and labelled Environment = "Unmapped" so it remains visible under Environment = All, filterable on its own once actually present. Protection Inventory and Backup Policy Configuration are unchanged and continue to exclude an unmapped subscription''s rows, matching their existing, unmodified selection logic.
Known LIMS values are pre-populated in config/nfi/lims/observability/backup-restore-workbook.bicepparam.''')
param subscriptionEnvironmentMappings array = []

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
// KQL, mirroring how CostManagementSnapshot_CL rows already had Environment written
// by the collector; these raw backup tables do not, so every grid must derive it.
var subscriptionEnvironmentMapKqlBody = join(map(subscriptionEnvironmentMappings, m => '"${m.subscriptionId}", "${m.environment}"'), ', ')

// ─── Explicit LAW query time context ──────────────────────────────────────────
// Every LAW-backed query item below sets this exact 730-day window explicitly via
// `timeContext` rather than relying on any workbook-level default time-range
// control, so the Azure portal time picker can never silently truncate backup
// history — identical rationale and value to the Cost Management workbook.

var lawQueryTimeContext = {
  durationMs: 63072000000
}

// ─── KQL: shared Subscription -> Environment mapping fragment ────────────────
// Prepended to every grid query below that reads a raw backup table. Also used,
// via a `coalesce(SubscriptionId, extract(...))` pattern in the fragments that
// consume it, as a defensive fallback for the two tables (CoreAzureBackup,
// AddonAzureBackupPolicy) whose SubscriptionId column is documented as
// Backup-vault-specific: if it is unpopulated for a Recovery Services vault row,
// the subscription GUID is parsed out of that row's own ResourceId column
// instead (the same "split/parse a real ARM resource ID" pattern already used by
// src/observability/cost-management-data-foundation/main.bicep to derive a
// subscription ID from workspaceResourceId) — never a friendly name.

var subEnvMapKql = 'let SubscriptionEnvironmentMap = datatable(SubscriptionId:string, Environment:string) [${subscriptionEnvironmentMapKqlBody}];\n'

// ─── KQL: shared normalized-jobs fragment (AddonAzureBackupJobs) ─────────────
//
// This is the sole data-access path into AddonAzureBackupJobs for the execution,
// failures, and SQL Log continuity grids. There is no ARM/Azure Resource Graph/
// Cost Management/Recovery Services API call anywhere in this module.
//
// JobUniqueId defensive normalization (per known telemetry facts, there are
// currently zero duplicate JobUniqueId emissions, but this is applied
// unconditionally, not only when duplicates are observed): `summarize
// arg_max(TimeGenerated, *) by JobUniqueId` keeps only the newest ingested
// record per job, exactly as documented by Microsoft's own Backup Reports
// sample queries.
//
// Environment is derived from SubscriptionId only (see subEnvMapKql above),
// never from a resource/VM/vault name. This is a LEFT OUTER join, deliberately:
// a job whose SubscriptionId is not present in subscriptionEnvironmentMappings
// is NEVER silently discarded here — it is retained with Environment coalesced
// to the literal "Unmapped", so it stays visible under Environment = All (and
// is itself individually selectable once the Environment parameter's own query
// below detects it exists) rather than disappearing without a trace. A named,
// configured Environment selection (e.g. "dev") still filters to exactly that
// environment's own configured subscription IDs only — "Unmapped" rows never
// leak into a named environment's results, because Environment is compared for
// exact equality, and "Unmapped" is never itself added to
// subscriptionEnvironmentMappings. (Protection Inventory and Backup Policy
// Configuration are explicitly out of scope for this behavior and are
// unchanged — they still use an inner join and still exclude an unmapped
// subscription's rows, matching their existing, unmodified selection logic.)
//
// Backup classes (Class column) follow the exact canonical definitions supplied:
//   VM Backup        = BackupManagementType == "IaaSVM" and JobOperation == "Backup"
//   SQL Full         = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Full"
//   SQL Differential = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Differential"
//   SQL Log          = BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Log"
// Any job that matches none of these (ConfigureBackup and other administrative
// operations, in particular) gets Class == "" and is excluded from every grid
// below that groups by Class — it is never silently counted as a successful
// backup. IsSucceeded/IsFailed use the exact canonical case-insensitive (=~)
// definitions supplied: Succeeded requires BOTH JobStatus =~ "Completed" AND
// JobFailureCode =~ "Success"; Failed requires only JobStatus =~ "Failed". A job
// with any other JobStatus (e.g. an in-progress or "CompletedWithWarnings" job)
// is neither Succeeded nor Failed — it still counts toward Executed, so it is
// never silently reclassified as a success.
//
// MonthKey buckets every job by JobStartDateTime (the actual business event
// time), never by TimeGenerated (ingestion time) — consistent with "Use
// JobStartDateTime for gap analysis, not ingestion TimeGenerated" applied
// uniformly, not only in the SQL Log continuity grid.
//
// TelemetryPresence is the (Environment, MonthKey) pairs that have AT LEAST ONE
// raw job row, of any class (even Class == ""), computed live from LAW every
// render, never hard-coded and never a single global date bound. This is the
// precise, per-environment/month presence check the six-month window fragment
// below uses to decide IsValidMonth for whichever Environment is currently
// selected — a month with genuinely zero telemetry for that environment/month
// pair renders Unavailable, while a month WITH telemetry but a genuinely zero
// metric (e.g. zero failures) renders as a real zero, never Unavailable.

var normalizedJobsKql = '${subEnvMapKql}let NormalizedJobs =\n    AddonAzureBackupJobs\n    | summarize arg_max(TimeGenerated, *) by JobUniqueId\n    | join kind=leftouter (SubscriptionEnvironmentMap) on SubscriptionId\n    | extend Environment = coalesce(Environment, "Unmapped")\n    | extend Class = case(\n        BackupManagementType == "IaaSVM" and JobOperation == "Backup", "VM Backup",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Full", "SQL Full",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Differential", "SQL Differential",\n        BackupManagementType == "AzureWorkload" and JobOperation == "Backup" and JobOperationSubType == "Log", "SQL Log",\n        "")\n    | extend IsSucceeded = (JobStatus =~ "Completed" and JobFailureCode =~ "Success")\n    | extend IsFailed = (JobStatus =~ "Failed")\n    | extend MonthKey = format_datetime(startofmonth(JobStartDateTime), "yyyy-MM");\nlet TelemetryPresence = NormalizedJobs | summarize by Environment, MonthKey;\n'

// ─── KQL: shared six-month window fragment ────────────────────────────────────
// Identical structure and rationale to modules/observability/cost-management-workbook/main.bicep:
// Report Month + the five preceding calendar months, calendar-accurate
// (datetime_add), never a 30/60-day approximation.
//
// IsValidMonth is evaluated per (currently selected Environment, month) against
// TelemetryPresence above, not against a single global earliest-telemetry date:
// when a specific Environment is selected, a month is valid only if THAT
// environment has at least one raw job row that month; when Environment = All
// is selected, a month is valid if ANY environment (including "Unmapped") has
// at least one raw job row that month. This means a month/environment
// combination with genuinely no source telemetry always renders Unavailable
// ("-"), never a fabricated zero — while a month/environment that DOES have
// telemetry, but whose calculated metric is genuinely zero (e.g. zero failed
// jobs), still renders that real zero, because zero-vs-Unavailable is decided
// by presence-of-telemetry, never by the metric's own value. This automatically
// still yields Unavailable for every calendar month before telemetry existed
// for any environment (currently September 2026), with no hard-coded date.
// anyInvalidMonth is true whenever any of the six displayed months lacks
// telemetry for the selected Environment — every Total/aggregate column below
// renders "-" rather than silently summing only the valid months and
// presenting an incomplete total as complete.

var monthWindowKql = 'let selectedMonth = startofmonth(todatetime(strcat("{ReportMonth}", "-01")));\nlet isCurrentMonth = selectedMonth == startofmonth(now());\nlet telemetryMonthsForSelectedEnvironment =\n    TelemetryPresence\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | summarize by MonthKey;\nlet monthList =\n    range MonthOffset from -5 to 0 step 1\n    | extend MonthStart = datetime_add("month", MonthOffset, selectedMonth)\n    | extend MonthKey = format_datetime(MonthStart, "yyyy-MM")\n    | extend IsValidMonth = MonthKey in (telemetryMonthsForSelectedEnvironment | project MonthKey);\nlet anyInvalidMonth = toscalar(monthList | summarize InvalidMonths = countif(not(IsValidMonth))) > 0;\n'

// ─── KQL: Section B — Backup Execution six-month pivot (with Trend) ──────────
// Rows: the four fixed backup classes (VM Backup, SQL Full, SQL Differential,
// SQL Log) — always shown, even at zero, unlike a dynamically-discovered row
// list, because these four classes are the reporting taxonomy itself, not
// observed data. Columns: six calendar months (each cell = Success % for that
// month, "-" for a pre-telemetry month or a valid month with zero executions of
// that class — a 0/0 percentage is not a meaningful number), Trend, and
// Total-of-window Executed/Succeeded/Failed/Success % counts (each "-" whenever
// anyInvalidMonth, for the same "never present an incomplete total as complete"
// reason as the Cost Management workbook).
//
// Trend (v1, operational — NOT the Cost workbook's cost-specific bands):
// ordinary least-squares linear regression of that class's monthly Success %
// over the required trend months only (current partial month excluded when
// Report Month is current, exactly as in the Cost workbook). A required month
// only counts as usable regression input when it is BOTH IsValidMonth AND has
// at least one execution of that class that month (Executed > 0) — a month with
// zero executions has an undefined success rate, not a real data point. If
// fewer usable months exist than required, Trend is "Unavailable" ("insufficient
// valid historical months", per the supplied v1 rule) — the trend is never
// computed by treating a missing/undefined month as 0% or 100%. Otherwise the
// slope (percentage points of Success % per month) is classified with a small,
// explicitly-labelled statistical dead-band (not a business SLA threshold, and
// none has been supplied): |slope| < 1.0 percentage point/month -> "Stable";
// slope > 0 -> "Improving" (success rate trending up); slope < 0 -> "Degrading".
// These labels are deliberately operational, never the Cost workbook's
// currency-specific "Strong Upward"/"Mild Upward" bands.
//
// Two chained joins on "Class" below (execPivot x totals, then that result x
// trendBase) each independently duplicate the join-key column with a numeric
// suffix — Kusto's join operator does this even when the key name is identical
// on both sides (proven by the Cost Management workbook's own Environment1/
// ServiceName1/ServiceName2 fix). Both are explicitly projected away so the
// only class-identity column in the final grid output is "Class".

var kqlExecutionGrid = '${normalizedJobsKql}${monthWindowKql}let execBase = NormalizedJobs | where Class != "" | where "{Environment}" == "All" or Environment == "{Environment}";\nlet BackupClasses = datatable(Class:string) ["VM Backup", "SQL Full", "SQL Differential", "SQL Log"];\nlet execMonthGrid = BackupClasses | extend _j=1 | join kind=inner (monthList | extend _j=1) on _j | project Class, MonthKey, IsValidMonth;\nlet execMonthActual =\n    execMonthGrid\n    | join kind=leftouter (execBase | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Class, MonthKey) on Class, MonthKey\n    | project Class, MonthKey, IsValidMonth, Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0), Failed = coalesce(Failed, 0);\nlet execPivotSrc =\n    execMonthActual\n    | extend Display = iff(not(IsValidMonth), "-", iff(Executed == 0, "-", strcat(tostring(toint(round(100.0 * Succeeded / Executed, 0))), "%")))\n    | project Class, MonthKey, Display;\nlet execPivot = execPivotSrc | evaluate pivot(MonthKey, take_any(Display), Class);\nlet windowJobs = execBase | where MonthKey in (monthList | project MonthKey);\nlet totals =\n    BackupClasses\n    | join kind=leftouter (windowJobs | summarize Executed = count(), Succeeded = countif(IsSucceeded), Failed = countif(IsFailed) by Class) on Class\n    | extend Executed = coalesce(Executed, 0), Succeeded = coalesce(Succeeded, 0), Failed = coalesce(Failed, 0)\n    | extend SuccessPctVal = iff(Executed > 0, round(100.0 * Succeeded / Executed, 0), real(null))\n    | extend ExecutedDisplay = iff(anyInvalidMonth, "-", tostring(Executed))\n    | extend SucceededDisplay = iff(anyInvalidMonth, "-", tostring(Succeeded))\n    | extend FailedDisplay = iff(anyInvalidMonth, "-", tostring(Failed))\n    | extend SuccessPctDisplay = iff(anyInvalidMonth or Executed == 0, "-", strcat(tostring(toint(SuccessPctVal)), "%"))\n    | project Class, ExecutedDisplay, SucceededDisplay, FailedDisplay, SuccessPctDisplay;\nlet requiredTrendMonths = monthList | where MonthOffset <= iff(isCurrentMonth, -1, 0);\nlet requiredTrendMonthCount = toscalar(requiredTrendMonths | count);\nlet trendMonthList = requiredTrendMonths | order by MonthOffset asc | serialize | extend x = row_number() - 1;\nlet trendBase =\n    execMonthActual\n    | where IsValidMonth and Executed > 0\n    | join kind=inner trendMonthList on MonthKey\n    | extend SuccessPctForTrend = 100.0 * Succeeded / Executed\n    | summarize N = count(), SumX = sum(x * 1.0), SumY = sum(SuccessPctForTrend), SumXY = sum(x * 1.0 * SuccessPctForTrend), SumX2 = sum(x * 1.0 * x) by Class\n    | extend Denom = N * SumX2 - SumX * SumX\n    | extend Slope = iff(Denom == 0 or N < 2, 0.0, (N * SumXY - SumX * SumY) / Denom)\n    | extend Trend = case(\n        N < requiredTrendMonthCount, "Unavailable",\n        abs(Slope) < 1.0, "Stable",\n        Slope > 0, "Improving",\n        "Degrading"\n      )\n    | project Class, Trend;\nlet execRows =\n    execPivot\n    | join kind=leftouter totals on Class\n    | join kind=leftouter trendBase on Class\n    | extend Trend = coalesce(Trend, "Unavailable")\n    | project-away Class1, Class2;\nexecRows\n| order by Class asc'

// ─── KQL: Section C — Backup failures (selected-month detail) ────────────────
// Selected-month-only detail grid of individually FAILED jobs (canonical
// Failed definition only — not "any non-success"), restricted to the four
// tracked backup classes (ConfigureBackup and other administrative operations
// are, by construction, Class == "" and therefore excluded here too, matching
// their exclusion from the Execution grid's success metrics). Sorted newest
// failure first. Known observed SQL Log failure codes
// (UserErrorOpeningSQLConnection, UserErrorOperationFailedTargetSQLServerInSingleUserMode)
// are NOT hard-coded anywhere below — JobFailureCode is projected as-is, so any
// actual value LAW returns is shown. DatasourceFriendlyName is projected as-is
// and may be empty for Recovery Services vault-sourced jobs (documented as a
// Backup-vault-specific field) — BackupItemFriendlyName is the field
// consistently populated for Recovery Services vaults.

var kqlFailuresGrid = '${normalizedJobsKql}let selectedMonthFailures =\n    NormalizedJobs\n    | where Class != ""\n    | where "{Environment}" == "All" or Environment == "{Environment}"\n    | where MonthKey == "{ReportMonth}"\n    | where IsFailed\n    | project JobStartDateTime, Environment, Class, BackupItemFriendlyName, DatasourceFriendlyName, JobOperationSubType, JobStatus, JobFailureCode, AdHocOrScheduledJob, JobUniqueId\n    | order by JobStartDateTime desc;\nselectedMonthFailures'

// ─── KQL: Section D — Protection inventory (current, live-calculated) ────────
// Uses CoreAzureBackup's "BackupItem" operation only, latest record per
// BackupItemUniqueId via arg_max(TimeGenerated, *) — the canonical current-item
// selection. Not filtered by the Environment selector (it always shows every
// configured environment as a row, at zero if it has no protected items, e.g.
// mgt today) — it is itself the per-Environment breakdown.
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
// duplicate that join-key column (same Kusto behavior noted above) — each is
// explicitly projected away immediately after its own join, before the next
// join runs, so no duplicate ever accumulates or cascades.

var kqlInventoryGrid = '${subEnvMapKql}let ConfiguredEnvironments = datatable(Environment:string) [${configuredEnvironmentsKqlBody}];\nlet CoreItemsLatest =\n    CoreAzureBackup\n    | where OperationName == "BackupItem"\n    | summarize arg_max(TimeGenerated, *) by BackupItemUniqueId\n    | extend ResolvedSubscriptionId = coalesce(SubscriptionId, extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, ResourceId))\n    | join kind=inner (SubscriptionEnvironmentMap | project ResolvedSubscriptionId = SubscriptionId, Environment) on ResolvedSubscriptionId;\nlet ProtectedVMs = CoreItemsLatest | where BackupManagementType == "IaaSVM";\nlet ProtectedSqlDatabases = CoreItemsLatest | where BackupManagementType == "AzureWorkload";\nlet vmCounts = ProtectedVMs | summarize ProtectedVMs = dcount(BackupItemUniqueId) by Environment;\nlet sqlHostCounts = ProtectedSqlDatabases | summarize SqlHosts = dcount(ProtectedContainerUniqueId) by Environment;\nlet sqlDbCounts = ProtectedSqlDatabases | summarize ProtectedSqlDatabases = dcount(BackupItemUniqueId) by Environment;\nConfiguredEnvironments\n| join kind=leftouter vmCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlHostCounts on Environment\n| project-away Environment1\n| join kind=leftouter sqlDbCounts on Environment\n| project-away Environment1\n| extend ProtectedVMs = coalesce(ProtectedVMs, 0), SqlHosts = coalesce(SqlHosts, 0), ProtectedSqlDatabases = coalesce(ProtectedSqlDatabases, 0)\n| order by Environment asc'

// ─── KQL: Section E — Current backup policy configuration ────────────────────
// Latest AddonAzureBackupPolicy "Policy" row per PolicyUniqueId (arg_max).
// Reports the ACTUAL current configuration only — deliberately no
// compliance/pass-fail column, per explicit instruction not to freeze
// policy-compliance rules ahead of an authoritative strategy document. Uses the
// exact discovered schema spelling "DiffBackupDaysofTheWeek" (lowercase "of"),
// matching Microsoft's own published AddonAzureBackupPolicy column reference —
// NOT "DiffBackupDaysOfTheWeek".

var kqlPolicyGrid = '${subEnvMapKql}AddonAzureBackupPolicy\n| where OperationName == "Policy"\n| summarize arg_max(TimeGenerated, *) by PolicyUniqueId\n| extend ResolvedSubscriptionId = coalesce(SubscriptionId, extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, ResourceId))\n| join kind=inner (SubscriptionEnvironmentMap | project ResolvedSubscriptionId = SubscriptionId, Environment) on ResolvedSubscriptionId\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| project Environment, PolicyName, BackupManagementType, PolicySubType, BackupFrequency, BackupDaysOfTheWeek, BackupTimes, DailyRetentionDuration, WeeklyRetentionDaysOfTheWeek, WeeklyRetentionDuration, MonthlyRetentionWeeksOfTheMonth, MonthlyRetentionDaysOfTheWeek, MonthlyRetentionDuration, YearlyRetentionMonthsOfTheYear, YearlyRetentionWeeksOfTheMonth, YearlyRetentionDaysOfTheWeek, YearlyRetentionDuration, DiffBackupDaysofTheWeek, DiffBackupTime, DiffBackupRetentionDuration, LogBackupFrequency, LogBackupRetentionDuration, State\n| order by Environment asc, PolicyName asc'

// ─── KQL: Section F — SQL Log continuity / RPO observation ───────────────────
// Purely observational, per explicit instruction: no invented grace threshold,
// no "RPO compliant" label. Uses successful ("Succeeded") SQL Log jobs only,
// grouped per protected database (BackupItemUniqueId), gap-analysed using
// JobStartDateTime (never TimeGenerated) via prev()-over-serialize, guarded so
// a gap is only computed between two consecutive jobs for the SAME
// BackupItemUniqueId (never bridging two different databases). Configured log
// frequency is joined in "where available" (leftouter) from the protected
// item's own PolicyUniqueId (CoreAzureBackup) -> AddonAzureBackupPolicy's
// LogBackupFrequency — never fabricated when a policy link is absent.

var kqlSqlLogContinuityGrid = '${normalizedJobsKql}let PolicyByPolicyId =\n    AddonAzureBackupPolicy\n    | where OperationName == "Policy"\n    | summarize arg_max(TimeGenerated, *) by PolicyUniqueId\n    | project PolicyUniqueId, LogBackupFrequency;\nlet ItemPolicyMap =\n    CoreAzureBackup\n    | where OperationName == "BackupItem"\n    | summarize arg_max(TimeGenerated, *) by BackupItemUniqueId\n    | where isnotempty(PolicyUniqueId)\n    | join kind=leftouter PolicyByPolicyId on PolicyUniqueId\n    | project BackupItemUniqueId, ConfiguredLogFrequencyMinutes = LogBackupFrequency;\nlet sqlLogJobs = NormalizedJobs | where Class == "SQL Log" | where "{Environment}" == "All" or Environment == "{Environment}";\nlet successfulLogJobs = sqlLogJobs | where IsSucceeded;\nlet gapAnalysis =\n    successfulLogJobs\n    | order by BackupItemUniqueId asc, JobStartDateTime asc\n    | serialize\n    | extend PrevJobStartDateTime = prev(JobStartDateTime, 1), PrevBackupItemUniqueId = prev(BackupItemUniqueId, 1)\n    | extend GapMinutes = iff(PrevBackupItemUniqueId == BackupItemUniqueId, datetime_diff("minute", JobStartDateTime, PrevJobStartDateTime), int(null))\n    | summarize FirstSuccessfulLogJob = min(JobStartDateTime), LastSuccessfulLogJob = max(JobStartDateTime), MaxObservedGapMinutes = max(GapMinutes) by Environment, BackupItemUniqueId, BackupItemFriendlyName;\nlet failedLogJobs = sqlLogJobs | where IsFailed | summarize FailedLogJobs = count(), ObservedFailureCodes = make_set(JobFailureCode, 20) by BackupItemUniqueId;\ngapAnalysis\n| join kind=leftouter failedLogJobs on BackupItemUniqueId\n| join kind=leftouter ItemPolicyMap on BackupItemUniqueId\n| extend FailedLogJobs = coalesce(FailedLogJobs, 0)\n| extend ObservedFailureCodes = tostring(ObservedFailureCodes)\n| project Environment, Database = BackupItemFriendlyName, ConfiguredLogFrequencyMinutes, FirstSuccessfulLogJob, LastSuccessfulLogJob, MaxObservedGapMinutes, FailedLogJobs, ObservedFailureCodes\n| order by Environment asc, Database asc'

// ─── KQL: Section G — Restore / Recovery evidence ─────────────────────────────
// Searches raw AddonAzureBackupJobs directly (not through the Class/Success
// taxonomy above, which is Backup-operation-specific) for JobOperation in~
// ("Restore", "Recovery"). Current discovery found none in available LAW
// history — the grid's own noDataMessage (set on the workbook item below, the
// same standard Azure Workbook mechanism the Cost Management workbook already
// uses for its own no-data case) renders "No restore/recovery evidence in
// available LAW history." when zero rows are returned. This module never
// synthesizes a "0 compliant restore tests" or "restore requirement met/failed"
// message — restore-test compliance is a business/compliance assertion this
// workbook does not make. Also a left outer join, for the same reason as
// NormalizedJobs above: a restore/recovery job from an unmapped SubscriptionId
// is retained and labelled "Unmapped", never silently discarded.

var kqlRestoreGrid = '${subEnvMapKql}AddonAzureBackupJobs\n| where JobOperation in~ ("Restore", "Recovery")\n| extend ResolvedSubscriptionId = coalesce(SubscriptionId, extract(@"/subscriptions/([0-9a-fA-F-]{36})/", 1, ResourceId))\n| join kind=leftouter (SubscriptionEnvironmentMap | project ResolvedSubscriptionId = SubscriptionId, Environment) on ResolvedSubscriptionId\n| extend Environment = coalesce(Environment, "Unmapped")\n| where "{Environment}" == "All" or Environment == "{Environment}"\n| project JobStartDateTime, Environment, BackupManagementType, BackupItemFriendlyName, DatasourceFriendlyName, JobOperation, JobOperationSubType, JobStatus, JobFailureCode, RecoveryJobRPDateTime, RecoveryJobDestination, RecoveryJobRPLocation, JobUniqueId\n| order by JobStartDateTime desc'

// ─── KQL: Telemetry coverage (dynamic, Section A) ─────────────────────────────
// Global fact query (not Environment-filtered — the "known telemetry facts"
// this section documents are workspace-wide), computed live from LAW every time
// the workbook renders, never hard-coded: earliest/latest JobStartDateTime
// (business event time) and TimeGenerated (ingestion time), total job rows, and
// distinct JobUniqueId count (proving the defensive arg_max normalization
// elsewhere is not silently hiding duplicate emissions).

var kqlTelemetryCoverage = 'AddonAzureBackupJobs\n| summarize ["Earliest JobStartDateTime"] = min(JobStartDateTime), ["Latest JobStartDateTime"] = max(JobStartDateTime), ["Earliest TimeGenerated"] = min(TimeGenerated), ["Latest TimeGenerated"] = max(TimeGenerated), ["Total job rows"] = count(), ["Unique JobUniqueId values"] = dcount(JobUniqueId)'

// ─── KQL: Environment parameter — dynamic, conditional "Unmapped" choice ──────
// "All" and every configured environment (mgt/dev/tst/acc/preprd/prd for LIMS)
// are always offered, exactly as before. "Unmapped" is a live, conditional
// third category: it is added to the selector's own choices only when
// AddonAzureBackupJobs actually contains at least one row whose SubscriptionId
// is not present in subscriptionEnvironmentMappings — never unconditionally,
// and never as a permanent configured environment. This is why this parameter
// is now query-backed (queryType 0 against the same LAW workspace) rather than
// a static jsonData list: the previous static list could not express "this
// choice only exists if the underlying data actually exists". "All" remains
// the default selection via the query's own `selected` column — the same
// documented Azure Workbook dropdown-default mechanism the Report Month
// parameter already uses, never a static `value:` override.

var kqlEnvironmentParameterQuery = '${subEnvMapKql}let ConfiguredEnvironmentChoices = datatable(EnvChoice:string) [${configuredEnvironmentsKqlBody}];\nlet HasUnmapped = toscalar(\n    AddonAzureBackupJobs\n    | summarize by SubscriptionId\n    | join kind=leftanti (SubscriptionEnvironmentMap) on SubscriptionId\n    | count\n) > 0;\nunion (print EnvChoice = "All"), (ConfiguredEnvironmentChoices), (print EnvChoice = "Unmapped" | where HasUnmapped)\n| project value = EnvChoice, selected = (EnvChoice == "All")'

// ─── Workbook content ─────────────────────────────────────────────────────────

var workbookContent = {
  version: 'Notebook/1.0'
  items: [

    // ── Visible parameters bar: Workload -> Report Month -> Environment ─────
    // Standardized pattern (shared with the Cost Management workbook, and
    // intended for future workbooks too).
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
          // for MonthOffset == 0, the current month) — the documented Azure
          // Workbook dropdown contract for a query-backed parameter's default
          // value — never a static `value: 'value::0'` override.
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
          // subscriptionEnvironmentMappings, never hard-coded and never
          // inferred from a vault/resource/VM name, PLUS a live, conditional
          // "Unmapped" choice that only appears once AddonAzureBackupJobs
          // actually contains telemetry from a subscription absent from
          // subscriptionEnvironmentMappings (see kqlEnvironmentParameterQuery
          // above) — query-backed so that condition can be evaluated live,
          // never a static jsonData list. Default selection is "All" via the
          // query's own `selected` column, matching the Report Month
          // parameter's convention above.
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

    // ── A. Overview / report definition ──────────────────────────────────────
    {
      type: 1
      content: {
        json: '# Backup & Restore Dashboard — {workloadName}\n\n| | |\n|---|---|\n| **Report month** | {ReportMonth} |\n| **Environment** | {Environment} |\n| **Data source** | `AddonAzureBackupJobs`, `CoreAzureBackup`, `AddonAzureBackupPolicy` (Log Analytics) — existing Azure Backup diagnostic telemetry only; no ARM, Azure Resource Graph, Cost Management, or Recovery Services API call is made by this workbook |\n| **Window** | Report Month and the five preceding calendar months (six columns) where the Execution grid applies a window; the Protection Inventory, Policy Configuration, SQL Log Continuity, and Restore/Recovery grids reflect current/observed state, not a six-month pivot |\n| **Telemetry coverage** | Earliest currently observed job telemetry starts **September 2026** (see the live query below) — calendar months before that have no collected telemetry yet |\n| **Success / failure definition** | Succeeded = `JobStatus =~ "Completed"` and `JobFailureCode =~ "Success"`. Failed = `JobStatus =~ "Failed"`. Any other status counts toward Executed but is neither Succeeded nor Failed — never silently treated as success |\n| **Current-month behaviour** | The current month shows partial, month-to-date data where available; it is always excluded from Trend, never from Executed/Succeeded/Failed totals |\n| **Unavailable vs zero** | A month before available telemetry (or, for a class, a valid month with zero executions) renders "-", never a fabricated "0%" |\n| **Restore/recovery evidence** | Absence of a restore/recovery job is reported as "no evidence in available LAW history" — never as a compliance pass/fail |\n| **Policy compliance** | Not evaluated by this workbook — pending an authoritative strategy document |\n| **Backup resources managed** | None — this workbook only reads existing diagnostic telemetry; it creates/modifies no Recovery Services Vault, backup policy, protected item, diagnostic setting, or RBAC/identity |\n\nLive telemetry coverage (computed fresh from LAW, never hard-coded) is shown in the grid immediately below.'
      }
      name: 'text-overview'
    }

    // ── A (continued). Live telemetry coverage ───────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlTelemetryCoverage
        size: 0
        title: 'Telemetry Coverage (live)'
        noDataMessage: 'AddonAzureBackupJobs has no rows in this workspace.'
        showExportToExcel: false
        showPin: false
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-telemetry-coverage'
    }

    // ── B. Backup Execution — six-month pivot ────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlExecutionGrid
        size: 0
        title: 'Backup Execution'
        noDataMessage: 'No backup execution data returned for the selected Report Month and Environment.'
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
                  { operator: '==', thresholdValue: 'Improving', representation: 'green',     text: '{0}{1}' }
                  { operator: '==', thresholdValue: 'Degrading', representation: 'redBright', text: '{0}{1}' }
                  { operator: 'Default',                         representation: '',          text: '{0}{1}' }
                ]
              }
            }
          ]
          labelSettings: [
            { columnId: 'Class',            label: 'Backup Class' }
            { columnId: 'ExecutedDisplay',  label: 'Executed' }
            { columnId: 'SucceededDisplay', label: 'Succeeded' }
            { columnId: 'FailedDisplay',    label: 'Failed' }
            { columnId: 'SuccessPctDisplay',label: 'Success %' }
            { columnId: 'Trend',            label: 'Trend' }
          ]
        }
      }
      name: 'query-execution-grid'
    }

    // ── C. Backup failures ───────────────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlFailuresGrid
        size: 0
        title: 'Backup Failures — {ReportMonth}'
        noDataMessage: 'No failed backup jobs for the selected Report Month and Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-failures-grid'
    }

    // ── D. Protection inventory ──────────────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlInventoryGrid
        size: 0
        title: 'Protection Inventory (current, by Environment)'
        noDataMessage: 'No protected items found in CoreAzureBackup.'
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

    // ── E. Current backup policy configuration ───────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlPolicyGrid
        size: 0
        title: 'Current Backup Policy Configuration'
        noDataMessage: 'No policy data returned for the selected Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-policy-grid'
    }

    // ── F. SQL Log continuity / RPO observation ──────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlSqlLogContinuityGrid
        size: 0
        title: 'SQL Log Continuity (observed, not a compliance assertion)'
        noDataMessage: 'No successful SQL Log jobs found for the selected Environment.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-sql-log-continuity-grid'
    }

    // ── G. Restore / Recovery evidence ───────────────────────────────────────
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: kqlRestoreGrid
        size: 0
        title: 'Restore / Recovery Evidence'
        noDataMessage: 'No restore/recovery evidence in available LAW history.'
        showExportToExcel: true
        showPin: true
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [workspaceResourceId]
        timeContext: lawQueryTimeContext
      }
      name: 'query-restore-grid'
    }

  ]
}

// ─── Resource ─────────────────────────────────────────────────────────────────
// Deterministic name derived from stable configuration inputs only — never from
// workbookDisplayName, so renaming the customer-facing title never changes the
// underlying resource identity. Deliberately a DIFFERENT seed (and no
// managementGroupId component at all — this workbook has no historical
// management-group query scope) than the Cost Management workbook's GUID, so
// the two workbooks can never collide or be confused with one another.

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

// Parameters for the LIMS Backup & Restore Dashboard.
//
// This workbook reads exclusively from three existing Azure Backup Log
// Analytics resource-specific tables (AddonAzureBackupJobs, CoreAzureBackup,
// AddonAzureBackupPolicy) in the workspace below — populated by existing
// Recovery Services Vault diagnostic settings that are entirely outside this
// repository's authority. This workbook creates no table, DCR, diagnostic
// setting, Recovery Services Vault, backup policy, protected item, or
// RBAC/identity resource — see modules/observability/backup-restore-workbook/main.bicep.
//
// Workbook hosting reuses the existing LIMS reporting resource group/location
// (same as the VM Availability SLA Dashboard v2 and Cost Management Dashboard
// workbooks) — this is a hosting-location decision only and is independent
// from workspaceResourceId below.
using '../../../../src/observability/backup-restore-workbook/main.bicep'

param workloadName = 'lims'

param workbookDisplayName = 'Backup & Restore Dashboard - lims'

// Explicit, independent hosting-subscription decision — this is the AZ-NFI-lims-mgt
// subscription (same one workspaceResourceId below already points at), but it is
// declared here directly rather than derived from workspaceResourceId, so the
// deployment always targets the intended subscription regardless of the Azure
// DevOps service connection's ambient/default subscription context.
param workbookSubscriptionId = 'cd9bed50-c972-49d0-83b0-b97bf801c804'

param workbookResourceGroupName = 'rg-lims-reports-mgmt-westeu'

param location = 'westeurope'

// Existing central Log Analytics workspace that already receives Azure Backup
// diagnostic telemetry (same workspace used by the Cost Management Dashboard
// and VM Availability SLA Dashboard v2 workbooks).
param workspaceResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourcegroups/rg-lims-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

// Same subscription -> environment mapping shape and values already used by
// config/nfi/lims/observability/cost-management-workbook.bicepparam. Every LAW
// row this workbook reads is matched against these subscriptionId values to
// derive Environment — never inferred from a vault/resource/VM name. A
// subscription not listed here is excluded from every grid.
param subscriptionEnvironmentMappings = [
  {
    _comment: 'AZ-NFI-lims-mgt — management / reporting subscription'
    subscriptionId: 'cd9bed50-c972-49d0-83b0-b97bf801c804'
    environment: 'mgt'
  }
  {
    _comment: 'AZ-NFI-lims-dev — development subscription'
    subscriptionId: '8ebb26a1-674a-40d1-97f8-e0a237e288a6'
    environment: 'dev'
  }
  {
    _comment: 'AZ-NFI-lims-tst — test subscription'
    subscriptionId: '1947d5e2-5ca8-4994-8f7d-5c380da19ef9'
    environment: 'tst'
  }
  {
    _comment: 'AZ-NFI-lims-acc — acceptance subscription'
    subscriptionId: 'b29525c8-045f-4793-b3cf-e93b5ff9bf74'
    environment: 'acc'
  }
  {
    _comment: 'AZ-NFI-lims-preprd — pre-production subscription'
    subscriptionId: '3999f5e2-435b-4b07-a28e-005ffe0a5607'
    environment: 'preprd'
  }
  {
    _comment: 'AZ-NFI-lims-prd — production subscription'
    subscriptionId: '786de6c9-1dd2-48d4-8436-1a6565a61799'
    environment: 'prd'
  }
]

// Allowlist for the business-facing Backup Policy Evidence grid — hides
// unrelated built-in/unused Azure Backup policies (DefaultPolicy,
// EnhancedPolicy, HourlyLogBackup, etc.) that would otherwise clutter the
// grid. This is presentation filtering only; it does not assert or imply
// that any specific protected item/database uses a given policy.
param agreedPolicyNames = [
  'backuppolicy-vm-lims-mgmt-westeu-v2'
  'backuppolicy-vm-lims-dev-westeu'
  'backuppolicy-sql-lims-dev-westeu'
  'backuppolicy-vm-lims-tst-westeu'
  'backuppolicy-sql-lims-tst-westeu'
  'backuppolicy-vm-lims-acc-westeu'
  'backuppolicy-sql-lims-acc-westeu'
  'backuppolicy-vm-lims-preprd-westeu'
  'backuppolicy-sql-lims-preprd-westeu'
  'backuppolicy-vm-lims-prd-westeu'
  'backuppolicy-sql-lims-prd-westeu'
]

param tags = {
  environment: 'management'
  purpose: 'lims'
}

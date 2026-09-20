// Example parameters for the Backup & Restore Dashboard — illustrates the
// shape a real deployment's parameter file must provide. Subscription IDs,
// policy names, and resource names below are fictional.
//
// This workbook reads exclusively from three existing Azure Backup Log
// Analytics resource-specific tables (AddonAzureBackupJobs, CoreAzureBackup,
// AddonAzureBackupPolicy) in the workspace below — populated by existing
// Recovery Services Vault diagnostic settings that are entirely outside this
// repository's authority. This workbook creates no table, DCR, diagnostic
// setting, Recovery Services Vault, backup policy, protected item, or
// RBAC/identity resource — see modules/observability/backup-restore-workbook/main.bicep.
using '../../../src/observability/backup-restore-workbook/main.bicep'

param workloadName = 'contoso'

param workbookDisplayName = 'Backup & Restore Dashboard - contoso'

// Declared directly rather than derived from workspaceResourceId, so
// deployment always targets the intended subscription regardless of the
// deployment identity's ambient/default subscription context.
param workbookSubscriptionId = '00000000-0000-0000-0000-000000000001'

param workbookResourceGroupName = 'rg-contoso-reports-mgmt-westeu'

param location = 'westeurope'

// Existing central Log Analytics workspace that already receives Azure Backup
// diagnostic telemetry.
param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-contoso-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-reports-mgmt-westeu'

// Every LAW row this workbook reads is matched against these subscriptionId
// values to derive Environment — never inferred from a vault/resource/VM
// name. A subscription not listed here is excluded from Protected Estate and
// Backup Policy Evidence.
param subscriptionEnvironmentMappings = [
  {
    _comment: 'Management / reporting subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000001'
    environment: 'mgt'
  }
  {
    _comment: 'Development subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000002'
    environment: 'dev'
  }
  {
    _comment: 'Test subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000003'
    environment: 'tst'
  }
  {
    _comment: 'Acceptance subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000004'
    environment: 'acc'
  }
  {
    _comment: 'Pre-production subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000005'
    environment: 'preprd'
  }
  {
    _comment: 'Production subscription'
    subscriptionId: '00000000-0000-0000-0000-000000000006'
    environment: 'prd'
  }
]

// Allowlist for the business-facing Backup Policy Evidence grid — hides
// unrelated built-in/unused Azure Backup policies (DefaultPolicy,
// EnhancedPolicy, HourlyLogBackup, etc.) that would otherwise clutter the
// grid. This is presentation filtering only; it does not assert or imply
// that any specific protected item/database uses a given policy.
param agreedPolicyNames = [
  'backuppolicy-vm-contoso-mgmt-westeu-v2'
  'backuppolicy-vm-contoso-dev-westeu'
  'backuppolicy-sql-contoso-dev-westeu'
  'backuppolicy-vm-contoso-tst-westeu'
  'backuppolicy-sql-contoso-tst-westeu'
  'backuppolicy-vm-contoso-acc-westeu'
  'backuppolicy-sql-contoso-acc-westeu'
  'backuppolicy-vm-contoso-preprd-westeu'
  'backuppolicy-sql-contoso-preprd-westeu'
  'backuppolicy-vm-contoso-prd-westeu'
  'backuppolicy-sql-contoso-prd-westeu'
]

param tags = {
  environment: 'management'
  purpose: 'contoso'
}

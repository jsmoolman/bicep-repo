metadata description = 'Subscription-scoped orchestrator for the Backup & Restore Dashboard Workbook, which reads exclusively from the three existing Azure Backup Log Analytics tables (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy — see modules/observability/backup-restore-workbook/main.bicep). Workbook hosting (subscription/resource group/location) is configured independently from the Log Analytics workspace that hosts those tables — the two are unrelated inputs that happen to coincide only when a project bicepparam file says so.'

targetScope = 'subscription'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Workload/project short code (e.g. "lims"). Drives parameter labelling and the deterministic workbook name/GUID seed (passed through to the module).')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Customer-facing workbook title/display name.')
param workbookDisplayName string

@description('''Subscription ID that hosts the workbook resource group below. An explicit, independent configuration decision — deliberately not derived from workspaceResourceId (that ARM ID identifies an unrelated resource, the Log Analytics workspace this workbook queries) or from the deployment''s ambient/service-connection subscription context, which is not guaranteed to be the intended hosting subscription.''')
param workbookSubscriptionId string

@description('Name of the existing resource group, in the workbookSubscriptionId subscription above, that will host the workbook resource.')
param workbookResourceGroupName string

@description('Azure region for the workbook resource.')
param location string = 'westeurope'

@description('''Full ARM resource ID of the existing central Log Analytics workspace that already receives Azure Backup diagnostic telemetry (AddonAzureBackupJobs, CoreAzureBackup, AddonAzureBackupPolicy) via existing Recovery Services Vault diagnostic settings. This workbook queries those three tables directly and exclusively for all backup/restore reporting.''')
param workspaceResourceId string

@description('''Array of subscription-to-environment mappings. Each element: { subscriptionId: string, environment: string }. Used to derive Environment for every LAW row this workbook reads — the raw backup tables carry no Environment column of their own. Uses the same shape already used by the Cost Management workbook's subscriptionEnvironmentMappings.
Known LIMS values are pre-populated in config/nfi/lims/observability/backup-restore-workbook.bicepparam.''')
param subscriptionEnvironmentMappings array = []

@description('''Optional allowlist of exact AddonAzureBackupPolicy PolicyName values to show in the Backup Policy Evidence grid (passed through to the module unchanged). Empty (default) applies no name filter. See modules/observability/backup-restore-workbook/main.bicep for the full rationale.''')
param agreedPolicyNames array = []

@description('Tags applied to the workbook resource.')
param tags object = {}

// ─── Module ───────────────────────────────────────────────────────────────────

module workbook '../../../modules/observability/backup-restore-workbook/main.bicep' = {
  name: 'backup-restore-workbook-${take(uniqueString(workloadName, workspaceResourceId), 8)}'
  scope: resourceGroup(workbookSubscriptionId, workbookResourceGroupName)
  params: {
    workloadName:                    workloadName
    workbookDisplayName:             workbookDisplayName
    location:                        location
    workspaceResourceId:             workspaceResourceId
    subscriptionEnvironmentMappings: subscriptionEnvironmentMappings
    agreedPolicyNames:               agreedPolicyNames
    tags:                            tags
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed workbook.')
output workbookResourceId string = workbook.outputs.workbookResourceId

@description('GUID name of the deployed workbook resource.')
output workbookName string = workbook.outputs.workbookName

@description('Display name of the deployed workbook.')
output workbookDisplayName string = workbook.outputs.workbookDisplayName

@description('Resource group hosting the workbook.')
output workbookResourceGroupName string = workbookResourceGroupName

@description('''Subscription ID hosting the workbook (deployment diagnostics only — proves the deployment targeted the intended explicit subscription rather than the service connection''s ambient/default one).''')
output workbookSubscriptionId string = workbookSubscriptionId

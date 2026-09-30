// Real ACC parameters for the Change Tracking & Inventory (CTI) policy
// assignment — Microsoft's built-in "Enable ChangeTracking and Inventory for
// virtual machines" initiative, applied to the whole ACC subscription
// (b29525c8-045f-4793-b3cf-e93b5ff9bf74). No notScopes / exclusions: all
// workload subscriptions share the same topology and are intended to have
// CTI.
//
// ACC is the first environment onboarded through repository-controlled IaC;
// the existing preprd pilot's policy assignment was configured manually and
// is not represented here or changed by this configuration.
//
// Policy-assignment/remediation identity: the existing ACC DevOps
// user-assigned managed identity (umi-nfi-lims-acc-devops), already granted
// Owner at the ACC subscription scope. Not created or modified here, and no
// RBAC for it is created or modified here.
using '../../../../src/observability/change-tracking-inventory-policy/main.bicep'

param assignmentName = 'cti-lims-acc'

param location = 'westeurope'

param policyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/92a36f05-ebc9-4bba-9128-b47ad2ea3354'

param displayName = 'Enable ChangeTracking and Inventory for virtual machines'

param enforcementMode = 'Default'

param identityResourceId = '/subscriptions/b29525c8-045f-4793-b3cf-e93b5ff9bf74/resourcegroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/umi-nfi-lims-acc-devops'

param bringYourOwnUserAssignedManagedIdentity = false

param restrictBringYourOwnUserAssignedIdentityToSubscription = true

param builtInIdentityResourceGroupLocation = 'westeurope'

param listOfApplicableLocations = [
  'westeurope'
]

param effect = 'DeployIfNotExists'

param dcrResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourceGroups/rg-lims-reports-mgmt-westeu/providers/Microsoft.Insights/dataCollectionRules/dcr-cti-lims-acc-westeu'

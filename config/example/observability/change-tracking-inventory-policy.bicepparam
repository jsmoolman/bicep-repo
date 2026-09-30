// Example parameters for the Change Tracking & Inventory (CTI) policy
// assignment — Microsoft's built-in "Enable ChangeTracking and Inventory for
// virtual machines" initiative. Subscription ID, resource names, and the
// identity resource ID below are fictional.
//
// This creates only the policy assignment (Microsoft.Authorization/
// policyAssignments) referencing an existing user-assigned managed identity.
// No managed identity, role assignment, VM extension, or DCR association is
// created here — those remain owned by the built-in initiative and its own
// remediation tasks.
using '../../../src/observability/change-tracking-inventory-policy/main.bicep'

param assignmentName = 'cti-example-workload'

param location = 'westeurope'

param policyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/92a36f05-ebc9-4bba-9128-b47ad2ea3354'

param displayName = 'Enable ChangeTracking and Inventory for virtual machines'

param enforcementMode = 'Default'

param identityResourceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourcegroups/rg-example-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/umi-example-workload-devops'

param bringYourOwnUserAssignedManagedIdentity = false

param restrictBringYourOwnUserAssignedIdentityToSubscription = true

param builtInIdentityResourceGroupLocation = 'westeurope'

param listOfApplicableLocations = [
  'westeurope'
]

param effect = 'DeployIfNotExists'

param dcrResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-inventory-westeu/providers/Microsoft.Insights/dataCollectionRules/dcr-cti-example-westeu'

// Example parameters for the Change Tracking & Inventory (CTI) foundation —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription ID and resource names below are fictional.
//
// This creates only the CTI Data Collection Rule and the ChangeTracking
// solution against an existing Log Analytics workspace. No workspace, VM
// extension, DCR association, policy assignment, managed identity, or role
// assignment is created — policy-driven onboarding is a separate, later step.
using '../../../src/observability/change-tracking-inventory-foundation/main.bicep'

param workspaceSubscriptionId = '00000000-0000-0000-0000-000000000001'

param workspaceResourceGroupName = 'rg-example-inventory-westeu'

param workspaceName = 'law-example-inventory-westeu'

param location = 'westeurope'

param dataCollectionRuleName = 'dcr-cti-example-westeu'

param tags = {
  environment: 'management'
  purpose: 'example'
}

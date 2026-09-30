// Real ACC parameters for the Change Tracking & Inventory (CTI) foundation.
// ACC is the first environment onboarded through repository-controlled IaC;
// the existing preprd pilot was configured manually and is not represented
// here or changed by this configuration.
using '../../../../src/observability/change-tracking-inventory-foundation/main.bicep'

param workspaceSubscriptionId = 'cd9bed50-c972-49d0-83b0-b97bf801c804'

param workspaceResourceGroupName = 'rg-lims-reports-mgmt-westeu'

param workspaceName = 'law-inventory-mgmt-westeu'

param location = 'westeurope'

param dataCollectionRuleName = 'dcr-cti-lims-acc-westeu'

param tags = {
  environment: 'management'
  purpose: 'lims'
}

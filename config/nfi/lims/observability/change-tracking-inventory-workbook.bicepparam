using '../../../../src/observability/change-tracking-inventory-workbook/main.bicep'

param workloadName = 'lims'

param workbookDisplayName = 'Change Tracking & Inventory Dashboard - lims'

param workbookSubscriptionId = 'cd9bed50-c972-49d0-83b0-b97bf801c804'

param workbookResourceGroupName = 'rg-lims-reports-mgmt-westeu'

param location = 'westeurope'

// Existing central Log Analytics workspace that already receives CTI
// ConfigurationChange/ConfigurationData telemetry — same workspace targeted
// by config/nfi/lims/observability/change-tracking-inventory-foundation-acc.bicepparam.
param workspaceResourceId = '/subscriptions/cd9bed50-c972-49d0-83b0-b97bf801c804/resourcegroups/rg-lims-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-inventory-mgmt-westeu'

param tags = {
  environment: 'management'
  purpose: 'lims'
}

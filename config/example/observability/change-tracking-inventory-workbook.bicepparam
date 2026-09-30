// Example parameters for the Change Tracking & Inventory (CTI) Dashboard —
// illustrates the shape a real deployment's parameter file must provide.
// Subscription IDs and resource names below are fictional.
//
// This workbook reads exclusively from the existing ConfigurationChange and
// ConfigurationData Log Analytics tables in the workspace below — populated
// by the CTI foundation (modules/observability/change-tracking-inventory-foundation)
// and onboarded via the CTI policy pipeline
// (modules/observability/change-tracking-inventory-policy). This workbook
// creates no DCR, policy assignment, identity, VM extension, DCR
// association, or LAW configuration — see
// modules/observability/change-tracking-inventory-workbook/main.bicep.
using '../../../src/observability/change-tracking-inventory-workbook/main.bicep'

param workloadName = 'contoso'

param workbookDisplayName = 'Change Tracking & Inventory Dashboard - contoso'

// Declared directly rather than derived from workspaceResourceId, so
// deployment always targets the intended subscription regardless of the
// deployment identity's ambient/default subscription context.
param workbookSubscriptionId = '00000000-0000-0000-0000-000000000001'

param workbookResourceGroupName = 'rg-contoso-reports-mgmt-westeu'

param location = 'westeurope'

// Existing central Log Analytics workspace that already receives CTI
// ConfigurationChange/ConfigurationData telemetry from onboarded VMs.
param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-contoso-reports-mgmt-westeu/providers/microsoft.operationalinsights/workspaces/law-inventory-mgmt-westeu'

param tags = {
  environment: 'management'
  purpose: 'contoso'
}

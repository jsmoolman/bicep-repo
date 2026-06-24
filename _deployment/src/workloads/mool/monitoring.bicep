targetScope = 'resourceGroup'

metadata name = 'lims — Monitoring'
metadata description = 'Deploys action groups and metric alerts for lims workload resources.'

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Alert notification email address.')
param alertEmailAddress string = ''

@description('Tags to apply.')
param tags object = {}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-lims-ops'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'limsops'
    enabled: true
    emailReceivers: empty(alertEmailAddress) ? [] : [
      {
        name: 'ops-email'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

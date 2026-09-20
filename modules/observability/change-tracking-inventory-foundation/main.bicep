metadata description = 'Azure Change Tracking & Inventory (CTI) foundation using the Azure Monitor Agent model: a dedicated Data Collection Rule (Windows extension, software/services/inventory only) plus the ChangeTracking solution, both against an existing Log Analytics workspace. Creates no workspace, VM extension, DCR association, policy assignment, managed identity, or role assignment — those are separate, later concerns.'

targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the existing Log Analytics workspace that will receive Change Tracking data. This module must be deployed into the same resource group as this workspace, per the Change Tracking DCR requirement.')
param workspaceName string

@description('Azure region for the Data Collection Rule and the ChangeTracking solution.')
param location string = 'westeurope'

@description('Name of the Data Collection Rule to create, e.g. dcr-cti-example-westeu.')
@minLength(3)
@maxLength(64)
param dataCollectionRuleName string

@description('Tags applied to the Data Collection Rule and the ChangeTracking solution.')
param tags object = {}

// ─── Existing Log Analytics workspace ─────────────────────────────────────────
// Referenced only to obtain its resource ID for the DCR destination and the
// solution's workspaceResourceId property. No workspace-wide property is read
// or written here.

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

// ─── Data Collection Rule ──────────────────────────────────────────────────────
// Shape follows Microsoft's current Change Tracking & Inventory AMA DCR sample
// (CtDcrCreation.json): one Windows extension data source
// (extensionName: ChangeTracking-Windows) carrying all three CTI streams, one
// Log Analytics destination, one data flow. Software, services, and inventory
// collection are enabled with the sample's default frequencies; files and
// registry collection are disabled and carry no custom path/key configuration
// — that stays a later, explicit decision if ever required.

var ctiStreams = [
  'Microsoft-ConfigurationChange'
  'Microsoft-ConfigurationChangeV2'
  'Microsoft-ConfigurationData'
]

var logAnalyticsDestinationName = 'Microsoft-CT-Dest'

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  properties: {
    description: 'Data collection rule for Change Tracking & Inventory (Windows).'
    dataSources: {
      extensions: [
        {
          streams: ctiStreams
          extensionName: 'ChangeTracking-Windows'
          extensionSettings: {
            enableFiles: false
            enableSoftware: true
            enableRegistry: false
            enableServices: true
            enableInventory: true
            softwareSettings: {
              softwareCollectionFrequency: 1800
            }
            servicesSettings: {
              serviceCollectionFrequency: 1800
            }
            inventorySettings: {
              inventoryCollectionFrequency: 36000
            }
          }
          name: 'CTDataSource-Windows'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: logAnalyticsDestinationName
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ctiStreams
        destinations: [
          logAnalyticsDestinationName
        ]
      }
    ]
  }
}

// ─── ChangeTracking solution ────────────────────────────────────────────────
// Microsoft.OperationsManagement/solutions, ChangeTracking(<workspaceName>)
// plan, gallery product OMSGallery/ChangeTracking — the current Microsoft
// Change Tracking solution registration against the same existing workspace.

var changeTrackingSolutionName = 'ChangeTracking(${workspaceName})'

resource changeTrackingSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: changeTrackingSolutionName
  location: location
  tags: tags
  plan: {
    name: changeTrackingSolutionName
    product: 'OMSGallery/ChangeTracking'
    promotionCode: ''
    publisher: 'Microsoft'
  }
  properties: {
    workspaceResourceId: workspace.id
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

@description('Full ARM resource ID of the deployed Data Collection Rule.')
output dataCollectionRuleResourceId string = dcr.id

@description('Immutable ID of the deployed Data Collection Rule.')
output dataCollectionRuleImmutableId string = dcr.properties.immutableId

@description('Full ARM resource ID of the deployed ChangeTracking solution.')
output changeTrackingSolutionResourceId string = changeTrackingSolution.id

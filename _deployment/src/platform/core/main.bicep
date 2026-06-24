targetScope = 'managementGroup'

metadata name = 'Platform Core'
metadata description = 'Deploys management group hierarchy, subscription placements, and root-level policy assignments.'

@description('Prefix used for all management group names.')
param managementGroupPrefix string

@description('Azure region for deployments that require a location.')
param location string = 'westeurope'

@description('Tags to apply to all deployed resources.')
param tags object = {}

// Management group hierarchy
module managementGroups '../../../modules/org/management-groups/main.bicep' = {
  name: 'management-groups'
  params: {
    prefix: managementGroupPrefix
  }
}

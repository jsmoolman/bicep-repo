// =============================================================================
// MODULE: platform/private-dns-vnet-link
// =============================================================================
// PURPOSE
//   Reusable, environment-neutral building block that adds a single Virtual
//   Network Link to an existing Private DNS zone. The caller in src/ is
//   responsible for deciding which zones and which VNets to link.
//
// SCAFFOLDING GUIDE (read this if you are an AI agent extending the repo)
//   This module follows the canonical module pattern in this repository.
//   A module MUST:
//     1. Be reusable and environment-neutral — NO hardcoded environment codes
//        (dev/tst/prd) and NO hardcoded workload or customer names. All such
//        values arrive as parameters from the composition in src/.
//     2. Declare targetScope = 'resourceGroup' — the caller in src/ deploys
//        into the resource group that owns the Private DNS zone.
//     3. Expose a small, explicit parameter contract with @description on every
//        parameter and @minLength / @maxLength guards where applicable.
//     4. Return outputs the composition needs to chain further resources.
//
// AUTHORING LOOKUP CHAIN (mandatory — see bicep-authoring-standards)
//   Before writing or changing resource blocks, ALWAYS run, in order:
//     1. Azure Verified Modules (AVM)  — https://azure.github.io/Azure-Verified-Modules/
//        AVM equivalent: br/public:avm/res/network/private-dns-zone (check for
//        a virtualNetworkLinks sub-module before using this native implementation).
//     2. Bicep Registry source         — https://github.com/Azure/bicep-registry-modules
//     3. Microsoft Learn Bicep docs    — https://learn.microsoft.com/azure/azure-resource-manager/bicep/
//     4. Bicep MCP tools               — get_az_resource_type_schema, get_bicep_best_practices,
//                                         get_bicep_file_diagnostics, format_bicep_file
// =============================================================================

targetScope = 'resourceGroup'

metadata name = 'Platform — Private DNS VNet Link'
metadata description = 'Adds a single Virtual Network Link to an existing Private DNS zone. Reusable, environment-neutral module.'

// -----------------------------------------------------------------------------
// PARAMETERS — the module's public contract.
// Every value that differs between environments or workloads MUST be a parameter.
// -----------------------------------------------------------------------------

@description('Name of the existing Private DNS zone to link from.')
@minLength(1)
@maxLength(253)
param privateDnsZoneName string

@description('Name for the VNet link child resource. Must be unique within the zone.')
@minLength(1)
@maxLength(80)
param linkName string

@description('Full resource ID of the VNet to link. May be in a different subscription from the DNS zone.')
@minLength(1)
param virtualNetworkId string

@description('Tags applied to the VNet link resource.')
param tags object = {}

// -----------------------------------------------------------------------------
// RESOURCES
// -----------------------------------------------------------------------------

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDnsZoneName
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: linkName
  // VNet links must always be 'global' — the location of the linked VNet is irrelevant here.
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

// -----------------------------------------------------------------------------
// OUTPUTS — values the composition in src/ may need to chain further work.
// -----------------------------------------------------------------------------

@description('Resource ID of the VNet link.')
output vnetLinkId string = vnetLink.id

@description('Name of the VNet link resource.')
output vnetLinkName string = vnetLink.name

// =============================================================================
// MODULE: org/entra-groups
// =============================================================================
// PURPOSE
//   Reusable, environment-neutral building block that creates a single
//   Microsoft Entra ID (Azure AD) security group via the Microsoft Graph Bicep
//   extension, with optional owners and members.
//
// SCAFFOLDING GUIDE (read this if you are an AI agent extending the repo)
//   This module deploys an EXTENSION resource (Microsoft.Graph), not an ARM
//   resource. Key differences from a normal module:
//     1. It requires `extension microsoftGraphV1_0` (declared below) and the
//        matching entry in bicepconfig.json under "extensions", plus
//        "experimentalFeaturesEnabled.extensibility": true.
//     2. Microsoft.Graph/groups has NO `location` and does NOT accept Azure
//        `tags` — Entra objects are tenant-global, so neither applies here.
//     3. `uniqueName` is REQUIRED and acts as the idempotency key: re-deploying
//        with the same uniqueName updates the existing group instead of creating
//        a duplicate. Treat it as immutable once deployed.
//     4. Like every module it stays workload/environment-neutral — concrete
//        names, owners, and members arrive as parameters from the composition.
//
// AUTHORING LOOKUP CHAIN (mandatory — see bicep-authoring-standards)
//   1. Microsoft Graph Bicep reference (authoritative for this resource):
//      https://learn.microsoft.com/graph/templates/bicep/reference/groups
//   2. There is currently no AVM module for raw Entra groups; the Graph
//      extension is the recommended approach.
//   3. Run get_bicep_file_diagnostics + format_bicep_file after editing.
//
// PERMISSIONS
//   The deploying identity needs the Microsoft Graph application permission
//   `Group.ReadWrite.All` (or `Directory.ReadWrite.All`). Setting
//   `assignableToRole = true` additionally requires `RoleManagement.ReadWrite.Directory`
//   and the Privileged Role Administrator role.
// =============================================================================

extension microsoftGraphV1_0

// Graph resources are extension resources and not bound to an ARM resource
// group. Declaring subscription scope lets a subscription-scoped composition
// call this module without provisioning a resource group.
targetScope = 'subscription'

metadata name = 'Org — Entra ID Group'
metadata description = 'Reusable module: creates a single Microsoft Entra ID security group with optional owners and members.'

// -----------------------------------------------------------------------------
// PARAMETERS — the module's public contract.
// -----------------------------------------------------------------------------

@description('Immutable unique key for the group, used for idempotent deployments (alternate key). Lowercase, no spaces, e.g. "sg-mool-admins-prd".')
@minLength(1)
@maxLength(120)
param uniqueName string

@description('Human-readable display name shown in the Entra portal. Max 256 characters.')
@minLength(1)
@maxLength(256)
param displayName string

@description('Optional description of the group\'s purpose.')
param groupDescription string = ''

@description('Mail alias for the group. Required by Graph even for security groups; ASCII only, max 64 chars, no @ () / [] ; : <> , or spaces.')
@minLength(1)
@maxLength(64)
param mailNickname string

@description('Object IDs (GUIDs) of users / service principals / groups to set as owners. Empty = no owners managed by this module.')
param ownerObjectIds array = []

@description('Object IDs (GUIDs) of members to add to the group. Empty = no members managed by this module.')
param memberObjectIds array = []

@description('Whether this security group can be assigned to Microsoft Entra roles (requires Entra ID P1; forces visibility = Hidden).')
param assignableToRole bool = false

// -----------------------------------------------------------------------------
// RESOURCE — the Entra security group.
//   Optional blocks (owners/members/visibility) are set to null when not
//   provided so we never send empty relationship collections to Graph.
// -----------------------------------------------------------------------------

resource entraGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  description: empty(groupDescription) ? null : groupDescription
  // Security group (not a Microsoft 365 / mail-enabled group).
  mailEnabled: false
  mailNickname: mailNickname
  securityEnabled: true
  isAssignableToRole: assignableToRole
  // Role-assignable groups must be Hidden; otherwise leave visibility unset.
  visibility: assignableToRole ? 'Hidden' : null
  // relationships is a list of directory object IDs. 'replace' semantics make
  // the deployment authoritative: the template's list becomes the full
  // owner/member set. Use 'append' if you only want to add without removing.
  owners: empty(ownerObjectIds) ? null : { relationships: ownerObjectIds, relationshipSemantics: 'replace' }
  members: empty(memberObjectIds) ? null : { relationships: memberObjectIds, relationshipSemantics: 'replace' }
}

// -----------------------------------------------------------------------------
// OUTPUTS
// -----------------------------------------------------------------------------

@description('The generated object ID (GUID) of the Entra group.')
output groupId string = entraGroup.id

@description('The display name of the Entra group.')
output displayName string = entraGroup.displayName

@description('The immutable unique name (alternate key) of the Entra group.')
output uniqueName string = entraGroup.uniqueName

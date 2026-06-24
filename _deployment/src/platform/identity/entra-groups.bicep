// =============================================================================
// COMPOSITION: Platform Identity — Entra ID Groups
// =============================================================================
// PURPOSE
//   Deployable entry point that provisions one or more Microsoft Entra ID
//   security groups by calling the reusable `modules/org/entra-groups` module
//   once per entry in the `groups` array. Concrete group definitions live in a
//   `.bicepparam` file under `config/` — this composition stays value-free.
//
// SCAFFOLDING GUIDE (read this if you are an AI agent creating identity deployments)
//   1. SCOPE: Entra objects are tenant-global and are NOT tied to a resource
//      group, so this composition deploys at 'subscription' scope and creates no
//      resource group. The Microsoft Graph extension handles the Graph calls.
//      Deploy with `az deployment sub create` (any subscription in the tenant).
//   2. NO Azure naming standard applies to Entra groups (they have a displayName
//      and an immutable uniqueName, not an `rg-...` name). Still keep names
//      consistent — recommended uniqueName pattern: sg-{workload}-{role}-{environment}.
//   3. The composition stays thin: it only fans out over `groups` and delegates
//      all resource logic to the module.
//   4. To manage groups for another environment, copy the param file (not this
//      composition) and change the values.
//
// HOW TO DEPLOY (what-if first, then apply — see deployment-model-standards)
//   az deployment sub create \
//     --location westeurope \
//     --template-file   src/platform/identity/entra-groups.bicep \
//     --parameters      config/nfi/platform/identity-entra-groups.bicepparam \
//     --what-if
//
// REQUIRED PERMISSIONS
//   Deploying identity needs Microsoft Graph `Group.ReadWrite.All`. The standard
//   "apply identity" must be granted this app permission before deployment.
// =============================================================================

targetScope = 'subscription'

metadata name = 'Platform Identity — Entra ID Groups'
metadata description = 'Creates Entra ID security groups defined in config, via the org/entra-groups module.'

// -----------------------------------------------------------------------------
// PARAMETERS
// -----------------------------------------------------------------------------

@description('Environment code. Part of the identity deployment contract (used by pipelines for traceability and environment selection).')
@allowed(['dev', 'tst', 'acc', 'preprd', 'prd', 'mgmt'])
#disable-next-line no-unused-params
param environment string

@description('''
Array of Entra group definitions. Each object:
{
  uniqueName:       string        // immutable idempotency key, e.g. 'sg-lims-admins-prd'
  displayName:      string        // portal display name
  description:      string?       // optional
  mailNickname:     string        // ASCII alias, required by Graph
  ownerObjectIds:   string[]?     // optional owner object IDs
  memberObjectIds:  string[]?     // optional member object IDs
  assignableToRole: bool?         // optional, default false
}
''')
param groups array

// -----------------------------------------------------------------------------
// RESOURCES — one module instance per group definition.
//   getObjectValue-style defaults keep optional fields truly optional in config.
// -----------------------------------------------------------------------------

module entraGroups '../../../modules/org/entra-groups/main.bicep' = [
  for g in groups: {
    name: 'entra-group-${g.uniqueName}'
    params: {
      uniqueName: g.uniqueName
      displayName: g.displayName
      groupDescription: g.?description ?? ''
      mailNickname: g.mailNickname
      ownerObjectIds: g.?ownerObjectIds ?? []
      memberObjectIds: g.?memberObjectIds ?? []
      assignableToRole: g.?assignableToRole ?? false
    }
  }
]

// -----------------------------------------------------------------------------
// OUTPUTS — surface the created group IDs for downstream RBAC / role assignments.
// -----------------------------------------------------------------------------

@description('Object IDs of all groups created, keyed by uniqueName.')
output groupIds array = [
  for (g, i) in groups: {
    uniqueName: g.uniqueName
    groupId: entraGroups[i].outputs.groupId
  }
]

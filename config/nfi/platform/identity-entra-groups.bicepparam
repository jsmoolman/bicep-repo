// =============================================================================
// PARAMETERS: Platform Identity — Entra ID Groups (prd)
// =============================================================================
// PURPOSE
//   Environment-specific VALUES for the Entra groups composition. This is the
//   third layer of the pattern:
//
//       modules/  =  reusable building block   (HOW to create a group)
//       src/      =  composition / entry point (WHAT to deploy)
//       config/   =  this file                 (the actual groups to create)
//
// SCAFFOLDING GUIDE (read this if you are an AI agent adding groups)
//   - Add a new object to the `groups` array for each Entra group you need.
//   - `uniqueName` is the immutable idempotency key — choose it carefully and
//     do not change it later (changing it creates a NEW group).
//   - Recommended uniqueName pattern: sg-{workload}-{role}-{environment}.
//   - `ownerObjectIds` / `memberObjectIds` take Entra object IDs (GUIDs). Leave
//     them out (or empty) to manage membership elsewhere.
//   - To target another environment, COPY this file (e.g. identity-entra-groups.dev.bicepparam)
//     and change `environment` and the values — never duplicate the composition.
// =============================================================================

using '../../../src/platform/identity/entra-groups.bicep'

param environment = 'prd'

param groups = [
  {
    uniqueName: 'sg-lims-admins-prd'
    displayName: 'lims Administrators (prd)'
    description: 'Administrative access to the lims production workload.'
    mailNickname: 'sg-lims-admins-prd'
    // Replace with real Entra object IDs (GUIDs) of owners/members.
    ownerObjectIds: []
    memberObjectIds: []
    // Set true only if this group will be assigned an Entra directory role.
    assignableToRole: false
  }
  {
    uniqueName: 'sg-lims-readers-prd'
    displayName: 'lims Readers (prd)'
    description: 'Read-only access to the lims production workload.'
    mailNickname: 'sg-lims-readers-prd'
    memberObjectIds: []
  }
]

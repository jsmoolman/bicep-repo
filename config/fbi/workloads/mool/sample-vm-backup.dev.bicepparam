// =============================================================================
// SAMPLE PARAMETERS: lims — VM Backup (dev)
// =============================================================================
// PURPOSE
//   Environment-specific VALUES for the sample VM-backup composition. This is
//   the third piece of the pattern:
//
//       modules/  =  reusable building block   (HOW to deploy)
//       src/      =  composition / entry point (WHAT to deploy)
//       config/   =  this file                 (the VALUES per environment)
//
// SCAFFOLDING GUIDE (read this if you are an AI agent adding an environment)
//   To target another environment, COPY this file and change only the values
//   (e.g. sample-vm-backup.prd.bicepparam with environment = 'prd' and the prod
//   subscriptionId). NEVER duplicate the Bicep in `src/` per environment — reuse
//   the same composition with a different parameter file.
//
//   The `using` statement binds this parameter file to its composition and gives
//   editors full type-checking and IntelliSense for the params below.
// =============================================================================

using '../../../../src/workloads/lims/sample-vm-backup.bicep'

param location = 'westeurope'
param environment = 'dev'
param purpose = 'lims'

// Subscription the lims dev landing zone lives in.
param subscriptionId = 'jsm-dev-{guid}'

// VM resource IDs to protect. Left empty for the first deployment so the vault
// and policy are created up front; populate after the VMs exist, e.g.:
//   '/subscriptions/<sub>/resourceGroups/rg-lims-dev-westeurope/providers/Microsoft.Compute/virtualMachines/vm-lims-app-dev-westeurope'
param protectedVmResourceIds = []

param tags = {
  Environment: 'dev'
  Workload: 'lims'
  ManagedBy: 'bicep-iac'
  Owner: 'team-lims'
  CostCenter: 'CC-1001'
}

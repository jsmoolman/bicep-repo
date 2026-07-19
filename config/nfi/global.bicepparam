using 'none'

// Global parameters shared across all deployments for nfi.
// Reference this file from environment-specific .bicepparam files using `import`.

param location = 'westeurope'

param tags = {
  ManagedBy: 'bicep-iac'
  Owner: 'team-infrastructure'
  CostCenter: 'CC-0001'
}

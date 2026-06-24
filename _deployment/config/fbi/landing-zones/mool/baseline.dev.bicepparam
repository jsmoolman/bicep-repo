using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'dev'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-dev-{guid}'
param tags           = {
  environment: 'development'
  purpose:     'lims'
}

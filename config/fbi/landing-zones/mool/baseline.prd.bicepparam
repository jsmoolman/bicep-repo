using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'prd'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-prd-{guid}'
param tags           = {
  environment: 'production'
  purpose:     'lims'
}

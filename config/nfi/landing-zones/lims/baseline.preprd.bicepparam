using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'preprd'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-preprd-{guid}'
param tags           = {
  environment: 'pre-production'
  purpose:     'lims'
}

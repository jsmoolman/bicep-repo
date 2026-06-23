using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'preprd'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-preprd-{guid}'
param tags           = {
  environment: 'pre-production'
  purpose:     'mool'
}

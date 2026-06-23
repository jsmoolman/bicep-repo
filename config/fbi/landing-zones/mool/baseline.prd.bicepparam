using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'prd'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-prd-{guid}'
param tags           = {
  environment: 'production'
  purpose:     'mool'
}

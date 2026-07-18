using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'tst'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-tst-{guid}'
param tags           = {
  environment: 'test'
  purpose:     'lims'
}

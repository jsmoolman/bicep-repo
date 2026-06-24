using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'acc'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-acc-{guid}'
param tags           = {
  environment: 'acceptance'
  purpose:     'lims'
}

using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'acc'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-acc-{guid}'
param tags           = {
  environment: 'acceptance'
  purpose:     'mool'
}

using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'tst'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-tst-{guid}'
param tags           = {
  environment: 'test'
  purpose:     'mool'
}

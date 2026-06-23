using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'mgmt'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-mgmt-{guid}'
param tags           = {
  environment: 'management'
  purpose:     'mool'
}

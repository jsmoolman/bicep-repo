using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'mgmt'
param location       = 'westeurope'
param workloadName   = 'lims'
param purpose        = 'lims'
param subscriptionId = 'jsm-mgmt-{guid}'
param tags           = {
  environment: 'management'
  purpose:     'lims'
}

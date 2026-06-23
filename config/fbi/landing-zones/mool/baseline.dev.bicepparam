using '../../../../src/landing-zones/baseline/main.bicep'

param environment    = 'dev'
param location       = 'westeurope'
param workloadName   = 'mool'
param purpose        = 'mool'
param subscriptionId = 'jsm-dev-{guid}'
param tags           = {
  environment: 'development'
  purpose:     'mool'
}

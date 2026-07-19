using '../../../../src/landing-zones/subscription-vending/main.bicep'

param location = 'westeurope'

param subscriptions = [
  {
    name: 'lims-mgmt'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
  {
    name: 'lims-dev'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
  {
    name: 'lims-tst'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
  {
    name: 'lims-acc'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
  {
    name: 'lims-preprd'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
  {
    name: 'lims-prd'
    managementGroupId: 'nfi-landingzones-corp'
    billingAccountId: 'jsm-{billingAccountId}'
    enrollmentAccountId: 'jsm-{enrollmentAccountId}'
  }
]

targetScope = 'managementGroup'

metadata name = 'Landing Zone — Subscription Vending'
metadata description = 'Provisions new application landing zone subscriptions and places them in the correct management group.'

@description('Array of subscription definitions to vend.')
param subscriptions array = []

@description('Azure region used for deployment metadata.')
param location string = 'westeurope'

// Each subscription object should contain: name, managementGroupId, billingAccountId, enrollmentAccountId
@batchSize(1)
module vendedSubscriptions '../../../modules/org/subscription-vending/main.bicep' = [for sub in subscriptions: {
  name: 'vend-${sub.name}'
  params: {
    subscriptionName: sub.name
    managementGroupId: sub.managementGroupId
    billingAccountId: sub.billingAccountId
    enrollmentAccountId: sub.enrollmentAccountId
    location: location
  }
}]

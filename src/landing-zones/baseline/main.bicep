targetScope = 'subscription'

metadata name = 'Landing Zone — Baseline'
metadata description = 'Applies the per-subscription governance baseline: resource groups, RBAC assignments, budget alerts, diagnostic settings, and spoke VNet peering.'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Workload name used in resource naming (e.g. mool).')
param workloadName string

@description('Workload / purpose identifier used in tagging (e.g. mool).')
param purpose string

@description('Environment code.')
@allowed(['mgmt', 'dev', 'tst', 'acc', 'preprd', 'prd'])
param environment string

@description('Subscription ID this baseline is deployed into. Used by pipelines to select the correct service connection.')
param subscriptionId string

@description('Hub VNet resource ID for spoke peering.')
param hubVnetId string = ''

@description('Monthly budget amount in EUR.')
param budgetAmount int = 500

@description('Tags to apply to all resources.')
param tags object = {}

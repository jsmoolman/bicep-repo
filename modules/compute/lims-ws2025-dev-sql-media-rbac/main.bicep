metadata description = 'Grants an already-resolved, already-verified principal exactly one built-in Storage Blob Data Reader role assignment, scoped to exactly the existing mssql-2022-source blob container inside the existing salimsmgmtwe storage account — never storage-account, resource-group, or subscription scope. Part of the narrow LIMS WS2025 DEV v2 SQL installation-media container RBAC exception in docs/scope.md. Creates no storage account, container, account key, SAS token, or additional identity; references both the storage account and container as existing resources and modifies neither.'

targetScope = 'resourceGroup'

@description('Name of the existing storage account hosting the installation-media container, e.g. salimsmgmtwe. Referenced only as an existing resource — not created, modified, or redefined here.')
param storageAccountName string

@description('Name of the existing blob container to grant read access to, e.g. mssql-2022-source. Referenced only as an existing resource — not created, modified, or redefined here.')
param containerName string

@description('The already-resolved, already-verified principalId of the SQL VM system-assigned managed identity (see modules/compute/lims-ws2025-dev-sql-media-rbac/resolve-sql-vm-identity.bicep). This module performs no verification of its own and resolves no identity — it only consumes this value.')
param principalId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' existing = {
  parent: blobService
  name: containerName
}

// Built-in Storage Blob Data Reader role — verified against Microsoft's own
// built-in-roles documentation
// (https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-reader).
// No custom Microsoft.Authorization/roleDefinitions resource is declared
// anywhere in this module.
var storageBlobDataReaderRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

// Scope is the container resource itself (never the storage account,
// resource group, or subscription) — the narrowest scope this exception
// permits. Deterministic guid()-based name for idempotency, matching the
// same name-construction pattern already used elsewhere in this repository
// (e.g. modules/compute/lims-ws2025-dev-foundation/main.bicep's VM login
// role assignments).
resource containerReadAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, principalId, storageBlobDataReaderRoleDefinitionId)
  scope: container
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleDefinitionId
  }
}

@description('Full ARM resource ID of the single Storage Blob Data Reader role assignment created by this module.')
output roleAssignmentId string = containerReadAccess.id

@description('Full ARM resource ID of the exact container scope this role assignment targets (never the storage account, resource group, or subscription).')
output containerResourceId string = container.id

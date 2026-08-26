---
applyTo: "**/*.bicep,**/*.bicepparam"
---

# Bicep Authoring Standards

Before authoring any resource, confirm it falls within the allowed capability categories in `docs/scope.md`. Do not author Entra/Graph resources, RBAC, management groups, subscription vending, or general infrastructure (networking, VMs, storage, databases, Key Vault, app hosting) — these are prohibited or require an explicit architecture decision.

## Mandatory lookup chain — run in this order, do not skip

Before writing any resource block:

1. **Azure Verified Modules (AVM)** — https://azure.github.io/Azure-Verified-Modules/
   Use AVM when a module exists. It is Microsoft's current recommended standard.
2. **Bicep Registry source** — https://github.com/Azure/bicep-registry-modules
   Review params, outputs, and patterns before coding.
3. **Microsoft Learn Bicep docs** — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
   Authoritative source for syntax, scopes, and API versions.
4. **Bicep MCP tools** (run AFTER the online checks):
   - `list_avm_metadata` — find the AVM module and get the latest pinned version
   - `get_azure_resource_type_schema` — verify resource type properties and correct API version
   - `get_bicep_best_practices` — review current guidance before coding
   - `format_bicep_file` — format before committing

Do not write resource blocks from memory.

## Naming convention

```
{type}-{workload}-{environment}-{region-suffix}
```

The region segment in resource names uses the **short region code** (e.g. `westeu`). The full Azure region name (e.g. `westeurope`) is used only in deployment location parameters and properties — never as a name segment.

| Resource | Example |
|---|---|
| Resource Group | `rg-lims-dev-westeu` |
| Log Analytics Workspace | `law-lims-dev-westeu` |

## targetScope rules

- `subscription` — resource groups, subscription-level role assignments (only where explicitly approved), policies
- `resourceGroup` — any resource that lives inside a resource group
- Never default every module to `subscription`. Choose based on the resource being deployed.

## Parameter contract (every param file must include these)

```bicep
param environment    = 'dev'           // dev | tst | acc | preprd | prd
param location       = 'westeurope'
param purpose        = 'lims'
param tags           = {
  environment: 'development'           // long-form display name
  purpose:     'lims'
}
```

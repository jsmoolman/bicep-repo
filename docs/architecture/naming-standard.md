# Naming Standard

## Pattern

```
<resource-type-abbreviation>-<workload>-<environment>-<region>
```

| Segment | Description | Example |
|---|---|---|
| resource-type-abbreviation | Azure CAF abbreviation | `rg`, `vnet`, `kv` |
| workload | Short workload or platform name | `mool`, `conn`, `mgmt` |
| environment | Environment code | `dev`, `tst`, `acc`, `preprd`, `prd`, `mgmt` |
| region | Full Azure region name | `westeurope`, `northeurope` |

The region segment is always the full Azure region name (e.g. `westeurope`). Never use short region codes such as `weu`. An optional zero-padded two-digit instance suffix (e.g. `-01`) is only added when explicitly required.

## Examples

| Resource | Name |
|---|---|
| Resource Group (MOOL prod) | `rg-mool-prd-westeurope` |
| Virtual Network (connectivity hub) | `vnet-conn-prd-westeurope` |
| Key Vault (MOOL dev) | `kv-mool-dev-westeurope` |
| Log Analytics Workspace | `law-mgmt-prd-westeurope` |
| Recovery Services Vault | `rsv-mool-prd-westeurope` |

## Globally Unique Resources

For resources requiring globally unique names (Storage Accounts, Key Vaults, ACR), append a short hash or unique suffix derived from the subscription ID to avoid conflicts:

```
st<workload><env><region><uniquesuffix>
```

Example: `stmoolprdwesteurope3f8a`

## Validation

Use `scripts/Test-NamingConvention.ps1` to validate resource names before deployment.

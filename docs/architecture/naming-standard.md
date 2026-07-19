# Naming Standard

## Pattern

```
<resource-type-abbreviation>-<workload>-<environment>-<region-suffix>
```

| Segment | Description | Example |
|---|---|---|
| resource-type-abbreviation | Azure CAF abbreviation | `rg`, `vnet`, `kv` |
| workload | Short workload or platform name | `lims`, `conn`, `mgmt` |
| environment | Environment code | `dev`, `tst`, `acc`, `preprd`, `prd`, `mgmt` |
| region-suffix | Short region code used **in resource names only** | `westeu`, `northeu` |

The region segment in resource names uses the **short region code** (e.g. `westeu`), not the full Azure region name. The full region name (e.g. `westeurope`) is used only as the value for Azure deployment location parameters and properties — never as a name segment.

| Usage | Value |
|---|---|
| Resource name suffix | `westeu` |
| Azure location parameter / property | `westeurope` |

An optional zero-padded two-digit instance suffix (e.g. `-01`) is only added when explicitly required.

## Examples

| Resource | Name |
|---|---|
| Resource Group (lims prod) | `rg-lims-prd-westeu` |
| Virtual Network (connectivity hub) | `vnet-conn-prd-westeu` |
| Key Vault (lims dev) | `kv-lims-dev-westeu` |
| Log Analytics Workspace | `law-mgmt-prd-westeu` |
| Recovery Services Vault | `rsv-lims-prd-westeu` |

## Globally Unique Resources

For resources requiring globally unique names (Storage Accounts, Key Vaults, ACR), append a short hash or unique suffix derived from the subscription ID to avoid conflicts:

```
st<workload><env><region-suffix><uniquesuffix>
```

Example: `stlimsprdwesteu3f8a`

## Validation

Use `scripts/Test-NamingConvention.ps1` to validate resource names before deployment.

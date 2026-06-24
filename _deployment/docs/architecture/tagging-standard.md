# Tagging Standard

## Mandatory Tags

All Azure resources and resource groups must carry the following tags:

| Tag Key | Description | Example |
|---|---|---|
| `Environment` | Deployment environment | `dev`, `tst`, `acc`, `preprd`, `prd` |
| `Workload` | Workload or application name | `lims`, `platform-connectivity` |
| `CostCenter` | Finance cost center code | `CC-1234` |
| `Owner` | Team or individual responsible | `team-infrastructure` |
| `ManagedBy` | Deployment method | `bicep-iac` |

## Optional Tags

| Tag Key | Description | Example |
|---|---|---|
| `BusinessUnit` | Owning business unit | `it-operations` |
| `DataClassification` | Sensitivity of data processed | `confidential`, `internal`, `public` |
| `SLA` | SLA tier | `standard`, `premium` |
| `ExpiryDate` | For temporary resources | `2026-12-31` |

## Enforcement

Tags are enforced via Azure Policy (initiative: `nfi-mandatory-tags`) assigned at the management group level. Non-compliant resources are flagged in the compliance dashboard and blocked from deployment via deny policies on resource groups.

## Inheritance

Resource groups inherit tags from subscriptions where possible. Individual resources should explicitly carry all mandatory tags to support cost management filtering.

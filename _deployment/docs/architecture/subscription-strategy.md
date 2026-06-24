# Subscription Strategy

## Principles

- **One subscription per workload per environment** for production workloads — provides blast radius isolation, independent cost tracking, and policy scope flexibility.
- **Shared platform subscriptions** for management, connectivity, and identity — these are singleton services consumed by all landing zones.
- **Sandbox subscriptions** are ephemeral and subject to automated cost and resource cleanup policies.

## Subscription Catalogue

| Subscription Name | Purpose | Environment | Management Group |
|---|---|---|---|
| `nfi-mgmt-prd` | Centralized logging, monitoring, automation | prd | nfi-platform-management |
| `nfi-conn-prd` | Hub VNet / vWAN, Azure Firewall, DNS | prd | nfi-platform-connectivity |
| `nfi-id-prd` | Domain controllers, LDAP, PKI | prd | nfi-platform-identity |
| `nfi-lims-dev` | lims workload — development | dev | nfi-landingzones-corp |
| `nfi-lims-tst` | lims workload — test | tst | nfi-landingzones-corp |
| `nfi-lims-acc` | lims workload — acceptance | acc | nfi-landingzones-corp |
| `nfi-lims-preprd` | lims workload — pre-production | preprd | nfi-landingzones-corp |
| `nfi-lims-prd` | lims workload — production | prd | nfi-landingzones-corp |

## Vending Process

New subscriptions are provisioned via the `landing-zones/subscription-vending` deployment unit. See `config/customer-a/landing-zones/lims/subscriptions.yaml` for the subscription manifest format.

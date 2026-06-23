# Subscription Strategy

## Principles

- **One subscription per workload per environment** for production workloads — provides blast radius isolation, independent cost tracking, and policy scope flexibility.
- **Shared platform subscriptions** for management, connectivity, and identity — these are singleton services consumed by all landing zones.
- **Sandbox subscriptions** are ephemeral and subject to automated cost and resource cleanup policies.

## Subscription Catalogue

| Subscription Name | Purpose | Environment | Management Group |
|---|---|---|---|
| `fbi-mgmt-prd` | Centralized logging, monitoring, automation | prd | fbi-platform-management |
| `fbi-conn-prd` | Hub VNet / vWAN, Azure Firewall, DNS | prd | fbi-platform-connectivity |
| `fbi-id-prd` | Domain controllers, LDAP, PKI | prd | fbi-platform-identity |
| `fbi-mool-dev` | MOOL workload — development | dev | fbi-landingzones-corp |
| `fbi-mool-tst` | MOOL workload — test | tst | fbi-landingzones-corp |
| `fbi-mool-acc` | MOOL workload — acceptance | acc | fbi-landingzones-corp |
| `fbi-mool-preprd` | MOOL workload — pre-production | preprd | fbi-landingzones-corp |
| `fbi-mool-prd` | MOOL workload — production | prd | fbi-landingzones-corp |

## Vending Process

New subscriptions are provisioned via the `landing-zones/subscription-vending` deployment unit. See `config/customer-a/landing-zones/mool/subscriptions.yaml` for the subscription manifest format.

# Policy Strategy

## Approach

Azure Policy is the primary governance control plane. Policies follow the ALZ baseline with nfi-specific customisations.

## Assignment Scopes

| Scope | Assignment Type | Examples |
|---|---|---|
| nfi root management group | DeployIfNotExists, Audit, Deny | Mandatory tags, allowed locations |
| Platform management group | DeployIfNotExists | Diagnostic settings to Log Analytics |
| Landing Zones management group | Deny, Audit | No public IPs, encryption at rest |
| Corp management group | Deny | Require private endpoints |
| Individual subscription | Audit | Cost budget alerts |

## Custom Policy Modules

Custom policy definitions and initiatives live under `modules/policy/`:

- `definitions/` — Individual custom policy definitions
- `initiatives/` — Policy set definitions grouping related policies
- `assignments/` — Assignment modules parameterised per scope

## ALZ Policy Alignment

ALZ built-in policy sets are vendored under `lib/alz/policy_assignments/`. These are updated periodically using the ALZ Library tooling and reviewed before applying to production.

## Exemptions

Policy exemptions are tracked in code as Bicep resources deployed alongside the affected resources. Exemptions must include a justification comment and an expiry date.

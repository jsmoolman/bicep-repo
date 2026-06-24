# Management Group Hierarchy

## Structure

```
Tenant Root Group
└── nfi (nfi)
    ├── Platform (nfi-platform)
    │   ├── Management (nfi-platform-management)
    │   ├── Connectivity (nfi-platform-connectivity)
    │   ├── Identity (nfi-platform-identity)
    │   └── Security (nfi-platform-security)
    │
    ├── Landing Zones (nfi-landingzones)
    │   ├── Corp (nfi-landingzones-corp)
    │   └── Online (nfi-landingzones-online)
    │
    ├── Sandboxes (nfi-sandboxes)
    │
    └── Decommissioned (nfi-decommissioned)
```

## Policy Inheritance

Policies are assigned at the highest applicable scope to maximise coverage with minimal assignments:

| Management Group | Key Policy Initiatives |
|---|---|
| nfi root | Mandatory tags, allowed locations, diagnostic settings |
| Platform | Defender for Cloud, audit logging |
| Landing Zones | VM baseline, encryption at rest, network controls |
| Corp | Deny public endpoints, require private endpoints |

## Subscription Placement

| Subscription | Management Group |
|---|---|
| nfi-mgmt-prd | nfi-platform-management |
| nfi-conn-prd | nfi-platform-connectivity |
| nfi-id-prd | nfi-platform-identity |
| nfi-lims-dev | nfi-landingzones-corp |
| nfi-lims-tst | nfi-landingzones-corp |
| nfi-lims-acc | nfi-landingzones-corp |
| nfi-lims-preprd | nfi-landingzones-corp |
| nfi-lims-prd | nfi-landingzones-corp |

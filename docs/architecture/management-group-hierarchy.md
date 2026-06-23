# Management Group Hierarchy

## Structure

```
Tenant Root Group
└── FBI (fbi)
    ├── Platform (fbi-platform)
    │   ├── Management (fbi-platform-management)
    │   ├── Connectivity (fbi-platform-connectivity)
    │   ├── Identity (fbi-platform-identity)
    │   └── Security (fbi-platform-security)
    │
    ├── Landing Zones (fbi-landingzones)
    │   ├── Corp (fbi-landingzones-corp)
    │   └── Online (fbi-landingzones-online)
    │
    ├── Sandboxes (fbi-sandboxes)
    │
    └── Decommissioned (fbi-decommissioned)
```

## Policy Inheritance

Policies are assigned at the highest applicable scope to maximise coverage with minimal assignments:

| Management Group | Key Policy Initiatives |
|---|---|
| FBI root | Mandatory tags, allowed locations, diagnostic settings |
| Platform | Defender for Cloud, audit logging |
| Landing Zones | VM baseline, encryption at rest, network controls |
| Corp | Deny public endpoints, require private endpoints |

## Subscription Placement

| Subscription | Management Group |
|---|---|
| fbi-mgmt-prd | fbi-platform-management |
| fbi-conn-prd | fbi-platform-connectivity |
| fbi-id-prd | fbi-platform-identity |
| fbi-mool-dev | fbi-landingzones-corp |
| fbi-mool-tst | fbi-landingzones-corp |
| fbi-mool-acc | fbi-landingzones-corp |
| fbi-mool-preprd | fbi-landingzones-corp |
| fbi-mool-prd | fbi-landingzones-corp |

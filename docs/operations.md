# Operations

This document describes only the operational behavior that actually exists in this repository today.

## Current state

### VM Availability SLA Dashboard v2 — lims

The first migrated observability capability. This is a lossless migration of a pre-existing, customer-approved LIMS Azure Monitor Workbook from a legacy repository — the workbook's KQL, layout, parameters, and behavior were preserved as-is; only file location and the module reference path changed.

- **Reusable entrypoint:** [`src/observability/vm-availability-sla-dashboard-v2/main.bicep`](../src/observability/vm-availability-sla-dashboard-v2/main.bicep) — subscription-scoped orchestrator, no LIMS-specific values, suitable for reuse by another project with a different parameter file.
- **Reusable module:** [`modules/observability/vm-availability-sla-dashboard-v2/main.bicep`](../modules/observability/vm-availability-sla-dashboard-v2/main.bicep) — the workbook resource definition, migrated unchanged from the legacy implementation.
- **LIMS configuration:** [`config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam`](../config/nfi/lims/observability/vm-availability-sla-dashboard-v2.bicepparam) — one central workbook covering the `dev`/`tst`/`acc`/`preprd`/`prd` LIMS environments via `subscriptionEnvironmentMappings`, converted from the legacy ARM parameter JSON with all effective values unchanged.
- **Deployment pipeline:** [`.azuredevops/pipelines/deploy-vm-availability-sla-dashboard-v2.yml`](../.azuredevops/pipelines/deploy-vm-availability-sla-dashboard-v2.yml) exists but is **temporarily non-triggering** (`trigger: none`, `pr: none`) during commissioning. It supports an explicit `what-if` (default) or `deploy` action and must be run manually. It has not been run from this repository.
- **Live validation status:** No Azure what-if or deployment has been performed from this repository for this capability yet. This migration is a static, local-build-only change. Operational proof (a successful what-if against the live environment, followed by a reviewed deployment) is a separate future step.

**Known legacy naming detail:** the repository/capability name `VM Availability SLA Dashboard v2 - lims` refers to this capability in documentation and file paths only. It is not the literal customer-visible name produced by the deployed workbook. The existing (unchanged) legacy implementation actually produces:

- an in-workbook title of `VM Availability SLA Dashboard v2 — lims` (note: em dash, not a hyphen), and
- an Azure Portal workbook gallery `displayName` of `workbook-vm-availability-v2-lims-westeu`, which does not resemble the descriptive name at all.

This migration intentionally preserved both values unchanged, since the deployed workbook, its resource GUID/name logic, and its customer-visible display name/title must not change as part of relocating the implementation into this repository.

No other operational capability (alerts, Logic Apps, VM maintenance, backup automation, or scripts under `operations/`) has been implemented yet.

## Continuous Integration

The only pipeline in this repository is [`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml). It runs on every push to every branch, including `main`, and performs static validation only — it does not deploy or otherwise mutate Azure. There is no PR-specific trigger.

1. **Bicep build and lint** — every `*.bicep` file in the repository is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, subscription creation, or role assignment/definition resource types, enforcing the boundaries in [`docs/scope.md`](scope.md).

There is currently no automatic *deployment* pipeline. The deployment pipeline described above for the VM Availability SLA Dashboard v2 exists but does not trigger automatically (`trigger: none`, `pr: none`) and must be run manually.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

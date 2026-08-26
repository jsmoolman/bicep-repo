# Operations

This document describes only the operational behavior that actually exists in this repository today.

## Current state

No operational capability (workbooks, alerts, Logic Apps, VM maintenance, backup automation, or scripts under `operations/`) has been implemented yet. This milestone establishes the repository foundation (structure, pipeline, and documentation) only.

## Continuous Integration

The only pipeline in this repository is [`.azuredevops/pipelines/ci.yml`](../.azuredevops/pipelines/ci.yml). It runs on pull requests targeting `main` and performs static validation only — it does not deploy or otherwise mutate Azure:

1. **Bicep build and lint** — every `*.bicep` file in the repository is compiled and linted.
2. **Bicep parameter file validation** — every `*.bicepparam` file is built to confirm it resolves against its composition.
3. **Prohibited resource type guard** — a static search blocks any checked-in Bicep or parameter file that references Microsoft Graph, management-group creation, subscription creation, or role assignment/definition resource types, enforcing the boundaries in [`docs/scope.md`](scope.md).

There is currently no automatic deployment pipeline. One will be added alongside the first real operational capability.

## Future operational documentation

As workbooks, alerts, Logic Apps, or operational scripts are added, this document will be updated to describe their actual behavior, ownership, and how to run them. Do not treat any capability described in [`docs/scope.md`](scope.md) as already implemented — that document defines allowed *scope*, not current *state*.

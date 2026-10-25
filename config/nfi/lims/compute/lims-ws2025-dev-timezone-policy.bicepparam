// Real (non-secret) DEV parameters for LIMS WS2025 DEV v2 time-zone
// enforcement. Approved under the narrow LIMS WS2025 DEV v2 time-zone
// enforcement exception recorded in docs/scope.md — see that file before
// changing the scope of what this composition is allowed to create.
//
// *** NOT YET DEPLOYMENT-READY ***
// resourceGroupResourceId below is a REPLACE_WITH_REAL_VALUE placeholder,
// identical in kind to the one still unresolved in
// config/nfi/lims/compute/lims-ws2025-dev-foundation.bicepparam and
// config/nfi/lims/compute/lims-ws2025-dev-patch-policy.bicepparam (this
// composition targets the SAME existing rg-compute-lims-dev-westeu resource
// group — it creates no resource group of its own). Replace all three
// occurrences together from the same authoritative source. It MUST be
// replaced with the real resource ID before this file can be used for
// `bicep build-params` against live resources or for any deployment. Until
// then this file is suitable for local static validation only.
//
// This file intentionally contains no parameter referencing the existing,
// broader subscription-scoped "configure-windows-timezone-dev" policy
// assignment or its identity (2dea906c-2e98-4b2c-ab4b-2d002de614e7) — this
// composition does not reference, modify, or grant any permission to that
// assignment or identity. Both v2 policy assignments below use their own
// dedicated, newly created system-assigned identities instead.
using '../../../../src/compute/lims-ws2025-dev-timezone-policy/main.bicep'

param resourceGroupResourceId = 'REPLACE_WITH_REAL_VALUE:/subscriptions/<lims-dev-subscription-id>/resourceGroups/rg-compute-lims-dev-westeu'

param location = 'westeurope'

param appVmName = 'vm-lims-dev-v2-westeu-001'

param sqlVmName = 'vm-lims-dev-v2-westeu-002'

param timeZone = '(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna'

param includeArcMachines = 'false'

param enforcementMode = 'Default'

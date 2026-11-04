#!/usr/bin/env bash
# Standalone extraction of the target-identity guard logic from
# .azuredevops/pipelines/stage-lims-ws2025-dev-sql-media.yml's "Validate
# target VM identity before invoking the script" step, for local
# validation without any real Azure CLI dependency.
#
# Required env vars (simulate `az account show`/`az vm show` output and
# the pipeline's expected-value parameters):
#   SELECTED_SUBSCRIPTION_ID, EXPECTED_SUBSCRIPTION_ID
#   ACTUAL_VM_ID, EXPECTED_RESOURCE_GROUP, EXPECTED_VM_NAME
set -uo pipefail

selectedSubscriptionId="$SELECTED_SUBSCRIPTION_ID"
expectedSubscriptionId="$EXPECTED_SUBSCRIPTION_ID"
if [[ "${selectedSubscriptionId,,}" != "${expectedSubscriptionId,,}" ]]; then
  echo "ERROR: selected subscription '$selectedSubscriptionId' does not match the expected DEV subscription '$expectedSubscriptionId'." >&2
  exit 1
fi

actualVmId="$ACTUAL_VM_ID"
expectedVmId="/subscriptions/${expectedSubscriptionId}/resourceGroups/${EXPECTED_RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/${EXPECTED_VM_NAME}"

shopt -s nocasematch
if [[ "$actualVmId" != "$expectedVmId" ]]; then
  echo "ERROR: resolved VM resource ID ('$actualVmId') does not exactly match the expected target ('$expectedVmId'); refusing to proceed." >&2
  exit 1
fi
shopt -u nocasematch

echo "Target VM identity verified: $actualVmId"
exit 0

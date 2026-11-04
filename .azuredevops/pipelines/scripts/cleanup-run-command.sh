#!/usr/bin/env bash
# =============================================================================
# Best-effort cleanup of an ad hoc Managed Run Command resource created by
# submit-and-wait-run-command.sh -- deletes it only when that script
# recorded a conclusively determined outcome; otherwise retains it.
# =============================================================================
#
# Required environment variables:
#   DEV_SUBSCRIPTION_ID    Pinned DEV subscription ID. Passed explicitly
#                           as `--subscription` on `az vm run-command
#                           delete` -- never relied on implicitly via `az
#                           account set`/the service connection's own
#                           default context. This script deliberately
#                           contains no `az account set ... || true`
#                           fallback that could let a failed context
#                           switch fall through to whatever subscription
#                           happened to already be selected.
#   RESOURCE_GROUP         Pinned resource group of the target VM.
#   VM_NAME                Pinned name of the target VM.
#
# Optional environment variables:
#   RUN_COMMAND_NAME       Name of the run-command resource to clean up.
#                           If empty/unset, nothing was ever recorded as
#                           submitted this run -- exits 0 immediately,
#                           nothing to do.
#   STAGING_INDETERMINATE  Retain-by-default: deletion happens only when
#                           this is exactly the string "false". Any other
#                           value -- "true", empty, or unset entirely
#                           (for example because submit-and-wait-run-command.sh
#                           was interrupted before it could record any
#                           outcome at all) -- retains the resource. This
#                           is opt-in cleanup, not opt-out: an unknown
#                           state must never be treated as safe to
#                           delete.
#
# Exit code: always 0 -- this is a best-effort step that must never fail
# the pipeline job by itself (a definite deletion failure is reported as
# a non-fatal warning; "retained on purpose" and "nothing to do" are both
# success outcomes for this script, not errors).
set -uo pipefail

if [[ -z "${RUN_COMMAND_NAME:-}" ]]; then
  echo "No Managed Run Command resource name was ever recorded this run; nothing to delete."
  exit 0
fi

if [[ -z "${DEV_SUBSCRIPTION_ID:-}" || -z "${RESOURCE_GROUP:-}" || -z "${VM_NAME:-}" ]]; then
  echo "ERROR: DEV_SUBSCRIPTION_ID, RESOURCE_GROUP, and VM_NAME must all be set to clean up '$RUN_COMMAND_NAME'; retaining it rather than guessing." >&2
  exit 0
fi

if [[ "${STAGING_INDETERMINATE:-true}" != "false" ]]; then
  echo "The result for '$RUN_COMMAND_NAME' could not be conclusively determined -- it may still be executing. Deliberately NOT deleting it."
  echo "Run-command name: $RUN_COMMAND_NAME"
  echo "Inspect manually with:"
  echo "  az vm run-command show --subscription $DEV_SUBSCRIPTION_ID --resource-group $RESOURCE_GROUP --vm-name $VM_NAME --name $RUN_COMMAND_NAME --instance-view"
  exit 0
fi

echo "Deleting Managed Run Command resource '$RUN_COMMAND_NAME' (subscription: $DEV_SUBSCRIPTION_ID)..."
az vm run-command delete \
  --subscription "$DEV_SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "$RUN_COMMAND_NAME" \
  --yes \
  --only-show-errors \
  || echo "WARNING: failed to delete Managed Run Command resource '$RUN_COMMAND_NAME' (non-fatal; this resource can be deleted manually later and never performs or re-performs any guest action by existing)."

exit 0

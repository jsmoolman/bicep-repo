#!/usr/bin/env bash
# =============================================================================
# Submit a script to a VM via Azure Managed Run Command
# (Microsoft.Compute/virtualMachines/runCommands) and wait for it to reach
# a terminal execution state, verifying both the execution state and the
# guest exit code before reporting success.
# =============================================================================
#
# This is the one shared mechanism provision-lims-ws2025-dev-sql.yml's
# `stage-only` action uses today, and the one a future `install` action
# (SQL Server Setup, not in scope yet) is expected to reuse unchanged --
# only the script it submits (and the run-command name prefix) differs.
# Nothing about target resolution, polling, or result verification is
# duplicated per action.
#
# Required environment variables:
#   RESOURCE_GROUP              Pinned resource group of the target VM.
#   VM_NAME                     Pinned name of the target VM.
#   SCRIPT_TO_SUBMIT            Repository-relative path to the script to
#                                submit (loaded via the "@<path>" az CLI
#                                file-content convention).
#   RUN_COMMAND_NAME            Name for the ad hoc runCommands resource.
#   GUEST_TIMEOUT_SECONDS       Passed to `az vm run-command create
#                                --timeout-in-seconds` -- the guest script's
#                                own execution budget.
#   POLL_DEADLINE_SECONDS       Overall wall-clock budget for this script's
#                                polling loop (covers both the bounded
#                                startup-retry phase and normal polling).
#                                Independent of, and should exceed,
#                                GUEST_TIMEOUT_SECONDS by a margin that
#                                covers Azure's own provisioning/start
#                                overhead.
#   STARTUP_MAX_RETRIES         Maximum number of bounded retries allowed
#                                while the run-command resource is not yet
#                                visible, or is visible but has not yet
#                                reported any instanceView.executionState.
#   STARTUP_RETRY_INTERVAL_SECONDS
#                                Sleep between bounded startup retries.
#   NORMAL_POLL_INTERVAL_SECONDS Sleep between polls once an
#                                executionState has been observed at least
#                                once (including a non-terminal one, e.g.
#                                "Running").
#
# Side effects visible to the calling Azure Pipelines job (via `##vso`
# logging commands, so this works whether invoked as an inline script or
# as a scriptPath -- both just parse stdout):
#   - Pipeline variable `runCommandName` is always set, as soon as the
#     name is known, before submission is even attempted -- so a later
#     cleanup step can act on it regardless of how this script exits.
#   - Pipeline variable `stagingIndeterminate` is set to exactly "true"
#     only when this run-command resource's real-world state could not be
#     conclusively determined (the polling deadline was reached, the
#     command never became observable within the bounded startup-retry
#     budget, or Azure reported a terminal "Succeeded" state without an
#     exit code) -- a signal to the calling pipeline that the resource may
#     still be legitimately executing and should not be deleted. It is
#     explicitly set to "false" in every other outcome (success, a
#     definite "Failed"/"Canceled" state, a definite nonzero guest exit
#     code, or the initial `az vm run-command create` call itself failing
#     outright) so a cleanup step never has to guess from an unset
#     variable.
#
# Exit code: 0 only when Azure reports executionState "Succeeded" and the
# guest script's own exit code is exactly 0. Non-zero in every other case,
# including every indeterminate case above -- "indeterminate" is reported
# as a pipeline failure, never silently treated as success.
set -uo pipefail

for requiredVar in RESOURCE_GROUP VM_NAME SCRIPT_TO_SUBMIT RUN_COMMAND_NAME \
  GUEST_TIMEOUT_SECONDS POLL_DEADLINE_SECONDS STARTUP_MAX_RETRIES \
  STARTUP_RETRY_INTERVAL_SECONDS NORMAL_POLL_INTERVAL_SECONDS; do
  if [[ -z "${!requiredVar:-}" ]]; then
    echo "ERROR: required environment variable '$requiredVar' is not set." >&2
    exit 2
  fi
done

echo "##vso[task.setvariable variable=runCommandName]$RUN_COMMAND_NAME"
echo "##vso[task.setvariable variable=stagingIndeterminate]false"

echo "Submitting Managed Run Command '$RUN_COMMAND_NAME' (script: $SCRIPT_TO_SUBMIT, guest timeout: ${GUEST_TIMEOUT_SECONDS}s, poll deadline: ${POLL_DEADLINE_SECONDS}s)..."
if ! az vm run-command create \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "$RUN_COMMAND_NAME" \
  --script "@${SCRIPT_TO_SUBMIT}" \
  --timeout-in-seconds "$GUEST_TIMEOUT_SECONDS" \
  --no-wait; then
  echo "ERROR: 'az vm run-command create' itself failed (a permanent submission error, e.g. authorization or a malformed request) -- surfacing immediately rather than polling." >&2
  exit 1
fi

startTime=$(date +%s)
startupRetryCount=0
everSeenExecutionState=false
executionState=""
showOutput=""

while :; do
  now=$(date +%s)
  elapsed=$((now - startTime))
  if [[ $elapsed -ge $POLL_DEADLINE_SECONDS ]]; then
    echo "ERROR: polling deadline of ${POLL_DEADLINE_SECONDS}s exceeded without Azure ever reporting a terminal execution state for '$RUN_COMMAND_NAME'. Its real-world state cannot be conclusively determined -- it may still be executing in the guest." >&2
    echo "##vso[task.setvariable variable=stagingIndeterminate]true"
    exit 1
  fi

  showStderrFile=$(mktemp)
  if showOutput=$(az vm run-command show \
    --resource-group "$RESOURCE_GROUP" \
    --vm-name "$VM_NAME" \
    --name "$RUN_COMMAND_NAME" \
    --instance-view \
    --output json 2>"$showStderrFile"); then
    showExitCode=0
  else
    showExitCode=$?
  fi
  showStderr=$(cat "$showStderrFile")
  rm -f "$showStderrFile"

  if [[ $showExitCode -ne 0 ]]; then
    if [[ "$everSeenExecutionState" == "false" ]] && echo "$showStderr" | grep -qiE 'ResourceNotFound|could not be found|NotFound'; then
      startupRetryCount=$((startupRetryCount + 1))
      if [[ $startupRetryCount -gt $STARTUP_MAX_RETRIES ]]; then
        echo "ERROR: Managed Run Command '$RUN_COMMAND_NAME' never became visible after $STARTUP_MAX_RETRIES bounded startup retries. Its real-world state cannot be conclusively determined." >&2
        echo "##vso[task.setvariable variable=stagingIndeterminate]true"
        exit 1
      fi
      echo "Startup retry $startupRetryCount/$STARTUP_MAX_RETRIES: command not yet visible ($showStderr); retrying in ${STARTUP_RETRY_INTERVAL_SECONDS}s..."
      sleep "$STARTUP_RETRY_INTERVAL_SECONDS"
      continue
    fi
    echo "ERROR: 'az vm run-command show --instance-view' failed for '$RUN_COMMAND_NAME' with a non-transient error -- surfacing immediately rather than retrying: $showStderr" >&2
    echo "##vso[task.setvariable variable=stagingIndeterminate]true"
    exit 1
  fi

  executionState=$(echo "$showOutput" | jq -r '.instanceView.executionState // empty')

  if [[ -z "$executionState" ]]; then
    if [[ "$everSeenExecutionState" == "false" ]]; then
      startupRetryCount=$((startupRetryCount + 1))
      if [[ $startupRetryCount -gt $STARTUP_MAX_RETRIES ]]; then
        echo "ERROR: Managed Run Command '$RUN_COMMAND_NAME' is visible but never reported an instanceView.executionState after $STARTUP_MAX_RETRIES bounded startup retries. Its real-world state cannot be conclusively determined." >&2
        echo "##vso[task.setvariable variable=stagingIndeterminate]true"
        exit 1
      fi
      echo "Startup retry $startupRetryCount/$STARTUP_MAX_RETRIES: resource visible but instanceView.executionState not yet reported; retrying in ${STARTUP_RETRY_INTERVAL_SECONDS}s..."
      sleep "$STARTUP_RETRY_INTERVAL_SECONDS"
      continue
    fi
    # executionState was observed at least once before and is now
    # unexpectedly empty on this single poll -- treat as an ordinary
    # transient read, not a renewed startup condition, and keep polling
    # at the normal interval under the same overall deadline.
    echo "WARNING: instanceView.executionState was unexpectedly empty on this poll after previously being observed; retrying at the normal interval."
    sleep "$NORMAL_POLL_INTERVAL_SECONDS"
    continue
  fi

  everSeenExecutionState=true
  echo "Poll at ${elapsed}s: executionState=$executionState"
  if [[ "$executionState" == "Succeeded" || "$executionState" == "Failed" || "$executionState" == "Canceled" ]]; then
    break
  fi
  sleep "$NORMAL_POLL_INTERVAL_SECONDS"
done

exitCode=$(echo "$showOutput" | jq -r '.instanceView.exitCode // empty')
outputText=$(echo "$showOutput" | jq -r '.instanceView.output // empty')
errorText=$(echo "$showOutput" | jq -r '.instanceView.error // empty')

echo "===== Managed Run Command result ====="
echo "Name           : $RUN_COMMAND_NAME"
echo "ExecutionState : $executionState"
echo "ExitCode       : ${exitCode:-<missing>}"
echo "---- Guest script output (compact summary) ----"
echo "$outputText"
if [[ -n "$errorText" ]]; then
  echo "---- Guest script error ----"
  echo "$errorText"
fi
echo "======================================="

if [[ "$executionState" != "Succeeded" ]]; then
  echo "ERROR: Managed Run Command executionState was '$executionState' (expected 'Succeeded')." >&2
  exit 1
fi
if [[ -z "$exitCode" ]]; then
  echo "ERROR: executionState was 'Succeeded' but no exitCode was reported; the result cannot be conclusively verified." >&2
  echo "##vso[task.setvariable variable=stagingIndeterminate]true"
  exit 1
fi
if [[ "$exitCode" != "0" ]]; then
  echo "ERROR: guest script exited with code $exitCode (expected 0)." >&2
  exit 1
fi

echo "Managed Run Command '$RUN_COMMAND_NAME' succeeded with exit code 0."
exit 0

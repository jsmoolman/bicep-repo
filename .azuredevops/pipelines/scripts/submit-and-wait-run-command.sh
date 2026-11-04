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
#   DEV_SUBSCRIPTION_ID         Pinned DEV subscription ID. Passed
#                                explicitly as `--subscription` on every
#                                `az vm run-command create`/`show` call in
#                                this script -- never relied on implicitly
#                                via `az account set`/the service
#                                connection's own default context, which
#                                could silently differ from this pinned
#                                value.
#   RESOURCE_GROUP              Pinned resource group of the target VM.
#   VM_NAME                     Pinned name of the target VM.
#   SCRIPT_TO_SUBMIT            Repository-relative path to the script to
#                                submit. Its contents are read directly by
#                                this script and passed to `az vm
#                                run-command create --script` as a single
#                                literal argument -- never via the
#                                "@<path>" az CLI file-content convention,
#                                which sends the literal path string "as
#                                is" for this command (there is no file
#                                on the guest, or on the Azure control
#                                plane's side, for "@<path>" to resolve
#                                against) and was observed to make
#                                PowerShell reject the literal "@..."
#                                text itself as invalid syntax on line 1.
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
#   - Pipeline variable `stagingIndeterminate` defaults to exactly "true"
#     the moment submission starts (set in the same breath as
#     `runCommandName`, before `az vm run-command create` is even
#     called) and stays "true" -- the safe, retain-by-default state --
#     through every ambiguous outcome: the `create` call itself failing
#     or losing its response, the polling deadline being reached, the
#     command never becoming observable within the bounded
#     startup-retry budget, a non-transient CLI error occurring
#     mid-poll, Azure reporting a terminal "Succeeded" state without an
#     exit code, or this script (or the job running it) being
#     interrupted at any point before it can record a conclusive
#     outcome -- in every one of those cases the pipeline variable's
#     last recorded value is "true", never silently "false". It is
#     explicitly flipped to "false" -- cleanup opted in -- only once a
#     terminal execution state ("Succeeded", "Failed", or "Canceled")
#     has actually been observed, and is flipped back to "true" in the
#     one specific case where that terminal state is "Succeeded" but no
#     exit code accompanies it (still ambiguous even though terminal).
#
# Exit code: 0 only when Azure reports executionState "Succeeded" and the
# guest script's own exit code is exactly 0. Non-zero in every other case,
# including every indeterminate case above -- "indeterminate" is reported
# as a pipeline failure, never silently treated as success.
set -uo pipefail

for requiredVar in DEV_SUBSCRIPTION_ID RESOURCE_GROUP VM_NAME SCRIPT_TO_SUBMIT \
  RUN_COMMAND_NAME GUEST_TIMEOUT_SECONDS POLL_DEADLINE_SECONDS \
  STARTUP_MAX_RETRIES STARTUP_RETRY_INTERVAL_SECONDS NORMAL_POLL_INTERVAL_SECONDS; do
  if [[ -z "${!requiredVar:-}" ]]; then
    echo "ERROR: required environment variable '$requiredVar' is not set." >&2
    exit 2
  fi
done

print_retention_guidance() {
  echo "Run-command name: $RUN_COMMAND_NAME"
  echo "Its real-world state has not been conclusively determined by this run -- it is being retained rather than deleted. Inspect it manually with:"
  echo "  az vm run-command show --subscription $DEV_SUBSCRIPTION_ID --resource-group $RESOURCE_GROUP --vm-name $VM_NAME --name $RUN_COMMAND_NAME --instance-view"
}

# Read the pinned script's content into a Bash variable up front -- before
# anything is recorded or submitted -- so a read failure or an empty file
# is caught while nothing has happened yet (no run-command resource
# created, no pipeline variables set for cleanup to act on). This also
# means the real script content, not a path string, is what gets passed
# to `az vm run-command create --script` below: the previous "@<path>"
# convention sent that literal path text to Azure, which is not a
# supported way to reference a file for this command and made PowerShell
# reject the literal "@..." text as invalid syntax on line 1 in the
# guest. The script body itself is never echoed anywhere below, to keep
# it out of pipeline logs.
if ! script_content=$(cat -- "$SCRIPT_TO_SUBMIT"); then
  echo "ERROR: failed to read script content from '$SCRIPT_TO_SUBMIT'; nothing has been submitted." >&2
  exit 2
fi
if [[ -z "$script_content" ]]; then
  echo "ERROR: script content read from '$SCRIPT_TO_SUBMIT' is empty; nothing has been submitted." >&2
  exit 2
fi

# Retain-by-default: set together, before submission is even attempted,
# so that any interruption after this point -- a lost `create` response,
# a cancelled job, an agent disconnect -- leaves the pipeline variable's
# last recorded value at "true" rather than an unset/false default that
# would wrongly permit cleanup to delete a resource that may still be
# executing.
echo "##vso[task.setvariable variable=runCommandName]$RUN_COMMAND_NAME"
echo "##vso[task.setvariable variable=stagingIndeterminate]true"

echo "Submitting Managed Run Command '$RUN_COMMAND_NAME' (subscription: $DEV_SUBSCRIPTION_ID, script: $SCRIPT_TO_SUBMIT, guest timeout: ${GUEST_TIMEOUT_SECONDS}s, poll deadline: ${POLL_DEADLINE_SECONDS}s)..."
if ! az vm run-command create \
  --subscription "$DEV_SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "$RUN_COMMAND_NAME" \
  --script "$script_content" \
  --timeout-in-seconds "$GUEST_TIMEOUT_SECONDS" \
  --no-wait; then
  echo "ERROR: 'az vm run-command create' itself failed, or its response was lost -- whether Azure actually accepted this submission cannot be determined, so it is treated as indeterminate rather than 'nothing was created'." >&2
  print_retention_guidance
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
    print_retention_guidance
    exit 1
  fi

  showStderrFile=$(mktemp)
  if showOutput=$(az vm run-command show \
    --subscription "$DEV_SUBSCRIPTION_ID" \
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
        print_retention_guidance
        exit 1
      fi
      echo "Startup retry $startupRetryCount/$STARTUP_MAX_RETRIES: command not yet visible ($showStderr); retrying in ${STARTUP_RETRY_INTERVAL_SECONDS}s..."
      sleep "$STARTUP_RETRY_INTERVAL_SECONDS"
      continue
    fi
    echo "ERROR: 'az vm run-command show --instance-view' failed for '$RUN_COMMAND_NAME' with a non-transient error -- surfacing immediately rather than retrying: $showStderr" >&2
    print_retention_guidance
    exit 1
  fi

  executionState=$(echo "$showOutput" | jq -r '.instanceView.executionState // empty')

  if [[ -z "$executionState" ]]; then
    if [[ "$everSeenExecutionState" == "false" ]]; then
      startupRetryCount=$((startupRetryCount + 1))
      if [[ $startupRetryCount -gt $STARTUP_MAX_RETRIES ]]; then
        echo "ERROR: Managed Run Command '$RUN_COMMAND_NAME' is visible but never reported an instanceView.executionState after $STARTUP_MAX_RETRIES bounded startup retries. Its real-world state cannot be conclusively determined." >&2
        print_retention_guidance
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
    # stagingIndeterminate remains "true" (its retain-by-default value)
    # throughout -- it is never flipped to "false" until a terminal
    # state is actually observed below.
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

# A terminal execution state has now actually been observed -- this is
# the one and only point where cleanup becomes opted in by default.
echo "##vso[task.setvariable variable=stagingIndeterminate]false"

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
  echo "ERROR: executionState was 'Succeeded' but no exitCode was reported; the result cannot be conclusively verified even though a terminal state was reached." >&2
  echo "##vso[task.setvariable variable=stagingIndeterminate]true"
  print_retention_guidance
  exit 1
fi
if [[ "$exitCode" != "0" ]]; then
  echo "ERROR: guest script exited with code $exitCode (expected 0)." >&2
  exit 1
fi

echo "Managed Run Command '$RUN_COMMAND_NAME' succeeded with exit code 0."
exit 0

#!/usr/bin/env bash
# Standalone extraction of the Managed Run Command polling/verification
# logic from .azuredevops/pipelines/stage-lims-ws2025-dev-sql-media.yml's
# "Submit Managed Run Command and wait for a terminal execution state"
# step, for local validation against fixture `az vm run-command show
# --instance-view` JSON without any real Azure CLI / VM dependency.
#
# Usage: FIXTURE_FILE=<path-to-fixture.json> bash staging-pipeline-verify-logic.sh
#
# The fixture file's content is returned verbatim, once, in place of the
# real `az vm run-command show --instance-view --output json` call -- this
# harness never calls `az` and never polls more than once, since each
# fixture is already a single terminal-state (or deliberately malformed)
# snapshot. The real pipeline's poll loop is a thin wrapper around this
# exact same decode-and-verify logic, repeated until one of these terminal
# conditions is reached; that loop's control flow is not re-exercised here
# because it contains no branching logic beyond "retry until terminal or
# budget exceeded", already covered by code inspection.
set -uo pipefail

if [[ -z "${FIXTURE_FILE:-}" ]]; then
  echo "ERROR: FIXTURE_FILE environment variable not set." >&2
  exit 2
fi

showOutput=$(cat "$FIXTURE_FILE")

executionState=$(echo "$showOutput" | jq -e -r '.instanceView.executionState // empty')
decodeStateStatus=$?
if [[ $decodeStateStatus -ne 0 || -z "$executionState" ]]; then
  echo "ERROR: 'az vm run-command show' returned an empty instanceView.executionState; staging result cannot be verified." >&2
  exit 1
fi

echo "executionState=$executionState"

if [[ "$executionState" != "Succeeded" && "$executionState" != "Failed" && "$executionState" != "Canceled" ]]; then
  echo "NOT-TERMINAL: executionState='$executionState' is not yet terminal -- real pipeline would keep polling."
  exit 3
fi

exitCode=$(echo "$showOutput" | jq -e -r '.instanceView.exitCode // empty')
decodeExitStatus=$?
if [[ $decodeExitStatus -ne 0 ]]; then
  echo "ERROR: could not decode instanceView.exitCode from 'az vm run-command show' output; staging result cannot be verified." >&2
  exit 1
fi
outputText=$(echo "$showOutput" | jq -r '.instanceView.output // empty')
errorText=$(echo "$showOutput" | jq -r '.instanceView.error // empty')

echo "===== Managed Run Command result ====="
echo "ExecutionState : $executionState"
echo "ExitCode       : ${exitCode:-<missing>}"
echo "---- Guest script output (compact staging summary) ----"
echo "$outputText"
if [[ -n "$errorText" ]]; then
  echo "---- Guest script error ----"
  echo "$errorText"
fi
echo "======================================="

if [[ "$executionState" != "Succeeded" ]]; then
  echo "ERROR: Managed Run Command executionState was '$executionState' (expected 'Succeeded'); staging failed." >&2
  exit 1
fi
if [[ -z "$exitCode" ]]; then
  echo "ERROR: Managed Run Command did not report an exitCode; staging result cannot be verified." >&2
  exit 1
fi
if [[ "$exitCode" != "0" ]]; then
  echo "ERROR: guest script exited with code $exitCode (expected 0); staging failed." >&2
  exit 1
fi

echo "Managed Run Command succeeded with exit code 0."
exit 0

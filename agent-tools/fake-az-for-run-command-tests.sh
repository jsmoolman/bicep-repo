#!/usr/bin/env bash
# Fake `az` CLI used only to exercise
# .azuredevops/pipelines/scripts/submit-and-wait-run-command.sh and
# .azuredevops/pipelines/scripts/cleanup-run-command.sh locally, without
# any real Azure dependency. Intercepts exactly the three subcommands
# those scripts call (`az vm run-command create ... --no-wait`, `az vm
# run-command show ... --instance-view`, and `az vm run-command delete
# ... --yes`) and returns scripted, scenario-driven responses. Also
# asserts that every one of those calls carries the expected
# `--subscription` value -- a call missing it, or carrying the wrong
# value, is treated as a hard test failure (distinct exit code 7),
# never silently ignored. Everything else is an error, since the real
# scripts under test should never call anything else.
#
# Controlled by:
#   FAKE_AZ_SCENARIO       one of: delayed-success | permanent-failure |
#                                   deadline-expiry | nonzero-exit
#   FAKE_AZ_COUNTER_FILE   path to a counter file this script increments
#                           on every `show` call, to drive a per-scenario
#                           progression across the real script's polling
#                           loop (each poll is a fresh process invocation
#                           of this file, so state must live on disk).
#   FAKE_AZ_EXPECTED_SUBSCRIPTION
#                           the exact --subscription value every
#                           intercepted call must carry.
#   FAKE_AZ_EXPECTED_SCRIPT_FILE
#                           optional; when set, the exact --script value
#                           passed to `vm run-command create` must equal
#                           this file's content byte-for-byte (trailing
#                           newline aside -- both sides are read via
#                           command substitution, which strips it the
#                           same way on both sides). Lets a test assert
#                           that a real, multiline PowerShell fixture
#                           (variables, single/double quotes, newlines
#                           and all) survives into a single --script
#                           argument unmangled. Every `create` call is
#                           checked regardless of this variable for the
#                           regression this fixture exists to catch: a
#                           --script value starting with "@" (the old,
#                           broken "@<path>" convention) is always a
#                           hard failure.
#   FAKE_AZ_EXPECT_PARAMETERS_FLAG
#                           optional; "true" or "false". When set, a
#                           `create` call's presence/absence of the
#                           --parameters flag must match exactly, else a
#                           hard test failure.
#   FAKE_AZ_EXPECTED_PARAMETERS_LIST
#                           optional; when set, the arguments immediately
#                           following --parameters must equal exactly this
#                           NEWLINE-separated list of "name=value" entries
#                           (order-sensitive). Newline-, not
#                           comma-separated, because a "name=value" entry
#                           may itself legitimately contain a comma (e.g.
#                           a CSV-valued parameter) that must not be
#                           mistaken for an entry boundary.
#   FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG
#                           optional; same as FAKE_AZ_EXPECT_PARAMETERS_FLAG
#                           but for --protected-parameters.
#   FAKE_AZ_EXPECTED_PROTECTED_PARAMETERS_LIST
#                           optional; same as
#                           FAKE_AZ_EXPECTED_PARAMETERS_LIST but for the
#                           arguments following --protected-parameters.
set -uo pipefail

scenario="${FAKE_AZ_SCENARIO:?FAKE_AZ_SCENARIO not set}"
counterFile="${FAKE_AZ_COUNTER_FILE:?FAKE_AZ_COUNTER_FILE not set}"
expectedSubscription="${FAKE_AZ_EXPECTED_SUBSCRIPTION:?FAKE_AZ_EXPECTED_SUBSCRIPTION not set}"

assert_subscription_flag() {
  local sawSubscriptionFlag=false
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--subscription" ]]; then
      sawSubscriptionFlag=true
      local actual="${args[$((i + 1))]:-}"
      if [[ "$actual" != "$expectedSubscription" ]]; then
        echo "TEST FAILURE: --subscription was '$actual', expected '$expectedSubscription'." >&2
        exit 7
      fi
    fi
  done
  if [[ "$sawSubscriptionFlag" == "false" ]]; then
    echo "TEST FAILURE: call did not include --subscription at all: $*" >&2
    exit 7
  fi
}

assert_script_flag() {
  local sawScriptFlag=false
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--script" ]]; then
      sawScriptFlag=true
      local actual="${args[$((i + 1))]:-}"
      if [[ "$actual" == @* ]]; then
        echo "TEST FAILURE: --script value still uses the broken '@<path>' convention ('$actual') instead of the literal script content." >&2
        exit 8
      fi
      if [[ -z "$actual" ]]; then
        echo "TEST FAILURE: --script value was empty." >&2
        exit 8
      fi
      if [[ -n "${FAKE_AZ_EXPECTED_SCRIPT_FILE:-}" ]]; then
        local expected
        if ! expected=$(cat -- "$FAKE_AZ_EXPECTED_SCRIPT_FILE"); then
          echo "TEST FAILURE: could not read FAKE_AZ_EXPECTED_SCRIPT_FILE '$FAKE_AZ_EXPECTED_SCRIPT_FILE'." >&2
          exit 8
        fi
        if [[ "$actual" != "$expected" ]]; then
          echo "TEST FAILURE: --script content did not match the expected fixture content from '$FAKE_AZ_EXPECTED_SCRIPT_FILE' (PowerShell variables/quotes/newlines were not preserved as a single argument)." >&2
          exit 8
        fi
      fi
    fi
  done
  if [[ "$sawScriptFlag" == "false" ]]; then
    echo "TEST FAILURE: call did not include --script at all: $*" >&2
    exit 8
  fi
}

assert_multivalue_flag() {
  # $1 = flag name (e.g. --parameters), $2 = expected-present flag var
  # name, $3 = expected newline-separated list var name, remaining args =
  # the full call.
  local flagName="$1"
  local expectPresentVarName="$2"
  local expectedCsvVarName="$3"
  shift 3
  local args=("$@")
  local sawFlag=false
  local collected=()
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "$flagName" ]]; then
      sawFlag=true
      local j=$((i + 1))
      while ((j < ${#args[@]})) && [[ "${args[$j]}" != --* ]]; do
        collected+=("${args[$j]}")
        j=$((j + 1))
      done
      break
    fi
  done

  local expectPresent="${!expectPresentVarName:-}"
  if [[ -n "$expectPresent" ]]; then
    if [[ "$expectPresent" == "true" && "$sawFlag" == "false" ]]; then
      echo "TEST FAILURE: expected '$flagName' to be present, but it was not passed at all: $*" >&2
      exit 10
    fi
    if [[ "$expectPresent" == "false" && "$sawFlag" == "true" ]]; then
      echo "TEST FAILURE: expected '$flagName' to be ABSENT, but it was passed: $*" >&2
      exit 10
    fi
  fi

  local expectedList="${!expectedCsvVarName:-}"
  if [[ -n "$expectedList" ]]; then
    expectedArr=()
    while IFS= read -r expectedLine; do
      [[ -z "$expectedLine" ]] && continue
      expectedArr+=("$expectedLine")
    done <<<"$expectedList"
    if [[ "${#collected[@]}" -ne "${#expectedArr[@]}" ]]; then
      echo "TEST FAILURE: '$flagName' had ${#collected[@]} value(s), expected ${#expectedArr[@]} (expected: $expectedList; actual: ${collected[*]:-<none>})" >&2
      exit 10
    fi
    for ((k = 0; k < ${#expectedArr[@]}; k++)); do
      if [[ "${collected[$k]}" != "${expectedArr[$k]}" ]]; then
        echo "TEST FAILURE: '$flagName' value #$((k + 1)) was '${collected[$k]}', expected '${expectedArr[$k]}'" >&2
        exit 10
      fi
    done
  fi
}

if [[ "$1 $2 $3" == "vm run-command create" ]]; then
  assert_subscription_flag "$@"
  assert_script_flag "$@"
  assert_multivalue_flag "--parameters" "FAKE_AZ_EXPECT_PARAMETERS_FLAG" "FAKE_AZ_EXPECTED_PARAMETERS_LIST" "$@"
  assert_multivalue_flag "--protected-parameters" "FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG" "FAKE_AZ_EXPECTED_PROTECTED_PARAMETERS_LIST" "$@"
  # --no-wait in every scenario here; submission itself always succeeds
  # -- these fixtures are about what happens during polling, not
  # submission itself.
  exit 0
fi

if [[ "$1 $2 $3" == "vm run-command show" ]]; then
  assert_subscription_flag "$@"
  count=0
  if [[ -f "$counterFile" ]]; then
    count=$(cat "$counterFile")
  fi
  count=$((count + 1))
  echo "$count" > "$counterFile"

  case "$scenario" in
    delayed-success)
      # Not yet visible for the first 2 polls, then visible but Running
      # for 1 poll, then Succeeded with exit code 0.
      if [[ $count -le 2 ]]; then
        echo "ERROR: (ResourceNotFound) The entity was not found." >&2
        exit 3
      elif [[ $count -eq 3 ]]; then
        echo '{"instanceView":{"executionState":"Running","exitCode":null,"output":"","error":""}}'
        exit 0
      else
        echo '{"instanceView":{"executionState":"Succeeded","exitCode":0,"output":"===== LIMS SQL v2 installation-media staging: SUCCESS =====\nDestination: C:\\SQLMedia\\SQL2022","error":""}}'
        exit 0
      fi
      ;;
    permanent-failure)
      # A non-transient error on the very first poll -- must fail
      # immediately, never be mistaken for "not yet visible".
      echo "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Compute/virtualMachines/runCommands/read'." >&2
      exit 1
      ;;
    deadline-expiry)
      # Always visible, always Running, never reaches a terminal state --
      # the caller's own wall-clock poll deadline must be what stops this,
      # not this fixture.
      echo '{"instanceView":{"executionState":"Running","exitCode":null,"output":"","error":""}}'
      exit 0
      ;;
    nonzero-exit)
      # Visible and terminal immediately, but the guest script itself
      # failed.
      echo '{"instanceView":{"executionState":"Succeeded","exitCode":1,"output":"","error":"Assert-StagingTargetIdentity: guest hostname mismatch."}}'
      exit 0
      ;;
    *)
      echo "ERROR: unknown FAKE_AZ_SCENARIO '$scenario'" >&2
      exit 9
      ;;
  esac
fi

if [[ "$1 $2 $3" == "vm run-command delete" ]]; then
  assert_subscription_flag "$@"
  echo "fake az: deleted run-command resource"
  exit 0
fi

echo "ERROR: fake az received an unexpected command: $*" >&2
exit 9

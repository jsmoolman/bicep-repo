$env:PATH = "C:\Source\bicep-repo\bicep-repo\agent-tools\fake-bin;C:\Users\moolman\AppData\Local\Microsoft\WinGet\Packages\jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe;C:\Program Files\Git\usr\bin;C:\Program Files\Git\bin;$env:PATH"

$DEV_SUB = "8ebb26a1-674a-40d1-97f8-e0a237e288a6"
$WRONG_SUB = "11111111-1111-1111-1111-111111111111"
$bash = "C:\Program Files\Git\usr\bin\bash.exe"

function Run-Submit($scenario, $expectedSub, $devSubToPass, $extraEnv) {
    Remove-Item -Force -ErrorAction SilentlyContinue "agent-tools\fake-counter-$scenario.txt"
    $env:FAKE_AZ_SCENARIO = $scenario
    $env:FAKE_AZ_COUNTER_FILE = "/c/Source/bicep-repo/bicep-repo/agent-tools/fake-counter-$scenario.txt"
    $env:FAKE_AZ_EXPECTED_SUBSCRIPTION = $expectedSub
    $env:DEV_SUBSCRIPTION_ID = $devSubToPass
    $env:RESOURCE_GROUP = "rg-compute-lims-dev-westeu"
    $env:VM_NAME = "vm-lims-dev-v2-westeu-002"
    $env:SCRIPT_TO_SUBMIT = "operations/compute/lims-ws2025-dev-sql-media-staging/Stage-LimsSqlInstallationMedia.ps1"
    $env:RUN_COMMAND_NAME = "test-$scenario"
    $env:GUEST_TIMEOUT_SECONDS = "2400"
    $env:POLL_DEADLINE_SECONDS = "2700"
    $env:STARTUP_MAX_RETRIES = "20"
    $env:STARTUP_RETRY_INTERVAL_SECONDS = "1"
    $env:NORMAL_POLL_INTERVAL_SECONDS = "1"
    foreach ($k in $extraEnv.Keys) { Set-Item -Path "env:$k" -Value $extraEnv[$k] }
    $out = & $bash --noprofile --norc ".azuredevops/pipelines/scripts/submit-and-wait-run-command.sh" 2>&1
    $exit = $LASTEXITCODE
    foreach ($k in $extraEnv.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
    Remove-Item -Path "env:RUN_COMMAND_PARAMETERS","env:RUN_COMMAND_PROTECTED_PARAMETERS","env:FAKE_AZ_EXPECT_PARAMETERS_FLAG","env:FAKE_AZ_EXPECTED_PARAMETERS_LIST","env:FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG","env:FAKE_AZ_EXPECTED_PROTECTED_PARAMETERS_LIST" -ErrorAction SilentlyContinue
    $indeterminateLines = $out | Select-String -Pattern '##vso\[task\.setvariable variable=stagingIndeterminate\](\w+)'
    $finalIndeterminate = if ($indeterminateLines) { $indeterminateLines[-1].Matches[0].Groups[1].Value } else { "<none>" }
    return @{ Output = $out; Exit = $exit; Indeterminate = $finalIndeterminate }
}

function Run-Cleanup($runCommandName, $indeterminate, $expectedSub, $devSubToPass) {
    $env:FAKE_AZ_SCENARIO = "delayed-success"  # irrelevant for delete path, just needs to be a valid value
    $env:FAKE_AZ_COUNTER_FILE = "/c/Source/bicep-repo/bicep-repo/agent-tools/fake-counter-cleanup.txt"
    $env:FAKE_AZ_EXPECTED_SUBSCRIPTION = $expectedSub
    $env:DEV_SUBSCRIPTION_ID = $devSubToPass
    $env:RESOURCE_GROUP = "rg-compute-lims-dev-westeu"
    $env:VM_NAME = "vm-lims-dev-v2-westeu-002"
    $env:RUN_COMMAND_NAME = $runCommandName
    $env:STAGING_INDETERMINATE = $indeterminate
    $out = & $bash --noprofile --norc ".azuredevops/pipelines/scripts/cleanup-run-command.sh" 2>&1
    $exit = $LASTEXITCODE
    Remove-Item -Path "env:FAKE_AZ_SCENARIO","env:FAKE_AZ_COUNTER_FILE","env:FAKE_AZ_EXPECTED_SUBSCRIPTION","env:DEV_SUBSCRIPTION_ID","env:RESOURCE_GROUP","env:VM_NAME","env:RUN_COMMAND_NAME","env:STAGING_INDETERMINATE" -ErrorAction SilentlyContinue
    return @{ Output = $out; Exit = $exit; Deleted = ($out -join "`n") -match 'deleted run-command resource' }
}

$fail = $false

Write-Host "=========== 1. delayed-success (subscription correct) ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
if ($r.Exit -ne 0 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 0, indeterminate=false" -ForegroundColor Red; $fail = $true }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
Write-Host "---cleanup---"
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: cleanup deleted as expected" -ForegroundColor Green }

Write-Host "`n=========== 2. permanent-failure (indeterminate -> cleanup must skip) ==========="
$r = Run-Submit "permanent-failure" $DEV_SUB $DEV_SUB @{}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
if ($r.Exit -ne 1 -or $r.Indeterminate -ne "true") { Write-Host "FAIL: expected exit 1, indeterminate=true" -ForegroundColor Red; $fail = $true }
$c = Run-Cleanup "test-permanent-failure" $r.Indeterminate $DEV_SUB $DEV_SUB
Write-Host "---cleanup---"
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or $c.Deleted) { Write-Host "FAIL: expected cleanup to SKIP deletion" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: cleanup skipped deletion as expected" -ForegroundColor Green }

Write-Host "`n=========== 3. deadline-expiry (indeterminate -> cleanup must skip) ==========="
$r = Run-Submit "deadline-expiry" $DEV_SUB $DEV_SUB @{ POLL_DEADLINE_SECONDS = "3" }
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
if ($r.Exit -ne 1 -or $r.Indeterminate -ne "true") { Write-Host "FAIL: expected exit 1, indeterminate=true" -ForegroundColor Red; $fail = $true }
$c = Run-Cleanup "test-deadline-expiry" $r.Indeterminate $DEV_SUB $DEV_SUB
Write-Host "---cleanup---"
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or $c.Deleted) { Write-Host "FAIL: expected cleanup to SKIP deletion" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: cleanup skipped deletion as expected" -ForegroundColor Green }

Write-Host "`n=========== 4. nonzero-exit (determinate failure -> cleanup must still delete) ==========="
$r = Run-Submit "nonzero-exit" $DEV_SUB $DEV_SUB @{}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
if ($r.Exit -ne 1 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 1, indeterminate=false" -ForegroundColor Red; $fail = $true }
$c = Run-Cleanup "test-nonzero-exit" $r.Indeterminate $DEV_SUB $DEV_SUB
Write-Host "---cleanup---"
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate failure)" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: cleanup deleted as expected" -ForegroundColor Green }

Write-Host "`n=========== 5. Negative control: wrong subscription passed to submit script ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $WRONG_SUB @{}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit)"
if (($r.Output -join "`n") -notmatch 'TEST FAILURE.*--subscription') { Write-Host "FAIL: expected the fake az harness to catch the wrong --subscription value" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: harness correctly caught the wrong subscription" -ForegroundColor Green }

Write-Host "`n=========== 6. Cleanup with no RUN_COMMAND_NAME recorded (nothing submitted) ==========="
$c = Run-Cleanup "" "true" $DEV_SUB $DEV_SUB
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or $c.Deleted) { Write-Host "FAIL: expected a no-op" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: no-op as expected" -ForegroundColor Green }

Write-Host "`n=========== 7. Cleanup with STAGING_INDETERMINATE entirely unset (must default to retain) ==========="
$c = Run-Cleanup "test-unset-indeterminate" $null $DEV_SUB $DEV_SUB
Write-Host ($c.Output -join "`n")
if ($c.Exit -ne 0 -or $c.Deleted) { Write-Host "FAIL: expected retain-by-default to skip deletion" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: retained by default as expected" -ForegroundColor Green }

Write-Host "`n=========== 8. --script receives the real multiline PowerShell source as one argument, verbatim ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    SCRIPT_TO_SUBMIT              = "agent-tools/fixtures/fake-script-with-vars-and-quotes.ps1"
    FAKE_AZ_EXPECTED_SCRIPT_FILE  = "agent-tools/fixtures/fake-script-with-vars-and-quotes.ps1"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
if ($r.Exit -ne 0 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 0, indeterminate=false" -ForegroundColor Red; $fail = $true }
if (($r.Output -join "`n") -match 'TEST FAILURE') { Write-Host "FAIL: fake az reported a --script content mismatch" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: --script content matched the fixture's PowerShell variables/quotes/newlines exactly" -ForegroundColor Green }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true }

Write-Host "`n=========== 9. Missing SCRIPT_TO_SUBMIT file prevents submission entirely ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    SCRIPT_TO_SUBMIT = "agent-tools/fixtures/does-not-exist.ps1"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit)"
$joined = $r.Output -join "`n"
if ($r.Exit -ne 2) { Write-Host "FAIL: expected exit 2 for a read failure" -ForegroundColor Red; $fail = $true }
if ($joined -notmatch 'failed to read script content') { Write-Host "FAIL: expected a read-failure error message" -ForegroundColor Red; $fail = $true }
if ($joined -match '##vso\[task\.setvariable variable=runCommandName\]') { Write-Host "FAIL: runCommandName must not be recorded before the script is successfully read" -ForegroundColor Red; $fail = $true }
if ($joined -match 'Submitting Managed Run Command') { Write-Host "FAIL: submission must never be attempted when the script cannot be read" -ForegroundColor Red; $fail = $true }
if (-not $fail) { Write-Host "OK: read failure caught before anything was recorded or submitted" -ForegroundColor Green }

Write-Host "`n=========== 10. Empty SCRIPT_TO_SUBMIT file prevents submission entirely ==========="
New-Item -ItemType File -Force -Path "agent-tools/fixtures/fake-script-empty.ps1" | Out-Null
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    SCRIPT_TO_SUBMIT = "agent-tools/fixtures/fake-script-empty.ps1"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit)"
$joined = $r.Output -join "`n"
if ($r.Exit -ne 2) { Write-Host "FAIL: expected exit 2 for empty content" -ForegroundColor Red; $fail = $true }
if ($joined -notmatch 'script content read from .* is empty') { Write-Host "FAIL: expected an empty-content error message" -ForegroundColor Red; $fail = $true }
if ($joined -match '##vso\[task\.setvariable variable=runCommandName\]') { Write-Host "FAIL: runCommandName must not be recorded for an empty script" -ForegroundColor Red; $fail = $true }
if ($joined -match 'Submitting Managed Run Command') { Write-Host "FAIL: submission must never be attempted for an empty script" -ForegroundColor Red; $fail = $true }
if (-not $fail) { Write-Host "OK: empty content caught before anything was recorded or submitted" -ForegroundColor Green }

Write-Host "`n=========== 11. Regression guard: --script must never use the broken '@<path>' convention ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{}
$joined = $r.Output -join "`n"
if ($joined -match 'TEST FAILURE.*--script') { Write-Host "FAIL: fake az detected a regression to the '@<path>' --script convention" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: --script carries literal content, not an '@<path>' reference" -ForegroundColor Green }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true }

Write-Host "`n=========== 12. RUN_COMMAND_PARAMETERS / RUN_COMMAND_PROTECTED_PARAMETERS both unset -- regression check, no flags passed at all ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    FAKE_AZ_EXPECT_PARAMETERS_FLAG           = "false"
    FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG = "false"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
$joined = $r.Output -join "`n"
if ($r.Exit -ne 0 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 0, indeterminate=false" -ForegroundColor Red; $fail = $true }
if ($joined -match 'TEST FAILURE') { Write-Host "FAIL: fake az reported a --parameters/--protected-parameters flag-presence mismatch" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: no --parameters/--protected-parameters flag passed when both variables are unset" -ForegroundColor Green }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true }

Write-Host "`n=========== 13. RUN_COMMAND_PARAMETERS forwards multiple newline-separated name=value pairs intact, in order (including a value that itself contains a comma) ==========="
$paramLines = @(
    "WindowsSqlAdminPrincipalsCsv=BUILTIN\Administrators,AzureAD\group@tenant.onmicrosoft.com"
    "DataPath=E:\MSSQL\DATA"
    "TempDbFileCount=8"
)
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    RUN_COMMAND_PARAMETERS        = ($paramLines -join "`n")
    FAKE_AZ_EXPECT_PARAMETERS_FLAG = "true"
    FAKE_AZ_EXPECTED_PARAMETERS_LIST = ($paramLines -join "`n")
    FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG = "false"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
$joined = $r.Output -join "`n"
if ($r.Exit -ne 0 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 0, indeterminate=false" -ForegroundColor Red; $fail = $true }
if ($joined -match 'TEST FAILURE') { Write-Host "FAIL: fake az reported a --parameters mismatch" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: --parameters forwarded intact, in order, as separate name=value arguments" -ForegroundColor Green }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true }

Write-Host "`n=========== 14. RUN_COMMAND_PROTECTED_PARAMETERS is forwarded to --protected-parameters, and never echoed into this script's own output ==========="
$r = Run-Submit "delayed-success" $DEV_SUB $DEV_SUB @{
    RUN_COMMAND_PROTECTED_PARAMETERS        = "SaPassword=Sup3r`$ecretValueThatMustNeverAppear!"
    FAKE_AZ_EXPECT_PROTECTED_PARAMETERS_FLAG = "true"
    FAKE_AZ_EXPECTED_PROTECTED_PARAMETERS_LIST = "SaPassword=Sup3r`$ecretValueThatMustNeverAppear!"
    FAKE_AZ_EXPECT_PARAMETERS_FLAG           = "false"
}
Write-Host ($r.Output -join "`n")
Write-Host "Exit=$($r.Exit) Indeterminate=$($r.Indeterminate)"
$joined = $r.Output -join "`n"
if ($r.Exit -ne 0 -or $r.Indeterminate -ne "false") { Write-Host "FAIL: expected exit 0, indeterminate=false" -ForegroundColor Red; $fail = $true }
if ($joined -match 'TEST FAILURE') { Write-Host "FAIL: fake az reported a --protected-parameters mismatch" -ForegroundColor Red; $fail = $true }
if ($joined -match 'Sup3r\$ecretValueThatMustNeverAppear!') { Write-Host "FAIL: the secret value leaked into the submit script's own stdout/stderr output" -ForegroundColor Red; $fail = $true } else { Write-Host "OK: --protected-parameters forwarded to az, and the secret value never appeared in this script's own output" -ForegroundColor Green }
$c = Run-Cleanup "test-delayed-success" $r.Indeterminate $DEV_SUB $DEV_SUB
if ($c.Exit -ne 0 -or -not $c.Deleted) { Write-Host "FAIL: expected cleanup to delete (determinate success)" -ForegroundColor Red; $fail = $true }

Write-Host "`n`n==================== OVERALL: $(if ($fail) { 'FAIL' } else { 'PASS' }) ====================" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })

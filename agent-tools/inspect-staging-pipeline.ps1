$json = Get-Content agent-tools\yaml-parse-out.json -Raw | ConvertFrom-Json
Write-Host ('Trigger: ' + $json.trigger + ' | PR: ' + $json.pr)
Write-Host ('Parameters: ' + ($json.parameters | ForEach-Object { $_.name }) -join ', ')
Write-Host ('Pool: ' + ($json.pool.vmImage))
Write-Host ('Steps count: ' + $json.steps.Count)
$i = 0
foreach ($s in $json.steps) {
    $label = if ($s.checkout) { "checkout: $($s.checkout)" } else { $s.displayName }
    Write-Host ("[$i] $label  condition=$($s.condition)")
    $i++
}

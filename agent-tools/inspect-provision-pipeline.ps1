$json = Get-Content agent-tools\yaml-provision-out.json -Raw | ConvertFrom-Json
Write-Host ('Trigger: ' + $json.trigger + ' | PR: ' + $json.pr)
Write-Host ('Parameters: ' + (($json.parameters | ForEach-Object { $_.name + '=' + $_.default }) -join ', '))
$actionParam = $json.parameters | Where-Object { $_.name -eq 'action' }
Write-Host ('action values: ' + ($actionParam.values -join ', '))
Write-Host ('Variables: ' + (($json.variables | ForEach-Object { $_.name + '=' + $_.value }) -join '; '))
Write-Host ('Jobs count: ' + $json.jobs.Count)
$job = $json.jobs[0]
Write-Host ('Job name: ' + $job.job + ' timeoutInMinutes=' + $job.timeoutInMinutes + ' pool=' + $job.pool.vmImage)
Write-Host ('Steps count: ' + $job.steps.Count)
$i = 0
foreach ($s in $job.steps) {
    if ($s.checkout) {
        Write-Host "[$i] checkout: $($s.checkout)"
    } elseif ($s.PSObject.Properties.Name -contains '${{ if eq(parameters.action, ''stage-only'') }}') {
        Write-Host "[$i] (conditional stage-only block)"
    } else {
        Write-Host "[$i] $($s.displayName)  condition=$($s.condition)"
    }
    $i++
}

Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force
$scriptsDir = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts'
$settings = Join-Path $scriptsDir 'PSScriptAnalyzerSettings.psd1'
$files = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' | Where-Object { $_.Name -notlike '*.Tests.ps1' }
$allResults = @()
foreach ($f in $files) {
    Write-Output "== Analyzing $($f.Name) =="
    $results = Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -Severity Warning,Error
    $allResults += $results
    if ($results) { $results | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-String -Width 300 | Write-Output }
    else { Write-Output "No issues." }
}
Write-Output "TOTAL ISSUES: $($allResults.Count)"

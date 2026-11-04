Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force
$files = @(
    @{Path='operations\compute\lims-ws2025-dev-sql-install\Install-LimsSqlServer.ps1'; Settings='operations\compute\lims-ws2025-dev-sql-install\PSScriptAnalyzerSettings.psd1'},
    @{Path='operations\compute\lims-ws2025-dev-sql-media-staging\Stage-LimsSqlInstallationMedia.ps1'; Settings='operations\compute\lims-ws2025-dev-sql-media-staging\PSScriptAnalyzerSettings.psd1'}
)
$anyIssues = $false
foreach ($f in $files) {
    Write-Host "=== $($f.Path) ==="
    $results = Invoke-ScriptAnalyzer -Path $f.Path -Settings $f.Settings
    if ($results) { $anyIssues = $true; $results | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-String -Width 400 }
    else { Write-Host 'No issues found.' }
}
if ($anyIssues) { exit 1 } else { exit 0 }

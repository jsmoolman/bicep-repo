$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
$scriptFiles = @(Get-ChildItem -Path . -Recurse -Filter '*.ps1' | Where-Object { $_.Name -notlike '*.Tests.ps1' })
if ($scriptFiles.Count -eq 0) {
    Write-Host 'No PowerShell scripts found — nothing to analyze.'
    exit 0
}
$failed = $false
foreach ($file in $scriptFiles) {
    $settingsPath = Join-Path $file.DirectoryName 'PSScriptAnalyzerSettings.psd1'
    Write-Host "== PSScriptAnalyzer: $($file.FullName) =="
    if (Test-Path -LiteralPath $settingsPath) {
        $results = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath)
    }
    else {
        $results = @(Invoke-ScriptAnalyzer -Path $file.FullName)
    }
    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize RuleName, Severity, Line, Message
        $failed = $true
    }
}
if ($failed) { exit 1 }
Write-Host 'No PSScriptAnalyzer issues found.'

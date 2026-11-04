$errors = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile('C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Get-LimsGuestDiskDiagnostics.ps1', [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Output $_.ToString() }
} else {
    Write-Output 'OK: no parse errors'
}
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force
$settings = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\PSScriptAnalyzerSettings.psd1'
$results = Invoke-ScriptAnalyzer -Path 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Get-LimsGuestDiskDiagnostics.ps1' -Settings $settings -Severity Warning,Error
if ($results) { $results | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-String -Width 300 } else { Write-Output 'No PSSA issues.' }

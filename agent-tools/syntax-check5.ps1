$errors = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile('C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1', [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Output $_.ToString() }
} else {
    Write-Output 'OK: no parse errors'
}

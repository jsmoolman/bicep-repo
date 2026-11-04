$p = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'
$raw = Get-Content -Raw -LiteralPath $p
Write-Output ('Length: ' + $raw.Length)
$crlfNormalized = ($raw -replace "`r`n", "`n") -replace "`n", "`r`n"
Write-Output ('CRLF-normalized length: ' + $crlfNormalized.Length)
$t = $null
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
Write-Output ('ParseErrors: ' + $e.Count)

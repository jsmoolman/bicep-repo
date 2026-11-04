param([int[]] $StartLines)
$path = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$comments = $tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset }

foreach ($sl in $StartLines) {
    $first = $comments | Where-Object { $_.Extent.StartLineNumber -eq $sl } | Select-Object -First 1
    if (-not $first) { Write-Output "NOT FOUND for StartLine $sl"; continue }
    # Walk forward through consecutive-line comments to find the run end matching our known EndLine from the table (pass via separate param instead)
    [pscustomobject]@{ StartLine = $sl; StartOffset = $first.Extent.StartOffset }
}

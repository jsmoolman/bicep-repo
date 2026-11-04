$path = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$raw = Get-Content -Raw -LiteralPath $path
$comments = $tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text.Length -gt 150 } | Sort-Object { $_.Extent.StartLineNumber }
foreach ($c in $comments) {
    $lineStart = $raw.LastIndexOf("`n", $c.Extent.StartOffset) + 1
    $indent = $raw.Substring($lineStart, $c.Extent.StartOffset - $lineStart)
    [pscustomobject]@{
        StartLine  = $c.Extent.StartLineNumber
        EndLine    = $c.Extent.EndLineNumber
        Length     = $c.Text.Length
        StartOffset = $c.Extent.StartOffset
        EndOffset  = $c.Extent.EndOffset
        Indent     = $indent
    }
}

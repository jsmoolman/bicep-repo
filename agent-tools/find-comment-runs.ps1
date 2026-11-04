$path = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$raw = Get-Content -Raw -LiteralPath $path
$comments = $tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset }

$runs = @()
$current = $null
foreach ($c in $comments) {
    if ($null -ne $current -and $c.Extent.StartLineNumber -eq ($current.EndLine + 1) -and -not $c.Text.StartsWith('<#')) {
        $current.EndLine = $c.Extent.EndLineNumber
        $current.EndOffset = $c.Extent.EndOffset
        $current.Length += $c.Text.Length
        $current.Count += 1
    }
    else {
        if ($current) { $runs += [pscustomobject]$current }
        $current = @{
            StartLine   = $c.Extent.StartLineNumber
            EndLine     = $c.Extent.EndLineNumber
            StartOffset = $c.Extent.StartOffset
            EndOffset   = $c.Extent.EndOffset
            Length      = $c.Text.Length
            Count       = 1
            IsBlock     = $c.Text.StartsWith('<#')
        }
    }
}
if ($current) { $runs += [pscustomobject]$current }

$runs | Where-Object { $_.Length -gt 250 } | Sort-Object StartLine | Format-Table StartLine, EndLine, Length, Count, IsBlock -AutoSize

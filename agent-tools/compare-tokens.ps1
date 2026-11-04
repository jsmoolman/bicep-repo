# Proves behavior preservation: compares the before/after PowerShell token
# streams, excluding Comment and NewLine kinds (and ignoring all position/
# Extent metadata), requiring Kind+Text to match exactly in sequence.

$before = 'C:\Source\bicep-repo\bicep-repo\agent-tools\Initialize-LimsGuestDataDisks.before.ps1'
$after = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'

function Get-SemanticTokens {
    param([string] $Path)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Parse errors in $Path`: $($errors.Count)"
    }
    return @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Kind -ne 'NewLine' -and $_.Kind -ne 'EndOfInput' } | ForEach-Object {
            [pscustomobject]@{ Kind = $_.Kind.ToString(); Text = $_.Text }
        })
}

function Get-DirectiveComments {
    param([string] $Path)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '^\s*#[Rr]equires' } | ForEach-Object { $_.Text })
}

Write-Output "Parsing BEFORE: $before"
$beforeTokens = Get-SemanticTokens -Path $before
Write-Output "Parsing AFTER:  $after"
$afterTokens = Get-SemanticTokens -Path $after

Write-Output ("BEFORE semantic token count: {0}" -f $beforeTokens.Count)
Write-Output ("AFTER  semantic token count: {0}" -f $afterTokens.Count)

if ($beforeTokens.Count -ne $afterTokens.Count) {
    Write-Output "MISMATCH: token counts differ."
}

$maxLen = [Math]::Max($beforeTokens.Count, $afterTokens.Count)
$mismatches = 0
for ($i = 0; $i -lt $maxLen; $i++) {
    $b = if ($i -lt $beforeTokens.Count) { $beforeTokens[$i] } else { $null }
    $a = if ($i -lt $afterTokens.Count) { $afterTokens[$i] } else { $null }
    if ($null -eq $b -or $null -eq $a -or $b.Kind -ne $a.Kind -or $b.Text -ne $a.Text) {
        $mismatches++
        if ($mismatches -le 10) {
            Write-Output ("DIFF at index {0}:" -f $i)
            Write-Output ("  BEFORE: {0}" -f ($(if ($b) { "$($b.Kind) => $($b.Text)" } else { '<none>' })))
            Write-Output ("  AFTER : {0}" -f ($(if ($a) { "$($a.Kind) => $($a.Text)" } else { '<none>' })))
        }
    }
}

if ($mismatches -eq 0) {
    Write-Output "RESULT: IDENTICAL semantic token stream (Kind+Text) excluding comments/newlines. $($beforeTokens.Count) tokens compared."
}
else {
    Write-Output ("RESULT: {0} mismatch(es) found out of {1} compared." -f $mismatches, $maxLen)
}

Write-Output "---- Comment-based directives (e.g. #Requires) ----"
$beforeDirectives = Get-DirectiveComments -Path $before
$afterDirectives = Get-DirectiveComments -Path $after
Write-Output ("BEFORE: {0} directive(s)" -f $beforeDirectives.Count)
Write-Output ("AFTER:  {0} directive(s)" -f $afterDirectives.Count)
if (($beforeDirectives -join "`n") -eq ($afterDirectives -join "`n")) {
    Write-Output "RESULT: Comment-based directives IDENTICAL (none present in either file)."
}
else {
    Write-Output "RESULT: Comment-based directives DIFFER."
    Write-Output "BEFORE:"; $beforeDirectives | ForEach-Object { Write-Output "  $_" }
    Write-Output "AFTER:"; $afterDirectives | ForEach-Object { Write-Output "  $_" }
}

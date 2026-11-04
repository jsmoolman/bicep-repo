param([string]$Path)
$tokens = $null
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Output $e.ToString() }
    exit 1
}
else {
    Write-Output "OK: $Path parses cleanly"
    exit 0
}

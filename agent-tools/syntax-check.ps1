param([string]$Path)
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -eq 0) {
    Write-Host "OK: no syntax errors in $Path"
} else {
    foreach ($e in $parseErrors) {
        Write-Host ("Line {0} Col {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
        Write-Host ("  >> {0}" -f $e.Extent.Text)
    }
    exit 1
}

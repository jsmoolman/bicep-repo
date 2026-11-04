param([Parameter(Mandatory = $true)][string]$Path)
$j = Get-Content $Path -Raw | ConvertFrom-Json
Write-Output ("Diagnostics count: " + $j.Diagnostics.Count)
$nonInfo = @($j.Diagnostics | Where-Object { $_.Severity -ne 'Info' })
Write-Output ("Non-info diagnostics: " + $nonInfo.Count)
$nonInfo | Format-List
Write-Output ("Template present: " + [bool]$j.Template)

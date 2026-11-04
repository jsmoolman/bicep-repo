$j = Get-Content -Raw 'C:\Source\bicep-repo\bicep-repo\agent-tools\main.compiled.json' | ConvertFrom-Json
Write-Output "Top-level keys: $($j.PSObject.Properties.Name -join ', ')"
Write-Output "Resource count: $($j.resources.Count)"
$j.resources | ForEach-Object { Write-Output ("Type: {0}; Name: {1}" -f $_.type, $_.name) }
Write-Output "---- variables ----"
Write-Output ($j.variables.PSObject.Properties.Name -join ', ')

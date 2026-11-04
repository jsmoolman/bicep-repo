$j1 = Get-Content 'C:\Users\moolman\.cursor\projects\c-Source-bicep-repo-bicep-repo\agent-tools\226c68c5-a796-4e87-9326-ccdf89a2fd02.txt' -Raw | ConvertFrom-Json
Write-Output "=== main.bicep diagnostics ==="
$j1.Diagnostics | ConvertTo-Json -Depth 5

$j2 = Get-Content 'C:\Users\moolman\.cursor\projects\c-Source-bicep-repo-bicep-repo\agent-tools\e5aedfc4-2ab9-4d76-8e62-988334bcbf82.txt' -Raw | ConvertFrom-Json
Write-Output "=== bicepparam diagnostics ==="
$j2.Diagnostics | ConvertTo-Json -Depth 5

$j1 = Get-Content 'C:\Users\moolman\.cursor\projects\c-Source-bicep-repo-bicep-repo\agent-tools\d39118dd-19f1-49e4-80d5-c59c048bfbef.txt' -Raw | ConvertFrom-Json
Write-Output "nfi bicepparam: has Parameters=$([bool]$j1.Parameters) Diagnostics.Count=$($j1.Diagnostics.Count)"
$j2 = Get-Content 'C:\Users\moolman\.cursor\projects\c-Source-bicep-repo-bicep-repo\agent-tools\80b04657-c492-4351-8805-128089a5cf7d.txt' -Raw | ConvertFrom-Json
Write-Output "module main.bicep: has Template=$([bool]$j2.Template) Diagnostics.Count=$($j2.Diagnostics.Count)"

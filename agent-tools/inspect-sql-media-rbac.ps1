$j = Get-Content -Raw 'C:\Source\bicep-repo\bicep-repo\agent-tools\sql-media-rbac.compiled.json' | ConvertFrom-Json
Write-Output "Top-level resources:"
foreach ($r in $j.resources) {
  Write-Output ("  type={0} name={1} subscriptionId={2} resourceGroup={3}" -f $r.type, $r.name, $r.subscriptionId, $r.resourceGroup)
}
Write-Output ""
Write-Output "Nested deployment #1 (resolve-sql-vm-identity) resources:"
$dev = $j.resources | Where-Object { $_.name -eq 'resolve-sql-vm-identity' }
foreach ($r in $dev.properties.template.resources) {
  Write-Output ("  type={0}" -f $r.type)
}
Write-Output ("  nested resource count: {0}" -f (@($dev.properties.template.resources).Count))
Write-Output ""
Write-Output "Nested deployment #2 (sql-media-container-rbac) resources:"
$mgmt = $j.resources | Where-Object { $_.name -eq 'sql-media-container-rbac' }
foreach ($r in $mgmt.properties.template.resources) {
  Write-Output ("  type={0} scope={1} name={2}" -f $r.type, $r.scope, $r.name)
}
Write-Output ("  nested resource count: {0}" -f (@($mgmt.properties.template.resources).Count))

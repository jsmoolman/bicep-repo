$DestinationPath = "C:\SQLMedia\SQL2022"
$SourceContainer = 'mssql-2022-source'
$ExpectedHostName = "vm-lims-dev-v2-westeu-002"

Write-Host "Staging to $DestinationPath from '$SourceContainer'..."

if ($env:COMPUTERNAME -ne $ExpectedHostName) {
    throw "Guest hostname mismatch: expected '$ExpectedHostName', got '$env:COMPUTERNAME'."
}

Write-Host "===== LIMS SQL v2 installation-media staging: SUCCESS ====="
Write-Host "Destination: $DestinationPath"

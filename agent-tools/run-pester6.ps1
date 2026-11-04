Import-Module Pester -RequiredVersion 5.9.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.Tests.ps1'
$config.Output.Verbosity = 'Normal'
$config.Run.PassThru = $true
$result = Invoke-Pester -Configuration $config
Write-Output "TOTAL=$($result.TotalCount) PASSED=$($result.PassedCount) FAILED=$($result.FailedCount) SKIPPED=$($result.SkippedCount)"
if ($result.FailedCount -gt 0) {
    $result.Failed | ForEach-Object {
        Write-Output "FAILED: $($_.ExpandedName)"
        Write-Output $_.ErrorRecord
    }
}

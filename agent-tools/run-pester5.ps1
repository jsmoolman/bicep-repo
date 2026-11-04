Import-Module Pester -RequiredVersion 5.9.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = 'modules/compute/lims-ws2025-dev-foundation/scripts/Initialize-LimsGuestDataDisks.Tests.ps1'
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true
Invoke-Pester -Configuration $config

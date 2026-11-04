$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.9.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = 'operations/compute/lims-ws2025-dev-sql-media-staging/Stage-LimsSqlInstallationMedia.Tests.ps1'
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true
Invoke-Pester -Configuration $config

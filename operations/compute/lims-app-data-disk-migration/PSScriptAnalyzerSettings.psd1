@{
    # Static-analysis settings for the LIMS APP data-disk migration scripts.
    # Copy-LimsAppDataDiskContents.ps1 runs under Windows PowerShell 5.1 via
    # Managed Run Command. Invoke-LimsAppDataDiskMigration.ps1 runs on the
    # Ubuntu pipeline agent under pwsh, but is kept 5.1-compatible so this
    # one colocated settings file covers the whole directory.
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules               = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}

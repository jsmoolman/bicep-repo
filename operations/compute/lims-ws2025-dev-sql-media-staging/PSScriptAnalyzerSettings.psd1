@{
    # Static-analysis settings for Stage-LimsSqlInstallationMedia.ps1, which
    # is delivered either via the Azure Portal "Run Command" blade or via
    # Managed Run Command (.azuredevops/pipelines/stage-lims-ws2025-dev-sql-media.yml),
    # both of which execute under Windows PowerShell 5.1 by default on
    # Windows (see that script's own header comment for the Microsoft
    # documentation this repository already relies on for the sibling
    # Initialize-LimsGuestDataDisks.ps1 script). PSUseCompatibleSyntax/
    # PSUseCompatibleCommands catch syntax or cmdlet usage that would not
    # run under that exact version -- this is the guest-runtime
    # compatibility check; it does not execute the script or require real
    # network/filesystem/IMDS access.
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # Style-only rules unrelated to guest-runtime compatibility --
        # excluded so CI failures stay focused on the intended
        # compatibility check this settings file exists for.
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
            # Windows Server PowerShell 5.1 profile -- the documented
            # default Managed Run Command / Portal Run Command runtime on
            # Windows. Covers the cmdlets this script calls from its
            # *Adapter functions (Invoke-WebRequest, Invoke-RestMethod,
            # Get-Item, New-Item, Move-Item, Remove-Item).
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}

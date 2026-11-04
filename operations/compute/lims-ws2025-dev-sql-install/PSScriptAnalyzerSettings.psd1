@{
    # Static-analysis settings for Install-LimsSqlServer.ps1, delivered via
    # Managed Run Command (.azuredevops/pipelines/provision-lims-ws2025-dev-sql.yml,
    # action 'install'), which executes under Windows PowerShell 5.1 by
    # default on Windows -- the same guest runtime already relied on by
    # the sibling Stage-LimsSqlInstallationMedia.ps1 and
    # Initialize-LimsGuestDataDisks.ps1 scripts. PSUseCompatibleSyntax/
    # PSUseCompatibleCommands catch syntax or cmdlet usage that would not
    # run under that exact version -- this is the guest-runtime
    # compatibility check; it does not execute the script or require real
    # network/filesystem/registry/SQL/service access.
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # Style-only rules unrelated to guest-runtime compatibility --
        # excluded so CI failures stay focused on the intended
        # compatibility check this settings file exists for.
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        # $SaPassword is deliberately a plain [string], not a
        # SecureString/PSCredential. Managed Run Command's own
        # --protected-parameters mechanism (the only way this value ever
        # reaches this script -- see provision-lims-ws2025-dev-sql.yml)
        # delivers every parameter, protected or not, to a PowerShell
        # script's param() block as a plain string process argument; a
        # SecureString parameter here could not change how Run Command
        # itself delivers the value, so it would add complexity (an extra
        # conversion step) without closing any real exposure this specific
        # delivery mechanism doesn't already have. The value is never
        # written to any file, pipeline log, or output/verbose/error
        # stream by this script -- see Invoke-LimsSqlServerSetup's own
        # comment for where the one necessary use of it (the /SAPWD
        # command-line argument to Setup.exe) is handled.
        'PSAvoidUsingPlainTextForPassword'
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
            # *Adapter functions (Invoke-RestMethod, Test-Path,
            # Get-AuthenticodeSignature, Get-Volume, Get-Service,
            # Set-Service, Stop-Service, Start-Service, Restart-Service,
            # New-Item, Remove-Item, Set-Content, Get-ItemProperty,
            # Set-ItemProperty, New-ScheduledTask*, Register-ScheduledTask,
            # Start-Process).
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}

@{
    # Static-analysis settings for Initialize-LimsGuestDataDisks.ps1, which
    # executes inside the guest under Windows PowerShell 5.1 by default (see
    # that script's own header comment for the Microsoft documentation
    # confirming this runtime). PSUseCompatibleSyntax/PSUseCompatibleCmdlets
    # catch syntax or cmdlet usage that would not run under that exact
    # version -- this is the guest-runtime compatibility check; it does not
    # execute the script or require Windows Storage cmdlets to exist.
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # Style-only rules unrelated to guest-runtime compatibility --
        # excluded so CI failures stay focused on the intended compatibility
        # check this settings file exists for.
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
            # default Managed Run Command runtime on Windows (see this
            # script's own header comment). Covers the cmdlets this script
            # calls from its guest-only Adapter functions (Get-Disk,
            # Initialize-Disk, New-Partition, Format-Volume, Get-Partition,
            # Get-Volume, Get-CimInstance, Set-CimInstance,
            # Invoke-RestMethod).
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}

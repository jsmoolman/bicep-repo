@{
    # Static-analysis settings for retained LIMS APP release scripts.
    # Configure-LimsAppV2.ps1 is written for Windows PowerShell 5.1 guest
    # execution. The release entry point runs on the pipeline agent and is
    # kept 5.1-compatible so this one settings file covers the directory.
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        # Write-Host is the operator log: the script entry point Out-Nulls
        # structured returns, so success-stream Write-Output never reaches
        # the Azure DevOps log.
        'PSAvoidUsingWriteHost'
        # Protected Run Command parameters arrive as plain strings and
        # are passed to New-LocalUser / Register-ScheduledTask / sc.exe
        # without writing them to stdout.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingUsernameAndPasswordParams'
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

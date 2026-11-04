Describe 'Install-LimsSqlTempDbStartupSequence (orchestration, mocked adapters)' {
    It 'writes the preparation script, registers the AtStartup task, disables Windows auto-start, and smoke-tests the script without deleting TempDB' {
        $script:writtenContent = $null
        Mock Write-TextFileAdapter { param($Path, $Content) $script:writtenContent = $Content }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter { }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Disabled' } }

        $result = Install-LimsSqlTempDbStartupSequence -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB'
        $result | Should -Be $true
        Should -Invoke Register-TempDbPreparationScheduledTaskAdapter -Times 1 -ParameterFilter { $TaskName -eq 'LIMS-SQL-TempDb-PrepareAndStart' }
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 1 -ParameterFilter { $Name -eq 'MSSQLSERVER' -and $StartupType -eq 'Disabled' }
        Should -Invoke Invoke-TempDbPreparationScriptAdapter -Times 1
        $script:writtenContent | Should -Not -Match 'Remove-Item'
        $script:writtenContent | Should -Match 'icacls\.exe'
        $script:writtenContent | Should -Match 'Start-Service'
    }

    It 'fails closed (and never claims SQL started) when the preparation script reports a directory or ACL failure' {
        Mock Write-TextFileAdapter { }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter {
            Assert-LimsSqlInstallFailure "TempDB preparation script 'C:\SQLMedia\SQL2022\Start-LimsSqlServerAfterTempDbPreparation.ps1' exited with code 1."
        }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Disabled' } }

        { Install-LimsSqlTempDbStartupSequence -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB' } | Should -Throw -ExpectedMessage '*exited with code 1*'
        Should -Invoke Get-ServiceStateAdapter -Times 0
    }

    It 'throws if the service is not Running after a successful preparation-script smoke test' {
        Mock Write-TextFileAdapter { }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter { }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }

        { Install-LimsSqlTempDbStartupSequence -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB' } | Should -Throw -ExpectedMessage '*is not in the Running state*'
    }
}

Describe 'Test-LimsSqlPostInstallState (orchestration, mocked adapters)' {
    BeforeEach {
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }
    }

    It 'throws when the edition does not contain Enterprise' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Standard Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            return '16.0.1000.6'
        }
        { Test-LimsSqlPostInstallState -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*edition*'
    }

    It 'throws when the collation does not match' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'Latin1_General_CI_AS' }
            return '16.0.1000.6'
        }
        { Test-LimsSqlPostInstallState -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*collation*'
    }

    It 'throws when SQLSERVERAGENT is running' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            return '16.0.1000.6'
        }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Disabled' } }
        { Test-LimsSqlPostInstallState -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*is running*'
    }

    It 'returns a clean result when edition, collation, and agent state all match expectations' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            return '16.0.1000.6'
        }
        $result = Test-LimsSqlPostInstallState -Config $script:TestConfig
        $result.Edition | Should -Be 'Enterprise Edition (64-bit)'
        $result.AgentStatus | Should -Be 'Stopped'
    }
}

Describe 'Invoke-LimsSqlAdminVerificationAndSaDisableAttempt (orchestration, mocked adapters)' {
    It 'does NOT disable sa when the connected identity is SYSTEM even if it has sysadmin -- reports PendingManualOperatorVerification' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*SYSTEM_USER*') { return 'NT AUTHORITY\SYSTEM' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 1 }
            return 0
        }
        Mock Invoke-SqlWindowsAuthNonQueryAdapter { }

        $result = Invoke-LimsSqlAdminVerificationAndSaDisableAttempt -ApprovedPrincipals @('BUILTIN\Administrators', 'CONTOSO\jsmith')
        $result | Should -Be 'PendingManualOperatorVerification'
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 0
    }

    It 'does NOT disable sa when an approved identity is connected but does not have sysadmin' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*SYSTEM_USER*') { return 'CONTOSO\jsmith' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 0 }
            return 0
        }
        Mock Invoke-SqlWindowsAuthNonQueryAdapter { }

        $result = Invoke-LimsSqlAdminVerificationAndSaDisableAttempt -ApprovedPrincipals @('CONTOSO\jsmith')
        $result | Should -Be 'PendingManualOperatorVerification'
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 0
    }

    It 'disables sa from a verified session whose own identity matches an approved administrator and has sysadmin' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*SYSTEM_USER*') { return 'CONTOSO\jsmith' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 1 }
            if ($Query -like '*is_disabled*') { return 1 }
            return 0
        }
        Mock Invoke-SqlWindowsAuthNonQueryAdapter { }

        $result = Invoke-LimsSqlAdminVerificationAndSaDisableAttempt -ApprovedPrincipals @('BUILTIN\Administrators', 'CONTOSO\jsmith')
        $result | Should -Be 'Completed'
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 1 -ParameterFilter { $Query -like '*ALTER LOGIN*DISABLE*' }
    }

    It 'throws if sa does not report as disabled after a verified administrator session issued ALTER LOGIN' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*SYSTEM_USER*') { return 'CONTOSO\jsmith' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 1 }
            if ($Query -like '*is_disabled*') { return 0 }
            return 0
        }
        Mock Invoke-SqlWindowsAuthNonQueryAdapter { }

        { Invoke-LimsSqlAdminVerificationAndSaDisableAttempt -ApprovedPrincipals @('CONTOSO\jsmith') } | Should -Throw -ExpectedMessage '*does not report as disabled*'
    }
}

Describe 'Invoke-LimsSqlServerInstall (end-to-end orchestration, mocked adapters) -- fail before any mutation' {
    BeforeEach {
        $script:sqlAssessed = $false
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { return $true }
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        Mock Test-PathExistsAdapter { return $true }
        Mock Get-AuthenticodeSignatureAdapter { return New-ValidSignatureResult }
        Mock Get-VolumeLabelAdapter { param($DriveLetter) if ($DriveLetter -eq 'E') { return 'SQL-Data' }; return 'SQL-Logs' }
        Mock New-DirectoryAdapter { }
        Mock Write-TextFileAdapter { }
        Mock Invoke-SqlSetupProcessAdapter { return 0 }
        Mock Get-TcpIPAllRegistryValuesAdapter { return [pscustomobject]@{ TcpPort = '1433'; TcpDynamicPorts = '' } }
        Mock Set-TcpIPAllRegistryValuesAdapter { }
        Mock Restart-ServiceAndWaitRunningAdapter { return $true }
        Mock Test-TcpPortOpenAdapter { return $true }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter { }
        Mock Invoke-SqlWindowsAuthNonQueryAdapter { }
        Mock Get-ServiceStateAdapter {
            param($Name)
            if ($Name -eq $script:TestConfig.AgentServiceName) { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }
            if ($script:sqlAssessed) { return [pscustomobject]@{ Status = 'Running'; StartType = 'Disabled' } }
            $script:sqlAssessed = $true
            return $null
        }
        # Default: Managed Run Command identity (SYSTEM) with sysadmin --
        # insufficient to authorize disabling sa.
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            if ($Query -like '*SYSTEM_USER*') { return 'NT AUTHORITY\SYSTEM' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 1 }
            if ($Query -like '*is_disabled*') { return 0 }
            return '16.0.1000.6'
        }
    }

    It 'fails before any mutation when not running as SYSTEM/Administrator' {
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { return $false }

        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*SYSTEM or an Administrator*'

        Should -Invoke Get-ActualComputerNameAdapter -Times 0
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'fails before any mutation when SaPassword is empty' {
        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword '' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*SaPassword*'
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'fails before any mutation when the Windows SQL admin principals are empty, never guessing a default' {
        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv '' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*administrator principals*'
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'fails before any mutation on a hostname mismatch, never reaching the volume/instance checks' {
        Mock Get-ActualComputerNameAdapter { return 'wrong-hostname' }
        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*hostname*'
        Should -Invoke Get-VolumeLabelAdapter -Times 0
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'runs Setup end-to-end on a fresh VM (NotInstalled), reports SETUP COMPLETED, and leaves sa disable pending because the session is SYSTEM' {
        $result = Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'Sup3r$ecret!' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512

        $result.Status | Should -Be 'Succeeded'
        $result.Edition | Should -Be 'Enterprise Edition (64-bit)'
        $result.TempDbStartupSequenceConfirmed | Should -Be $true
        $result.SaDisableStatus | Should -Be 'PendingManualOperatorVerification'
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 1
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 0
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 1 -ParameterFilter { $StartupType -eq 'Disabled' }
        Should -Invoke Register-TempDbPreparationScheduledTaskAdapter -Times 1
    }

    It 'disables sa end-to-end only when the connected identity is an approved administrator with sysadmin' {
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            if ($Query -like '*SYSTEM_USER*') { return 'CONTOSO\jsmith' }
            if ($Query -like '*IS_SRVROLEMEMBER*') { return 1 }
            if ($Query -like '*is_disabled*') { return 1 }
            return '16.0.1000.6'
        }

        $result = Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'CONTOSO\jsmith' -SaPassword 'x' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512

        $result.Status | Should -Be 'Succeeded'
        $result.SaDisableStatus | Should -Be 'Completed'
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 1 -ParameterFilter { $Query -like '*ALTER LOGIN*DISABLE*' }
    }

    It 'fails the whole install (never reaching sa handling) when TempDB directory/ACL preparation fails' {
        Mock Invoke-TempDbPreparationScriptAdapter {
            Assert-LimsSqlInstallFailure "TempDB preparation script 'C:\SQLMedia\SQL2022\Start-LimsSqlServerAfterTempDbPreparation.ps1' exited with code 1."
        }

        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*exited with code 1*'

        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 0
    }

    It 'reports an already-healthy matching instance as success WITHOUT re-running Setup (idempotent rerun)' {
        Mock Get-ServiceStateAdapter {
            param($Name)
            if ($Name -eq $script:TestConfig.AgentServiceName) { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }
            return [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
        }

        $result = Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512

        $result.Status | Should -Be 'Succeeded'
        $result.SaDisableStatus | Should -Be 'PendingManualOperatorVerification'
        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'fails closed on a partial/unexpected existing instance, never attempting an automatic repair/reinstall' {
        Mock Get-ServiceStateAdapter {
            param($Name)
            if ($Name -eq $script:TestConfig.AgentServiceName) { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }
            return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
        }

        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*partial or unexpected state*'

        Should -Invoke Invoke-SqlSetupProcessAdapter -Times 0
    }

    It 'stops cleanly (not as a hard failure) when Setup reports exit code 3010 (reboot required), never proceeding to post-install verification' {
        Mock Invoke-SqlSetupProcessAdapter { return 3010 }

        $result = Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512

        $result.Status | Should -Be 'RebootRequired'
        $result.SetupExitCode | Should -Be 3010
        Should -Invoke Restart-ServiceAndWaitRunningAdapter -Times 0
        Should -Invoke Register-TempDbPreparationScheduledTaskAdapter -Times 0
        Should -Invoke Invoke-SqlWindowsAuthNonQueryAdapter -Times 0
    }

    It 'fails the whole run on a genuine Setup failure exit code' {
        Mock Invoke-SqlSetupProcessAdapter { return 1603 }

        { Invoke-LimsSqlServerInstall -WindowsSqlAdminPrincipalsCsv 'BUILTIN\Administrators' -SaPassword 'x' `
                -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
                -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        } | Should -Throw -ExpectedMessage '*exit code 1603*'

        Should -Invoke Restart-ServiceAndWaitRunningAdapter -Times 0
    }
}

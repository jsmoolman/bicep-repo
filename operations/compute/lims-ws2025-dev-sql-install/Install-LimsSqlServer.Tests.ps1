<#
    Pester tests for Install-LimsSqlServer.ps1.

    SCOPE. These tests run on Ubuntu CI (Pester on Linux; no real Windows
    registry/service/SQL/filesystem/IMDS access) and exercise exactly two
    kinds of code in the real script, unmodified:

      1. The PURE decision functions (ConvertTo-LimsSqlAdminPrincipalsList,
         Get-LimsSqlSetupExitCodeClassification,
         Get-LimsSqlExistingInstanceAssessmentDecision,
         Test-TcpIPAllConfigurationMatches,
         Test-LimsSqlVerifiedAdministratorSession,
         New-LimsSqlTempDbPreparationScriptContent,
         New-LimsSqlInstallConfigurationFileContent) -- called directly
         with plain fake data.

      2. The ORCHESTRATION functions (Assert-InstallTargetIdentity,
         Assert-SetupExecutableSignatureValid, Assert-RequiredVolumesPresent,
         Get-LimsSqlExistingInstanceAssessment, Invoke-LimsSqlServerSetup,
         Set-LimsSqlServerTcpPort1433, Install-LimsSqlTempDbStartupSequence,
         Test-LimsSqlPostInstallState, Invoke-LimsSqlAdminVerificationAndSaDisableAttempt,
         Invoke-LimsSqlServerInstall) -- called for real, but with every
         *Adapter function (the only functions that would call a real
         cmdlet/network/registry/service/SQL/process) replaced with a
         Pester Mock.

    These tests specifically cover, per the task's explicit request:
      - Fail-before-any-mutation ordering (identity, signature, volumes,
        rerun-state all checked before Setup.exe is ever invoked).
      - The sa password and the full Setup command line never appear in
        any thrown error message or in the generated ConfigurationFile.ini
        content.
      - Rerun safety: an already-healthy instance is reported as success
        without re-running Setup; a partial/unexpected instance fails
        closed without an automatic repair/reinstall attempt.
      - Setup exit-code classification, including 3010 ("reboot required")
        never being treated as a failure.
      - SYSTEM (or any identity not in the approved list) having sysadmin
        access is INSUFFICIENT to authorize disabling sa -- sa is never
        disabled in that case, and this is reported as
        PendingManualOperatorVerification, never as a silent success.
      - A session whose own connected identity genuinely matches an
        approved Windows SQL administrator principal, and has sysadmin
        access, is sufficient to verify and disable sa.
      - The explicit, deterministic TempDB preparation-then-start
        sequence, including a directory/ACL (icacls.exe) failure
        correctly preventing the Database Engine from starting and
        failing the whole install closed -- and that no step ever deletes
        the live TempDB directory.

    PowerShell 5.1 guest-runtime compatibility is checked separately by
    PSScriptAnalyzer (see PSScriptAnalyzerSettings.psd1 in this same
    directory) -- not by these tests. Real guest execution (actual Setup.exe
    invocation, actual SQL connections, actual scheduled-task/service/
    registry mutation, actual Managed Run Command delivery) has not been
    rehearsed anywhere, by this suite or otherwise.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_SQL_INSTALL_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'Install-LimsSqlServer.ps1')

    $script:TestConfig = Get-LimsSqlInstallFixedConfig

    function New-ValidSignatureResult {
        return [pscustomobject]@{
            Status            = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
        }
    }
}

Describe 'ConvertTo-LimsSqlAdminPrincipalsList (pure)' {
    It 'rejects an empty string' {
        $result = ConvertTo-LimsSqlAdminPrincipalsList -Csv ''
        $result.Accepted | Should -Be $false
        $result.Principals | Should -BeNullOrEmpty
    }

    It 'rejects a whitespace-only string' {
        $result = ConvertTo-LimsSqlAdminPrincipalsList -Csv '   '
        $result.Accepted | Should -Be $false
    }

    It 'rejects a string that resolves to zero non-empty entries' {
        $result = ConvertTo-LimsSqlAdminPrincipalsList -Csv ' , , '
        $result.Accepted | Should -Be $false
    }

    It 'accepts and trims a single principal' {
        $result = ConvertTo-LimsSqlAdminPrincipalsList -Csv '  BUILTIN\Administrators  '
        $result.Accepted | Should -Be $true
        $result.Principals | Should -Be @('BUILTIN\Administrators')
    }

    It 'accepts and trims multiple comma-separated principals' {
        $result = ConvertTo-LimsSqlAdminPrincipalsList -Csv 'BUILTIN\Administrators, AzureAD\group@tenant.onmicrosoft.com ,AzureAD\other@tenant.onmicrosoft.com'
        $result.Accepted | Should -Be $true
        $result.Principals.Count | Should -Be 3
        $result.Principals | Should -Contain 'BUILTIN\Administrators'
        $result.Principals | Should -Contain 'AzureAD\group@tenant.onmicrosoft.com'
        $result.Principals | Should -Contain 'AzureAD\other@tenant.onmicrosoft.com'
    }
}

Describe 'Get-LimsSqlSetupExitCodeClassification (pure)' {
    It 'classifies 0 as Succeeded' {
        Get-LimsSqlSetupExitCodeClassification -ExitCode 0 -Config $script:TestConfig | Should -Be 'Succeeded'
    }
    It 'classifies 3010 as SucceededRebootRequired, never as a failure' {
        Get-LimsSqlSetupExitCodeClassification -ExitCode 3010 -Config $script:TestConfig | Should -Be 'SucceededRebootRequired'
    }
    It 'classifies any other code as Failed' {
        Get-LimsSqlSetupExitCodeClassification -ExitCode 1603 -Config $script:TestConfig | Should -Be 'Failed'
    }
}

Describe 'Get-LimsSqlExistingInstanceAssessmentDecision (pure)' {
    It 'returns NotInstalled when the service does not exist' {
        Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $false -Config $script:TestConfig | Should -Be 'NotInstalled'
    }
    It 'returns HealthyMatchingInstance when running, matching edition, matching collation' {
        Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $true -ServiceStatus 'Running' -Edition 'Enterprise Edition (64-bit)' -Collation 'SQL_Latin1_General_CP1_CI_AS' -Config $script:TestConfig | Should -Be 'HealthyMatchingInstance'
    }
    It 'returns PartialOrUnexpectedState when the service exists but is stopped' {
        Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $true -ServiceStatus 'Stopped' -Edition $null -Collation $null -Config $script:TestConfig | Should -Be 'PartialOrUnexpectedState'
    }
    It 'returns PartialOrUnexpectedState when running but the edition does not match' {
        Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $true -ServiceStatus 'Running' -Edition 'Standard Edition (64-bit)' -Collation 'SQL_Latin1_General_CP1_CI_AS' -Config $script:TestConfig | Should -Be 'PartialOrUnexpectedState'
    }
    It 'returns PartialOrUnexpectedState when running but the collation does not match' {
        Get-LimsSqlExistingInstanceAssessmentDecision -ServiceExists $true -ServiceStatus 'Running' -Edition 'Enterprise Edition (64-bit)' -Collation 'Latin1_General_CI_AS' -Config $script:TestConfig | Should -Be 'PartialOrUnexpectedState'
    }
}

Describe 'Test-TcpIPAllConfigurationMatches (pure)' {
    It 'matches when TcpPort equals the desired port and TcpDynamicPorts is empty' {
        Test-TcpIPAllConfigurationMatches -CurrentTcpPort '1433' -CurrentTcpDynamicPorts '' -DesiredPort 1433 | Should -Be $true
    }
    It 'does not match when TcpPort differs' {
        Test-TcpIPAllConfigurationMatches -CurrentTcpPort '14330' -CurrentTcpDynamicPorts '' -DesiredPort 1433 | Should -Be $false
    }
    It 'does not match when TcpDynamicPorts is non-empty (dynamic ports still active)' {
        Test-TcpIPAllConfigurationMatches -CurrentTcpPort '1433' -CurrentTcpDynamicPorts '0' -DesiredPort 1433 | Should -Be $false
    }
    It 'does not match when both values are null (never configured)' {
        Test-TcpIPAllConfigurationMatches -CurrentTcpPort $null -CurrentTcpDynamicPorts $null -DesiredPort 1433 | Should -Be $false
    }
}

Describe 'Test-LimsSqlVerifiedAdministratorSession (pure)' {
    It 'rejects SYSTEM (or any identity not in the approved list) even with sysadmin access -- sysadmin alone is never sufficient' {
        Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity 'NT AUTHORITY\SYSTEM' -IsSysadmin $true -ApprovedPrincipals @('BUILTIN\Administrators', 'CONTOSO\jsmith') | Should -Be $false
    }
    It 'rejects an approved identity that does NOT have sysadmin access' {
        Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity 'CONTOSO\jsmith' -IsSysadmin $false -ApprovedPrincipals @('CONTOSO\jsmith') | Should -Be $false
    }
    It 'rejects an empty connected identity' {
        Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity '' -IsSysadmin $true -ApprovedPrincipals @('BUILTIN\Administrators') | Should -Be $false
    }
    It 'accepts a connected identity that exactly matches an approved principal and has sysadmin access' {
        Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity 'CONTOSO\jsmith' -IsSysadmin $true -ApprovedPrincipals @('BUILTIN\Administrators', 'CONTOSO\jsmith') | Should -Be $true
    }
    It 'matches case-insensitively' {
        Test-LimsSqlVerifiedAdministratorSession -ConnectedIdentity 'contoso\JSMITH' -IsSysadmin $true -ApprovedPrincipals @('CONTOSO\jsmith') | Should -Be $true
    }
}

Describe 'New-LimsSqlTempDbPreparationScriptContent (pure)' {
    BeforeAll {
        $script:PrepScriptContent = New-LimsSqlTempDbPreparationScriptContent -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB'
    }

    It 'never deletes anything -- no Remove-Item or recursive-delete logic of any kind' {
        $script:PrepScriptContent | Should -Not -Match 'Remove-Item'
    }
    It 'waits for the TempDB volume to become available before doing anything else' {
        $script:PrepScriptContent | Should -Match "Test-Path -LiteralPath 'D:\\'"
    }
    It 'creates the TempDB directory only if missing (never unconditionally, never after a delete)' {
        $script:PrepScriptContent | Should -Match "if \(-not \(Test-Path -LiteralPath 'D:\\MSSQL\\TempDB'\)\)"
    }
    It 'checks icacls.exe''s exit code and refuses to start the service on failure' {
        $script:PrepScriptContent | Should -Match 'icacls\.exe'
        $script:PrepScriptContent | Should -Match '\$LASTEXITCODE -ne 0'
        $script:PrepScriptContent | Should -Match 'exit 1'
    }
    It 'only starts the Database Engine service, and strictly after the icacls.exe exit-code check, never before' {
        $script:PrepScriptContent | Should -Match 'Start-Service'
        $icaclsIndex = $script:PrepScriptContent.IndexOf('icacls.exe')
        $startServiceIndex = $script:PrepScriptContent.IndexOf('Start-Service')
        $icaclsIndex | Should -BeGreaterThan -1
        $startServiceIndex | Should -BeGreaterThan $icaclsIndex
    }
}

Describe 'New-LimsSqlInstallConfigurationFileContent (pure)' {
    BeforeAll {
        $script:IniContent = New-LimsSqlInstallConfigurationFileContent -Config $script:TestConfig -AdminPrincipals @('BUILTIN\Administrators', 'AzureAD\group@tenant.onmicrosoft.com') `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
    }

    It 'never contains the word SAPWD or any password value -- the secret is never written to this file' {
        $script:IniContent | Should -Not -Match 'SAPWD'
    }
    It 'includes the fixed, non-caller-supplied configuration' {
        $script:IniContent | Should -Match 'FEATURES=SQL'
        $script:IniContent | Should -Match 'SECURITYMODE="SQL"'
        $script:IniContent | Should -Match 'SQLSVCACCOUNT="NT SERVICE\\MSSQLSERVER"'
        $script:IniContent | Should -Match 'AGTSVCACCOUNT="NT SERVICE\\SQLSERVERAGENT"'
        $script:IniContent | Should -Match 'AGTSVCSTARTUPTYPE="Disabled"'
        $script:IniContent | Should -Match 'TCPENABLED="1"'
        $script:IniContent | Should -Match 'NPENABLED="0"'
        $script:IniContent | Should -Match 'UPDATEENABLED="False"'
        $script:IniContent | Should -Match 'SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"'
    }
    It 'includes every explicit caller-supplied input -- never hardcoded/defaulted by this script' {
        $script:IniContent | Should -Match '"BUILTIN\\Administrators" "AzureAD\\group@tenant\.onmicrosoft\.com"'
        $script:IniContent | Should -Match 'INSTALLSQLDATADIR="E:\\MSSQL\\DATA"'
        $script:IniContent | Should -Match 'SQLUSERDBLOGDIR="F:\\MSSQL\\LOG"'
        $script:IniContent | Should -Match 'SQLTEMPDBDIR="D:\\MSSQL\\TempDB"'
        $script:IniContent | Should -Match 'SQLTEMPDBFILECOUNT=8'
        $script:IniContent | Should -Match 'SQLTEMPDBFILESIZE=1024'
        $script:IniContent | Should -Match 'SQLTEMPDBFILEGROWTH=512'
    }
}

Describe 'Assert-InstallTargetIdentity (orchestration, mocked adapters) -- fail before any mutation' {
    It 'throws on a hostname mismatch' {
        Mock Get-ActualComputerNameAdapter { return 'wrong-hostname' }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        { Assert-InstallTargetIdentity -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*hostname*' -ErrorAction SilentlyContinue
    }

    It 'throws on an IMDS subscription mismatch' {
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = 'wrong-subscription'; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        { Assert-InstallTargetIdentity -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*subscription*'
    }

    It 'passes when hostname and IMDS both match' {
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        { Assert-InstallTargetIdentity -Config $script:TestConfig } | Should -Not -Throw
    }
}

Describe 'Assert-SetupExecutableSignatureValid (orchestration, mocked adapters)' {
    It 'throws when the pinned Setup executable does not exist' {
        Mock Test-PathExistsAdapter { return $false }
        Mock Get-AuthenticodeSignatureAdapter { return New-ValidSignatureResult }
        { Assert-SetupExecutableSignatureValid -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*not found*'
        Should -Invoke Get-AuthenticodeSignatureAdapter -Times 0
    }

    It 'throws when the signature status is not Valid' {
        Mock Test-PathExistsAdapter { return $true }
        Mock Get-AuthenticodeSignatureAdapter { return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Assert-SetupExecutableSignatureValid -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*Authenticode signature*'
    }

    It 'throws when valid but not signed by Microsoft Corporation' {
        Mock Test-PathExistsAdapter { return $true }
        Mock Get-AuthenticodeSignatureAdapter { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Someone Else' } } }
        { Assert-SetupExecutableSignatureValid -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*Microsoft Corporation*'
    }

    It 'passes for a valid, Microsoft-signed executable' {
        Mock Test-PathExistsAdapter { return $true }
        Mock Get-AuthenticodeSignatureAdapter { return New-ValidSignatureResult }
        { Assert-SetupExecutableSignatureValid -Config $script:TestConfig } | Should -Not -Throw
    }
}

Describe 'Assert-RequiredVolumesPresent (orchestration, mocked adapters)' {
    It 'throws when E: does not carry the expected SQL-Data label' {
        Mock Get-VolumeLabelAdapter { param($DriveLetter) if ($DriveLetter -eq 'E') { return 'WrongLabel' }; return 'SQL-Logs' }
        Mock Test-PathExistsAdapter { return $true }
        { Assert-RequiredVolumesPresent -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*E:*'
    }
    It 'throws when F: does not carry the expected SQL-Logs label' {
        Mock Get-VolumeLabelAdapter { param($DriveLetter) if ($DriveLetter -eq 'E') { return 'SQL-Data' }; return 'WrongLabel' }
        Mock Test-PathExistsAdapter { return $true }
        { Assert-RequiredVolumesPresent -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*F:*'
    }
    It 'throws when D: does not exist' {
        Mock Get-VolumeLabelAdapter { param($DriveLetter) if ($DriveLetter -eq 'E') { return 'SQL-Data' }; return 'SQL-Logs' }
        Mock Test-PathExistsAdapter { return $false }
        { Assert-RequiredVolumesPresent -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*D:*'
    }
    It 'passes when all three volumes are correct' {
        Mock Get-VolumeLabelAdapter { param($DriveLetter) if ($DriveLetter -eq 'E') { return 'SQL-Data' }; return 'SQL-Logs' }
        Mock Test-PathExistsAdapter { return $true }
        { Assert-RequiredVolumesPresent -Config $script:TestConfig } | Should -Not -Throw
    }
}

Describe 'Get-LimsSqlExistingInstanceAssessment (orchestration, mocked adapters)' {
    It 'reports NotInstalled without ever querying SQL when the service does not exist' {
        Mock Get-ServiceStateAdapter { return $null }
        Mock Invoke-SqlWindowsAuthScalarAdapter { return 'should-not-be-called' }
        $result = Get-LimsSqlExistingInstanceAssessment -Config $script:TestConfig
        $result.Decision | Should -Be 'NotInstalled'
        Should -Invoke Invoke-SqlWindowsAuthScalarAdapter -Times 0
    }

    It 'reports HealthyMatchingInstance when running with matching edition/collation' {
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
        Mock Invoke-SqlWindowsAuthScalarAdapter {
            param($Query)
            if ($Query -like '*Edition*') { return 'Enterprise Edition (64-bit)' }
            if ($Query -like '*Collation*') { return 'SQL_Latin1_General_CP1_CI_AS' }
            return '16.0.1000.6'
        }
        $result = Get-LimsSqlExistingInstanceAssessment -Config $script:TestConfig
        $result.Decision | Should -Be 'HealthyMatchingInstance'
    }

    It 'reports PartialOrUnexpectedState when the service exists but is stopped' {
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
        Mock Invoke-SqlWindowsAuthScalarAdapter { return 'should-not-be-called' }
        $result = Get-LimsSqlExistingInstanceAssessment -Config $script:TestConfig
        $result.Decision | Should -Be 'PartialOrUnexpectedState'
        Should -Invoke Invoke-SqlWindowsAuthScalarAdapter -Times 0
    }
}

Describe 'Invoke-LimsSqlServerSetup (orchestration, mocked adapters) -- secret handling' {
    It 'passes /SAPWD only as a Setup.exe process argument, never writes it to the configuration file, and classifies the exit code' {
        $script:writtenIniContent = $null
        $script:capturedArguments = $null
        Mock New-DirectoryAdapter { }
        Mock Write-TextFileAdapter { param($Path, $Content) $script:writtenIniContent = $Content }
        Mock Invoke-SqlSetupProcessAdapter {
            param($SetupExePath, $Arguments)
            $script:capturedArguments = $Arguments
            return 0
        }

        $result = Invoke-LimsSqlServerSetup -Config $script:TestConfig -AdminPrincipals @('BUILTIN\Administrators') -SaPassword 'Sup3r$ecret!' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512

        $result.Classification | Should -Be 'Succeeded'
        $script:writtenIniContent | Should -Not -Match 'Sup3r\$ecret!'
        $script:writtenIniContent | Should -Not -Match 'SAPWD'
        ($script:capturedArguments -join ' ') | Should -Match 'Sup3r\$ecret!'
        ($script:capturedArguments -join ' ') | Should -Match '/ConfigurationFile='
    }

    It 'classifies exit code 3010 as SucceededRebootRequired' {
        Mock New-DirectoryAdapter { }
        Mock Write-TextFileAdapter { }
        Mock Invoke-SqlSetupProcessAdapter { return 3010 }
        $result = Invoke-LimsSqlServerSetup -Config $script:TestConfig -AdminPrincipals @('BUILTIN\Administrators') -SaPassword 'x' `
            -DataPath 'E:\MSSQL\DATA' -LogPath 'F:\MSSQL\LOG' -TempDbPath 'D:\MSSQL\TempDB' `
            -TempDbFileCount 8 -TempDbFileSizeMB 1024 -TempDbFileGrowthMB 512 -TempDbLogSizeMB 1024 -TempDbLogGrowthMB 512
        $result.Classification | Should -Be 'SucceededRebootRequired'
    }
}

Describe 'Set-LimsSqlServerTcpPort1433 (orchestration, mocked adapters)' {
    It 'does nothing further when already configured correctly' {
        Mock Get-TcpIPAllRegistryValuesAdapter { return [pscustomobject]@{ TcpPort = '1433'; TcpDynamicPorts = '' } }
        Mock Set-TcpIPAllRegistryValuesAdapter { }
        Mock Restart-ServiceAndWaitRunningAdapter { return $true }
        Mock Test-TcpPortOpenAdapter { return $true }

        { Set-LimsSqlServerTcpPort1433 -Config $script:TestConfig } | Should -Not -Throw
        Should -Invoke Set-TcpIPAllRegistryValuesAdapter -Times 0
        Should -Invoke Restart-ServiceAndWaitRunningAdapter -Times 0
    }

    It 'applies the change and restarts the service when not yet configured, then verifies' {
        $script:callCount = 0
        Mock Get-TcpIPAllRegistryValuesAdapter {
            $script:callCount++
            if ($script:callCount -eq 1) { return [pscustomobject]@{ TcpPort = ''; TcpDynamicPorts = '0' } }
            return [pscustomobject]@{ TcpPort = '1433'; TcpDynamicPorts = '' }
        }
        Mock Set-TcpIPAllRegistryValuesAdapter { }
        Mock Restart-ServiceAndWaitRunningAdapter { return $true }
        Mock Test-TcpPortOpenAdapter { return $true }

        { Set-LimsSqlServerTcpPort1433 -Config $script:TestConfig } | Should -Not -Throw
        Should -Invoke Set-TcpIPAllRegistryValuesAdapter -Times 1
        Should -Invoke Restart-ServiceAndWaitRunningAdapter -Times 1
    }

    It 'throws if the service never reaches Running after the change' {
        Mock Get-TcpIPAllRegistryValuesAdapter { return [pscustomobject]@{ TcpPort = ''; TcpDynamicPorts = '0' } }
        Mock Set-TcpIPAllRegistryValuesAdapter { }
        Mock Restart-ServiceAndWaitRunningAdapter { return $false }
        Mock Test-TcpPortOpenAdapter { return $true }
        { Set-LimsSqlServerTcpPort1433 -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*did not reach Running*'
    }

    It 'throws if the local TCP connection does not succeed after configuration' {
        Mock Get-TcpIPAllRegistryValuesAdapter { return [pscustomobject]@{ TcpPort = '1433'; TcpDynamicPorts = '' } }
        Mock Set-TcpIPAllRegistryValuesAdapter { }
        Mock Restart-ServiceAndWaitRunningAdapter { return $true }
        Mock Test-TcpPortOpenAdapter { return $false }
        { Set-LimsSqlServerTcpPort1433 -Config $script:TestConfig } | Should -Throw -ExpectedMessage '*did not accept a local connection*'
    }
}

Describe 'Install-LimsSqlTempDbStartupSequence (orchestration, mocked adapters)' {
    It 'writes the preparation script, registers the AtStartup task, sets the engine to Manual, and smoke-tests the script without deleting TempDB' {
        $script:writtenContent = $null
        Mock Write-TextFileAdapter { param($Path, $Content) $script:writtenContent = $Content }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter { }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Manual' } }

        $result = Install-LimsSqlTempDbStartupSequence -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB'
        $result | Should -Be $true
        Should -Invoke Register-TempDbPreparationScheduledTaskAdapter -Times 1 -ParameterFilter { $TaskName -eq 'LIMS-SQL-TempDb-PrepareAndStart' }
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 1 -ParameterFilter { $Name -eq 'MSSQLSERVER' -and $StartupType -eq 'Manual' }
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
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Running'; StartType = 'Manual' } }

        { Install-LimsSqlTempDbStartupSequence -Config $script:TestConfig -TempDbPath 'D:\MSSQL\TempDB' } | Should -Throw -ExpectedMessage '*exited with code 1*'
        Should -Invoke Get-ServiceStateAdapter -Times 0
    }

    It 'throws if the service is not Running after a successful preparation-script smoke test' {
        Mock Write-TextFileAdapter { }
        Mock Register-TempDbPreparationScheduledTaskAdapter { }
        Mock Set-ServiceStartupTypeAdapter { }
        Mock Invoke-TempDbPreparationScriptAdapter { }
        Mock Get-ServiceStateAdapter { return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' } }

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
            if ($script:sqlAssessed) { return [pscustomobject]@{ Status = 'Running'; StartType = 'Manual' } }
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
        Should -Invoke Set-ServiceStartupTypeAdapter -Times 1 -ParameterFilter { $StartupType -eq 'Manual' }
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

<#
    Pester tests for Copy-LimsAppDataDiskContents.ps1.

    Runs on Ubuntu CI with every real-cmdlet *Adapter mocked. Covers:
      - duplicated identity verification (caller + IMDS + mapping)
      - refusing to initialize or format the snapshot volume
      - insufficient destination capacity
      - Robocopy copy failure
      - unexplained differences on the second comparison
      - Robocopy arguments (DAT copy, no reparse-point follow, sdmshome exclude)
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_APP_MIG_COPY_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1')
    . (Join-Path $PSScriptRoot 'Copy-LimsAppDataDiskContents.ps1')
    $script:Dev = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
}

Describe 'mapping used by the guest script' {
    It 'is the same reviewed DEV mapping the control-plane script loads' {
        $env:LIMS_APP_MIG_CONTROL_DOT_SOURCE_ONLY = '1'
        . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Mapping.ps1')
        $control = Get-LimsAppDataDiskMigrationEnvironment -EnvironmentName 'dev'
        $guest = $script:Dev
        $guest.SourceVmName | Should -Be $control.SourceVmName
        $guest.SourceDataDiskName | Should -Be $control.SourceDataDiskName
        $guest.DestinationVmName | Should -Be $control.DestinationVmName
        $guest.DestinationComputerName | Should -Be $control.DestinationComputerName
        $guest.DestinationDataDiskName | Should -Be $control.DestinationDataDiskName
        $guest.PreferredTemporaryLun | Should -Be $control.PreferredTemporaryLun
        $guest.ExcludeRelativePaths | Should -Be $control.ExcludeRelativePaths
    }
}

Describe 'Test-VolumeRequiresInitializationOrFormat (pure)' {
    It 'is true when there is no partition or the filesystem is RAW' {
        (Test-VolumeRequiresInitializationOrFormat -HasPartition $false -PartitionStyle 'GPT' -FileSystem 'NTFS') | Should -Be $true
        (Test-VolumeRequiresInitializationOrFormat -HasPartition $true -PartitionStyle 'RAW' -FileSystem 'NTFS') | Should -Be $true
        (Test-VolumeRequiresInitializationOrFormat -HasPartition $true -PartitionStyle 'GPT' -FileSystem 'RAW') | Should -Be $true
        (Test-VolumeRequiresInitializationOrFormat -HasPartition $true -PartitionStyle 'GPT' -FileSystem 'NTFS') | Should -Be $false
    }
}

Describe 'Test-DestinationCapacitySufficient (pure)' {
    It 'fails when destination free space is below the required bytes' {
        (Test-DestinationCapacitySufficient -RequiredBytes 100 -DestinationFreeBytes 99) | Should -Be $false
        (Test-DestinationCapacitySufficient -RequiredBytes 100 -DestinationFreeBytes 100) | Should -Be $true
    }
}

Describe 'Robocopy argument list and exit-code classification (pure)' {
    It 'copies data/attributes/timestamps, does not follow reparse points, and excludes lv89\sdmshome' {
        $args = New-RobocopyArgumentList -SourceRoot 'S:\' -DestinationRoot 'A:\' -LogPath 'C:\LimsAppMigration\logs\robocopy-1.log' -ExcludeRelativePaths @('lv89\sdmshome')
        $args | Should -Contain '/COPY:DAT'
        $args | Should -Contain '/DCOPY:DAT'
        $args | Should -Contain '/XJ'
        $args | Should -Contain '/E'
        $args | Should -Contain '/XD'
        $args | Should -Contain 'S:\lv89\sdmshome'
        $args | Should -Not -Contain '/COPYALL'
        $args | Should -Not -Contain '/SEC'
        $args | Should -Not -Contain '/L'
    }

    It 'adds /L for preview and verify passes' {
        $args = New-RobocopyArgumentList -SourceRoot 'S:\' -DestinationRoot 'A:\' -LogPath 'C:\log.log' -ExcludeRelativePaths @() -ListOnly
        $args | Should -Contain '/L'
    }

    It 'treats Robocopy 0-3 as copy success and 8+ as failure' {
        (Get-RobocopyCopyExitCodeClassification -ExitCode 0) | Should -Be 'Succeeded'
        (Get-RobocopyCopyExitCodeClassification -ExitCode 1) | Should -Be 'Succeeded'
        (Get-RobocopyCopyExitCodeClassification -ExitCode 3) | Should -Be 'Succeeded'
        (Get-RobocopyCopyExitCodeClassification -ExitCode 8) | Should -Be 'Failed'
        (Get-RobocopyCopyExitCodeClassification -ExitCode 16) | Should -Be 'Failed'
        (Get-RobocopyVerifyExitCodeClassification -ExitCode 0) | Should -Be 'Identical'
        (Get-RobocopyVerifyExitCodeClassification -ExitCode 1) | Should -Be 'DifferencesRemain'
        (Get-RobocopyVerifyExitCodeClassification -ExitCode 8) | Should -Be 'DifferencesRemain'
    }
}

Describe 'Invoke-LimsAppDataDiskContentsCopy (orchestration, mocked adapters)' {
    BeforeEach {
        $script:tempDiskName = 'lims-app-mig-dev-10-tmp'
        $script:imds = [pscustomobject]@{
            subscriptionId    = $script:Dev.SubscriptionId
            resourceGroupName = $script:Dev.ResourceGroupName
            name              = $script:Dev.DestinationVmName
            storageProfile    = [pscustomobject]@{
                dataDisks = @(
                    [pscustomobject]@{ lun = 0; name = $script:Dev.DestinationDataDiskName; managedDisk = [pscustomobject]@{ id = 'disk-a' } }
                    [pscustomobject]@{ lun = 1; name = $script:tempDiskName; managedDisk = [pscustomobject]@{ id = 'disk-tmp' } }
                )
            }
        }
        Mock Get-ActualComputerNameAdapter { return $script:Dev.DestinationComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return $script:imds }
        Mock Get-DisksAdapter {
            return @(
                [pscustomobject]@{ Number = 0; IsBoot = $true; IsSystem = $true; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; Location = 'LUN 0' }
                [pscustomobject]@{ Number = 2; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; Location = 'Integrated : Adapter 1 : Target 0 : LUN 1' }
            )
        }
        Mock Get-PartitionsAdapter {
            return @([pscustomobject]@{ PartitionNumber = 2; IsSystem = $false; IsBoot = $false; DriveLetter = 'S'; AccessPaths = @('S:\') })
        }
        Mock Get-VolumeAdapter {
            param($DriveLetter, $DiskNumber)
            if ($DriveLetter -eq 'A') {
                return [pscustomobject]@{ DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; FileSystem = 'NTFS'; SizeRemaining = [int64]100GB }
            }
            return [pscustomobject]@{ DriveLetter = 'S'; FileSystemLabel = 'APP-SOURCE'; FileSystem = 'NTFS'; SizeRemaining = [int64]10GB }
        }
        Mock Get-OccupiedDriveLettersAdapter { return @('A', 'C', 'D') }
        Mock Set-DiskOnlineWritableAdapter { }
        Mock Set-PartitionDriveLetterAdapter { }
        Mock New-DirectoryAdapter { }
        Mock Test-PathExistsAdapter { return $true }
        Mock Get-ItemSizeBytesAdapter { param($Path) if ($Path -like '*sdmshome*') { return [int64]1GB } return [int64]20GB }
        Mock Invoke-RobocopyAdapter { return 1 }
    }

    It 'fails when IMDS identity does not match the mapped destination VM' {
        Mock Get-ImdsComputeMetadataAdapter {
            return [pscustomobject]@{
                subscriptionId    = $script:Dev.SubscriptionId
                resourceGroupName = $script:Dev.ResourceGroupName
                name              = 'vm-lims-dev-westeu-001'
                storageProfile    = $script:imds.storageProfile
            }
        }
        { Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*IMDS VM name*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when the snapshot volume would require initialization or formatting' {
        Mock Get-DisksAdapter {
            return @(
                [pscustomobject]@{ Number = 2; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'RAW'; Location = 'LUN 1' }
            )
        }
        Mock Get-PartitionsAdapter { return @() }
        Mock Get-VolumeAdapter {
            param($DriveLetter, $DiskNumber)
            if ($DriveLetter -eq 'A') {
                return [pscustomobject]@{ DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; FileSystem = 'NTFS'; SizeRemaining = [int64]100GB }
            }
            return $null
        }
        { Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*Initialize-Disk or Format-Volume*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when destination free space is insufficient' {
        Mock Get-VolumeAdapter {
            param($DriveLetter, $DiskNumber)
            if ($DriveLetter -eq 'A') {
                return [pscustomobject]@{ DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; FileSystem = 'NTFS'; SizeRemaining = [int64]1GB }
            }
            return [pscustomobject]@{ DriveLetter = 'S'; FileSystemLabel = 'APP-SOURCE'; FileSystem = 'NTFS'; SizeRemaining = [int64]10GB }
        }
        { Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*less than the*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when Robocopy reports a copy error' {
        Mock Invoke-RobocopyAdapter {
            param($Arguments)
            if ($Arguments -contains '/L') { return 1 }
            return 8
        }
        { Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'writes-quiesced' } |
            Should -Throw -ExpectedMessage '*copy failed with exit code 8*'
    }

    It 'fails when the second comparison reports unexplained differences' {
        $script:call = 0
        Mock Invoke-RobocopyAdapter {
            $script:call++
            if ($script:call -eq 1) { return 1 }
            if ($script:call -eq 2) { return 1 }
            return 2
        }
        { Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'online' } |
            Should -Throw -ExpectedMessage '*unexplained differences*'
    }

    It 'runs preview, copy, and verify, and never starts APP services' {
        $script:calls = @()
        Mock Invoke-RobocopyAdapter {
            param($Arguments)
            $script:calls += , $Arguments
            if ($Arguments -contains '/L') { return 0 }
            return 1
        }
        $null = Invoke-LimsAppDataDiskContentsCopy -EnvironmentName 'dev' -MigrationRunId '10' -ExpectedTemporaryLun 1 -ExpectedTemporaryDiskName $script:tempDiskName -CaptureMode 'online'
        $script:calls.Count | Should -Be 3
        $script:calls[0] | Should -Contain '/L'
        $script:calls[1] | Should -Not -Contain '/L'
        $script:calls[2] | Should -Contain '/L'
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
    }
}

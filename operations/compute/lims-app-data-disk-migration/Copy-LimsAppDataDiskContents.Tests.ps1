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
    . (Join-Path $PSScriptRoot 'LimsAppDataDiskMigration.Safety.ps1')
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
        $guest.DestinationAttestedGuestUniqueId | Should -Be '60022480D1B07E6ACD98417F86591F4B'
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
        $script:tempDiskName = 'lims-app-mig-dev-tmp'
        $script:tempDiskId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/disks/$script:tempDiskName"
        $script:destDiskId = "/subscriptions/$($script:Dev.SubscriptionId)/resourceGroups/$($script:Dev.ResourceGroupName)/providers/Microsoft.Compute/disks/$($script:Dev.DestinationDataDiskName)"
        $script:tempUid = 'TEMPDISKUID'
        $script:destUid = $script:Dev.DestinationAttestedGuestUniqueId
        $script:imds = [pscustomobject]@{
            subscriptionId    = $script:Dev.SubscriptionId
            resourceGroupName = $script:Dev.ResourceGroupName
            name              = $script:Dev.DestinationVmName
            storageProfile    = [pscustomobject]@{
                resourceDisk = [pscustomobject]@{ size = 201728 }
                dataDisks    = @(
                    [pscustomobject]@{ lun = 0; name = $script:Dev.DestinationDataDiskName; managedDisk = [pscustomobject]@{ id = $script:destDiskId } }
                    [pscustomobject]@{ lun = 1; name = $script:tempDiskName; managedDisk = [pscustomobject]@{ id = $script:tempDiskId } }
                )
            }
        }
        $script:guestDisks = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = $script:destUid; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = 128GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 2; UniqueId = $script:tempUid; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = 128GB; ScsiLogicalUnit = 1 }
            [pscustomobject]@{ Number = 3; UniqueId = 'RESOURCEDISK'; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = [int64]161059207680; ScsiLogicalUnit = 1 }
        )
        $script:partitions = @(
            [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; DriveLetter = 'A'; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ DiskNumber = 2; PartitionNumber = 2; DriveLetter = 'S'; IsSystem = $false; IsBoot = $false }
        )
        Mock Get-ActualComputerNameAdapter { return $script:Dev.DestinationComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return $script:imds }
        Mock Get-GuestDiskInventoryAdapter { return $script:guestDisks }
        Mock Get-GuestPartitionInventoryAdapter { return $script:partitions }
        Mock Get-DisksAdapter { return $script:guestDisks }
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
        Mock Get-LogicalDiskDriveTypeAdapter { return 3 }
        Mock Test-PathIsReparsePointAdapter { return $false }
        Mock Get-PathTargetAdapter { return '' }
        Mock Get-ChildEntriesAdapter { return @() }
        Mock Invoke-RobocopyAdapter { return 1 }
        $script:CopyParams = @{
            EnvironmentName                   = 'dev'
            MigrationRunId                    = '10'
            ExpectedTemporaryLun              = 1
            ExpectedTemporaryDiskName         = $script:tempDiskName
            ExpectedTemporaryDiskResourceId   = $script:tempDiskId
            ExpectedDestinationDiskResourceId = $script:destDiskId
            ExpectedTemporaryDiskUniqueId     = $script:tempUid
            ExpectedDestinationDiskUniqueId   = $script:destUid
            CaptureMode                       = 'online'
        }
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
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*IMDS VM name*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when A: is on the wrong Windows disk even if the LIMS-App label matches' {
        Mock Get-GuestPartitionInventoryAdapter {
            return @(
                [pscustomobject]@{ DiskNumber = 9; PartitionNumber = 2; DriveLetter = 'A'; IsSystem = $false; IsBoot = $false }
                [pscustomobject]@{ DiskNumber = 2; PartitionNumber = 2; DriveLetter = 'S'; IsSystem = $false; IsBoot = $false }
            )
        }
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*not the resolved managed disk*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
    }

    It 'copies despite the DEV IMDS/Windows temporary-disk size discrepancy and SCSI LUN 1 collision' {
        Mock Invoke-RobocopyAdapter {
            param($Arguments)
            if ($Arguments -contains '/L') { return 0 }
            return 1
        }
        $null = Invoke-LimsAppDataDiskContentsCopy @script:CopyParams
        Should -Invoke Invoke-RobocopyAdapter -Times 3
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
    }

    It 'dumps inventory and stops before Set-Disk when the snapshot-disk UniqueId is missing' {
        $script:CopyParams.ExpectedTemporaryDiskUniqueId = ''
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*no attested or captured UniqueId*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
        Should -Invoke Set-PartitionDriveLetterAdapter -Times 0
    }

    It 'collects read-only inventory, proves the UniqueId binding, and stops before mutation' {
        $stream = @(Invoke-LimsAppDataDiskContentsCopy @script:CopyParams -CollectInventoryOnly)
        $result = @($stream | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Status'] -and $_.Status -eq 'InventoryOnly' }) | Select-Object -Last 1
        $result | Should -Not -BeNullOrEmpty
        $result.DestinationDisk.Number | Should -Be 1
        $result.DestinationDisk.UniqueId | Should -Be $script:destUid
        $result.TemporaryDisk.Number | Should -Be 2
        $result.TemporaryDisk.UniqueId | Should -Be $script:tempUid
        Should -Invoke Invoke-RobocopyAdapter -Times 0
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
        Should -Invoke Set-PartitionDriveLetterAdapter -Times 0
    }

    It 'fails when the snapshot volume would require initialization or formatting' {
        $script:guestDisks = @(
            [pscustomobject]@{ Number = 0; UniqueId = 'OSDISK'; IsBoot = $true; IsSystem = $true; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = 127GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 1; UniqueId = $script:destUid; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT'; SizeBytes = 512GB; ScsiLogicalUnit = 0 }
            [pscustomobject]@{ Number = 2; UniqueId = $script:tempUid; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'RAW'; SizeBytes = 512GB; ScsiLogicalUnit = 1 }
        )
        Mock Get-PartitionsAdapter { return @() }
        Mock Get-VolumeAdapter {
            param($DriveLetter, $DiskNumber)
            if ($DriveLetter -eq 'A') {
                return [pscustomobject]@{ DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; FileSystem = 'NTFS'; SizeRemaining = [int64]100GB }
            }
            return $null
        }
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*Initialize-Disk or Format-Volume*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when destination free space is insufficient' {
        Mock Get-ChildEntriesAdapter {
            return @([pscustomobject]@{ FullName = 'S:\payload.bin'; PSIsContainer = $false; Attributes = [System.IO.FileAttributes]::Archive; Length = 20GB })
        }
        Mock Get-VolumeAdapter {
            param($DriveLetter, $DiskNumber)
            if ($DriveLetter -eq 'A') {
                return [pscustomobject]@{ DriveLetter = 'A'; FileSystemLabel = 'LIMS-App'; FileSystem = 'NTFS'; SizeRemaining = [int64]1GB }
            }
            return [pscustomobject]@{ DriveLetter = 'S'; FileSystemLabel = 'APP-SOURCE'; FileSystem = 'NTFS'; SizeRemaining = [int64]10GB }
        }
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*less than the*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when a destination reparse point is in a path the copy could write' {
        Mock Get-ChildEntriesAdapter {
            param($Path)
            if ($Path -like 'A:*') {
                return @([pscustomobject]@{ FullName = 'A:\app\link'; PSIsContainer = $true; Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint; Length = 0 })
            }
            return @()
        }
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*Destination reparse*'
        Should -Invoke Invoke-RobocopyAdapter -Times 0
    }

    It 'fails when Robocopy reports a copy error' {
        Mock Invoke-RobocopyAdapter {
            param($Arguments)
            if ($Arguments -contains '/L') { return 1 }
            return 8
        }
        $script:CopyParams.CaptureMode = 'writes-quiesced'
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*copy failed with exit code 8*'
    }

    It 'fails when the second comparison reports unexplained differences' {
        $script:call = 0
        Mock Invoke-RobocopyAdapter {
            $script:call++
            if ($script:call -eq 1) { return 1 }
            if ($script:call -eq 2) { return 1 }
            return 2
        }
        { Invoke-LimsAppDataDiskContentsCopy @script:CopyParams } | Should -Throw -ExpectedMessage '*unexplained differences*'
    }

    It 'runs preview, copy, and verify, and never starts APP services' {
        $script:calls = @()
        Mock Invoke-RobocopyAdapter {
            param($Arguments)
            $script:calls += , $Arguments
            if ($Arguments -contains '/L') { return 0 }
            return 1
        }
        $null = Invoke-LimsAppDataDiskContentsCopy @script:CopyParams
        $script:calls.Count | Should -Be 3
        $script:calls[0] | Should -Contain '/L'
        $script:calls[1] | Should -Not -Contain '/L'
        $script:calls[2] | Should -Contain '/L'
        Should -Invoke Set-DiskOnlineWritableAdapter -Times 0
    }
}

Describe 'Real Windows Robocopy junction exercise' {
    It 'copies local files, excludes lv89\sdmshome, and does not follow source or destination junctions' {
        $isWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.PSEdition -eq 'Desktop'
        if (-not $isWindows) {
            Set-ItResult -Skipped -Because 'Not a Windows host; Robocopy/mklink cannot be exercised. Stage and cleanup stay BlockedPendingValidation.'
            return
        }
        $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
        if (-not $robocopy) {
            Set-ItResult -Skipped -Because 'robocopy.exe is not on PATH. Stage and cleanup stay BlockedPendingValidation.'
            return
        }

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("lims-app-mig-reparse-" + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'source'
        $dest = Join-Path $root 'dest'
        $outside = Join-Path $root 'outside'
        New-Item -ItemType Directory -Path (Join-Path $source 'temp') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'lv89') -Force | Out-Null
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'keep.txt') -Value 'keep-local' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $source 'temp\work.txt') -Value 'temp-ok' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $outside 'secret.txt') -Value 'should-not-copy' -Encoding ascii

        $createdJunction = $false
        $sdms = Join-Path $source 'lv89\sdmshome'
        cmd.exe /c "mklink /J `"$sdms`" `"$outside`"" | Out-Null
        if (Test-Path -LiteralPath $sdms) { $createdJunction = $true }

        $srcLink = Join-Path $source 'unexpected-link'
        cmd.exe /c "mklink /J `"$srcLink`" `"$outside`"" | Out-Null
        $destLink = Join-Path $dest 'dest-link'
        cmd.exe /c "mklink /J `"$destLink`" `"$outside`"" | Out-Null

        try {
            if (-not $createdJunction) {
                Set-ItResult -Skipped -Because 'Unable to create a Windows junction for lv89\sdmshome. Stage and cleanup stay BlockedPendingValidation.'
                return
            }
            $log = Join-Path $root 'robocopy.log'
            $args = New-RobocopyArgumentList -SourceRoot $source -DestinationRoot $dest -LogPath $log -ExcludeRelativePaths @('lv89\sdmshome')
            $exit = & robocopy.exe @args
            $code = [int]$LASTEXITCODE
            $class = Get-RobocopyCopyExitCodeClassification -ExitCode $code
            $class | Should -Be 'Succeeded'

            (Join-Path $dest 'keep.txt') | Should -Exist
            (Join-Path $dest 'temp\work.txt') | Should -Exist
            Test-Path -LiteralPath (Join-Path $dest 'lv89\sdmshome') | Should -Be $false
            if (Test-Path -LiteralPath (Join-Path $dest 'unexpected-link')) {
                $item = Get-Item -LiteralPath (Join-Path $dest 'unexpected-link') -Force
                ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
                Test-Path -LiteralPath (Join-Path $dest 'unexpected-link\secret.txt') | Should -Be $false
            }
            Get-Content -LiteralPath (Join-Path $outside 'secret.txt') -Raw | Should -Match 'should-not-copy'
        }
        finally {
            cmd.exe /c "rmdir `"$sdms`"" 2>$null | Out-Null
            cmd.exe /c "rmdir `"$srcLink`"" 2>$null | Out-Null
            cmd.exe /c "rmdir `"$destLink`"" 2>$null | Out-Null
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Real Windows Robocopy directory-symbolic-link exercise' {
    It 'neither previews nor copies through a directory symbolic link at lv89\sdmshome, and a destination symbolic link blocks the copy' {
        $isWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.PSEdition -eq 'Desktop'
        if (-not $isWindows) {
            Set-ItResult -Skipped -Because 'Not a Windows host; directory symbolic links cannot be exercised. Stage and cleanup stay BlockedPendingValidation.'
            return
        }
        $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
        if (-not $robocopy) {
            Set-ItResult -Skipped -Because 'robocopy.exe is not on PATH. Stage and cleanup stay BlockedPendingValidation.'
            return
        }

        function New-DirectorySymbolicLink {
            param([string] $LinkPath, [string] $TargetPath)
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction SilentlyContinue | Out-Null
            if (-not (Test-Path -LiteralPath $LinkPath)) {
                cmd.exe /c "mklink /D `"$LinkPath`" `"$TargetPath`"" | Out-Null
            }
            if (-not (Test-Path -LiteralPath $LinkPath)) { return $false }
            $item = Get-Item -LiteralPath $LinkPath -Force
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
            if ($item.PSObject.Properties['LinkType'] -and [string]$item.LinkType -eq 'Junction') { return $false }
            return $true
        }

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("lims-app-mig-symlink-" + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $root 'source'
        $dest = Join-Path $root 'dest'
        $standIn = Join-Path $root 'share-stand-in'
        New-Item -ItemType Directory -Path (Join-Path $source 'temp') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'lv89') -Force | Out-Null
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        New-Item -ItemType Directory -Path $standIn -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'keep.txt') -Value 'keep-local' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $source 'temp\work.txt') -Value 'temp-ok' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $standIn 'secret.txt') -Value 'should-not-copy' -Encoding ascii

        $sdms = Join-Path $source 'lv89\sdmshome'
        $createdSymlink = New-DirectorySymbolicLink -LinkPath $sdms -TargetPath $standIn
        $destBlockRoot = Join-Path $root 'dest-with-link'
        $destApp = Join-Path $destBlockRoot 'app'
        New-Item -ItemType Directory -Path $destApp -Force | Out-Null
        $destLink = Join-Path $destApp 'redirect'
        $createdDestSymlink = New-DirectorySymbolicLink -LinkPath $destLink -TargetPath $standIn

        try {
            if (-not $createdSymlink) {
                Set-ItResult -Skipped -Because 'Unable to create a directory symbolic link at lv89\sdmshome (privilege or Developer Mode required). Stage and cleanup stay BlockedPendingValidation.'
                return
            }
            $sdmsItem = Get-Item -LiteralPath $sdms -Force
            [string]$sdmsItem.LinkType | Should -Be 'SymbolicLink'

            $exclude = @('lv89\sdmshome')
            $sourceReparse = @(Get-ReparseRelativePathsUnderRoot -Root $source -ExcludeRelativePaths $exclude)
            $sourceReparse | Should -Contain 'lv89\sdmshome'
            $previewPolicy = Test-ReparsePointPolicy -SourceReparseRelativePaths $sourceReparse -DestinationReparseRelativePaths @() -ExcludeRelativePaths $exclude
            $previewPolicy.Accepted | Should -Be $true

            $log = Join-Path $root 'robocopy.log'
            $previewArgs = New-RobocopyArgumentList -SourceRoot $source -DestinationRoot $dest -LogPath $log -ExcludeRelativePaths $exclude -ListOnly
            $null = & robocopy.exe @previewArgs
            $previewClass = Get-RobocopyCopyExitCodeClassification -ExitCode ([int]$LASTEXITCODE)
            $previewClass | Should -Be 'Succeeded'
            Test-Path -LiteralPath (Join-Path $dest 'keep.txt') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $dest 'lv89\sdmshome') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $dest 'lv89\sdmshome\secret.txt') | Should -Be $false

            $copyArgs = New-RobocopyArgumentList -SourceRoot $source -DestinationRoot $dest -LogPath $log -ExcludeRelativePaths $exclude
            $null = & robocopy.exe @copyArgs
            $copyClass = Get-RobocopyCopyExitCodeClassification -ExitCode ([int]$LASTEXITCODE)
            $copyClass | Should -Be 'Succeeded'
            (Join-Path $dest 'keep.txt') | Should -Exist
            (Join-Path $dest 'temp\work.txt') | Should -Exist
            Test-Path -LiteralPath (Join-Path $dest 'lv89\sdmshome') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $dest 'secret.txt') | Should -Be $false
            Get-Content -LiteralPath (Join-Path $standIn 'secret.txt') -Raw | Should -Match 'should-not-copy'

            if (-not $createdDestSymlink) {
                Set-ItResult -Skipped -Because 'Source directory symbolic link was proven, but a destination directory symbolic link could not be created. Stage and cleanup stay BlockedPendingValidation.'
                return
            }
            $destReparse = @(Get-ReparseRelativePathsUnderRoot -Root $destBlockRoot -ExcludeRelativePaths $exclude)
            $destReparse | Should -Contain 'app\redirect'
            $block = Test-ReparsePointPolicy -SourceReparseRelativePaths @('lv89\sdmshome') -DestinationReparseRelativePaths $destReparse -ExcludeRelativePaths $exclude
            $block.Accepted | Should -Be $false
            $block.Reason | Should -Match 'Destination reparse'
        }
        finally {
            foreach ($linkPath in @($sdms, $destLink)) {
                if ($linkPath -and (Test-Path -LiteralPath $linkPath)) {
                    cmd.exe /c "rmdir `"$linkPath`" >nul 2>&1" | Out-Null
                }
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

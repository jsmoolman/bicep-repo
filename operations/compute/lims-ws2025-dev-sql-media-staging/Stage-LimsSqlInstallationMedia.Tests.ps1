<#
    Pester tests for Stage-LimsSqlInstallationMedia.ps1.

    SCOPE. These tests run on Ubuntu CI (Pester on Linux; no real Windows
    filesystem/IMDS/network access) and exercise exactly two kinds of code
    in the real script, unmodified:

      1. The PURE decision/planning functions (ConvertFrom-BlobListingXml,
         Test-SafeStagingRelativePath, Get-LimsSqlMediaStagingBlobPlanEntries,
         Get-FileDownloadDecision, Get-RequiredFreeBytes,
         Test-SufficientFreeSpace, Get-UniqueStagingDirectories) -- called
         directly with plain fake data. This is where the actual safety
         logic lives, and it is Linux-testable because none of these
         functions call a real cmdlet.

      2. The ORCHESTRATION functions (Assert-StagingTargetIdentity,
         Get-LimsSqlMediaStagingFullListing, Get-LimsSqlMediaStagingPlan,
         Invoke-LimsSqlMediaStagingPlanApply, Test-LimsSqlMediaStagingComplete,
         Invoke-LimsSqlMediaStaging) -- called for real, but with every
         *Adapter function (the only functions that would call a real
         cmdlet/network/filesystem) replaced with a Pester Mock.

    These tests specifically cover, per the task's explicit request:
      - Pagination across multiple Blob-listing pages.
      - Path rejection (traversal, reserved names, collisions).
      - Insufficient free space.
      - An interrupted copy followed by a rerun.

    PowerShell 5.1 guest-runtime compatibility is checked separately by
    PSScriptAnalyzer (see PSScriptAnalyzerSettings.psd1 in this same
    directory and .azuredevops/pipelines/ci.yml) -- not duplicated here.
    No disposable VM/Windows CI runner exists for this repository, so real
    guest execution (actual IMDS reachability, actual Blob REST calls,
    actual NTFS reparse-point behavior, actual Managed Run Command
    delivery) has not been rehearsed anywhere, by this suite or otherwise.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_SQL_MEDIA_STAGING_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'Stage-LimsSqlInstallationMedia.ps1')

    $script:TestConfig = Get-LimsSqlMediaStagingFixedConfig

    function New-BlobListingXmlPage {
        param(
            [Parameter(Mandatory = $true)] [hashtable[]] $Blobs,
            [string] $NextMarker = ''
        )
        $blobXml = ($Blobs | ForEach-Object {
                "<Blob><Name>$($_.Name)</Name><Properties><Content-Length>$($_.Length)</Content-Length></Properties></Blob>"
            }) -join ''
        return "<?xml version=`"1.0`" encoding=`"utf-8`"?><EnumerationResults><Blobs>$blobXml</Blobs><NextMarker>$NextMarker</NextMarker></EnumerationResults>"
    }
}

Describe 'ConvertFrom-BlobListingXml (pure)' {
    It 'parses a single page with no NextMarker' {
        $xml = New-BlobListingXmlPage -Blobs @(
            @{ Name = 'SETUP.EXE'; Length = 1024 }
            @{ Name = 'x64/setup.exe'; Length = 2048 }
        )
        $result = ConvertFrom-BlobListingXml -XmlText $xml
        $result.Blobs.Count | Should -Be 2
        $result.Blobs[0].Name | Should -Be 'SETUP.EXE'
        $result.Blobs[0].Length | Should -Be 1024
        $result.Blobs[1].Length | Should -Be 2048
        $result.NextMarker | Should -BeNullOrEmpty
    }

    It 'parses a page that carries a NextMarker (pagination)' {
        $xml = New-BlobListingXmlPage -Blobs @(@{ Name = 'a.txt'; Length = 1 }) -NextMarker 'marker-page-2'
        $result = ConvertFrom-BlobListingXml -XmlText $xml
        $result.NextMarker | Should -Be 'marker-page-2'
    }

    It 'parses a page with zero blobs without producing a phantom entry' {
        $xml = '<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs></Blobs><NextMarker></NextMarker></EnumerationResults>'
        $result = ConvertFrom-BlobListingXml -XmlText $xml
        @($result.Blobs).Count | Should -Be 0
    }

    It 'throws on malformed XML' {
        { ConvertFrom-BlobListingXml -XmlText 'not xml at all <<<' } | Should -Throw
    }
}

Describe 'Test-SafeStagingRelativePath (pure)' {
    It 'accepts a normal nested blob name and preserves folder structure' {
        $result = Test-SafeStagingRelativePath -BlobName 'x64/setup/SETUP.EXE' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeTrue
        $result.RelativePath | Should -Be 'x64\setup\SETUP.EXE'
        $result.Segments.Count | Should -Be 3
    }

    It 'accepts a top-level blob name' {
        $result = Test-SafeStagingRelativePath -BlobName 'README.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeTrue
    }

    It 'rejects a blob name with a parent-traversal segment' {
        $result = Test-SafeStagingRelativePath -BlobName '../evil.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
        $result.Reason | Should -Match 'traversal'
    }

    It 'rejects a blob name with an embedded parent-traversal segment' {
        $result = Test-SafeStagingRelativePath -BlobName 'a/../../b.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects an absolute-path-shaped blob name (leading slash)' {
        $result = Test-SafeStagingRelativePath -BlobName '/etc/passwd' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a blob name containing a drive-letter segment' {
        $result = Test-SafeStagingRelativePath -BlobName 'C:/windows/x.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a blob name with an invalid Windows filename character' {
        $result = Test-SafeStagingRelativePath -BlobName 'a<b>.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a blob name with an embedded backslash' {
        $result = Test-SafeStagingRelativePath -BlobName 'a\b.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a reserved Windows device name segment' {
        $result = Test-SafeStagingRelativePath -BlobName 'setup/CON.ini' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
        $result.Reason | Should -Match 'reserved'
    }

    It 'rejects a bare reserved device name with no extension' {
        $result = Test-SafeStagingRelativePath -BlobName 'COM1' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a segment with a trailing dot' {
        $result = Test-SafeStagingRelativePath -BlobName 'folder./file.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a segment with a trailing space' {
        $result = Test-SafeStagingRelativePath -BlobName 'folder /file.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects an empty segment from a double slash' {
        $result = Test-SafeStagingRelativePath -BlobName 'a//b.txt' -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
    }

    It 'rejects a path that would exceed the classic Windows MAX_PATH' {
        $longSegment = 'x' * 260
        $result = Test-SafeStagingRelativePath -BlobName "folder/$longSegment.txt" -StagingRoot 'C:\SQLMedia\SQL2022'
        $result.Accepted | Should -BeFalse
        $result.Reason | Should -Match 'MAX_PATH'
    }
}

Describe 'Get-LimsSqlMediaStagingBlobPlanEntries (pure)' {
    It 'builds unblocked entries for a normal listing' {
        $blobs = @(
            [pscustomobject]@{ Name = 'SETUP.EXE'; Length = 100 }
            [pscustomobject]@{ Name = 'x64/setup.exe'; Length = 200 }
        )
        $plan = Get-LimsSqlMediaStagingBlobPlanEntries -Blobs $blobs -StagingRoot 'C:\SQLMedia\SQL2022'
        $plan.Blocked | Should -BeFalse
        $plan.Entries.Count | Should -Be 2
        ($plan.Entries | Where-Object { $_.BlobName -eq 'SETUP.EXE' }).DestinationPath | Should -Be 'C:\SQLMedia\SQL2022\SETUP.EXE'
    }

    It 'blocks the entire run on a single unsafe blob name (path rejection)' {
        $blobs = @(
            [pscustomobject]@{ Name = 'SETUP.EXE'; Length = 100 }
            [pscustomobject]@{ Name = '../escape.txt'; Length = 50 }
        )
        $plan = Get-LimsSqlMediaStagingBlobPlanEntries -Blobs $blobs -StagingRoot 'C:\SQLMedia\SQL2022'
        $plan.Blocked | Should -BeTrue
        $plan.Entries.Count | Should -Be 0
        $plan.Errors.Count | Should -BeGreaterThan 0
    }

    It 'blocks on a case-insensitive destination collision' {
        $blobs = @(
            [pscustomobject]@{ Name = 'Setup.exe'; Length = 100 }
            [pscustomobject]@{ Name = 'setup.exe'; Length = 100 }
        )
        $plan = Get-LimsSqlMediaStagingBlobPlanEntries -Blobs $blobs -StagingRoot 'C:\SQLMedia\SQL2022'
        $plan.Blocked | Should -BeTrue
        $plan.Errors[0] | Should -Match 'collision'
    }

    It 'blocks on an empty listing' {
        $plan = Get-LimsSqlMediaStagingBlobPlanEntries -Blobs @() -StagingRoot 'C:\SQLMedia\SQL2022'
        $plan.Blocked | Should -BeTrue
    }
}

Describe 'Get-FileDownloadDecision (pure)' {
    It 'decides Download when the file does not exist' {
        Get-FileDownloadDecision -ExpectedLength 100 -ExistingLength $null | Should -Be 'Download'
    }
    It 'decides Skip when lengths exactly match' {
        Get-FileDownloadDecision -ExpectedLength 100 -ExistingLength 100 | Should -Be 'Skip'
    }
    It 'decides Download when lengths mismatch' {
        Get-FileDownloadDecision -ExpectedLength 100 -ExistingLength 50 | Should -Be 'Download'
    }
    It 'treats a genuine zero-byte existing file as a real length, not missing' {
        Get-FileDownloadDecision -ExpectedLength 0 -ExistingLength 0 | Should -Be 'Skip'
    }
}

Describe 'Get-RequiredFreeBytes / Test-SufficientFreeSpace (pure)' {
    It 'sums only Download-decision entries plus the safety margin' {
        $entries = @(
            [pscustomobject]@{ ExpectedLength = 100; Decision = 'Download' }
            [pscustomobject]@{ ExpectedLength = 9999; Decision = 'Skip' }
            [pscustomobject]@{ ExpectedLength = 200; Decision = 'Download' }
        )
        Get-RequiredFreeBytes -Entries $entries -SafetyMarginBytes 50 | Should -Be 350
    }

    It 'reports insufficient free space with a clear reason' {
        $reason = Test-SufficientFreeSpace -RequiredBytes 1000 -AvailableBytes 500
        $reason | Should -Not -BeNullOrEmpty
    }

    It 'reports no error when space is sufficient' {
        Test-SufficientFreeSpace -RequiredBytes 1000 -AvailableBytes 1000 | Should -BeNullOrEmpty
    }
}

Describe 'Get-UniqueStagingDirectories (pure)' {
    It 'includes the staging root and every intermediate ancestor, de-duplicated' {
        $entries = @(
            [pscustomobject]@{ DestinationPath = 'C:\SQLMedia\SQL2022\x64\setup\SETUP.EXE' }
            [pscustomobject]@{ DestinationPath = 'C:\SQLMedia\SQL2022\x64\setup\other.msi' }
            [pscustomobject]@{ DestinationPath = 'C:\SQLMedia\SQL2022\README.txt' }
        )
        $dirs = Get-UniqueStagingDirectories -Entries $entries -StagingRoot 'C:\SQLMedia\SQL2022'
        $dirs | Should -Contain 'C:\SQLMedia\SQL2022'
        $dirs | Should -Contain 'C:\SQLMedia\SQL2022\x64'
        $dirs | Should -Contain 'C:\SQLMedia\SQL2022\x64\setup'
        @($dirs | Where-Object { $_ -eq 'C:\SQLMedia\SQL2022\x64\setup' }).Count | Should -Be 1
    }
}

Describe 'Get-LimsSqlMediaStagingFullListing (orchestration, mocked adapter) -- pagination' {
    It 'accumulates blobs across multiple pages following NextMarker' {
        Mock Invoke-BlobContainerListPageAdapter {
            if ([string]::IsNullOrWhiteSpace($Marker)) {
                return New-BlobListingXmlPage -Blobs @(@{ Name = 'page1-a.txt'; Length = 1 }, @{ Name = 'page1-b.txt'; Length = 2 }) -NextMarker 'go-to-page-2'
            }
            elseif ($Marker -eq 'go-to-page-2') {
                return New-BlobListingXmlPage -Blobs @(@{ Name = 'page2-a.txt'; Length = 3 }) -NextMarker 'go-to-page-3'
            }
            else {
                return New-BlobListingXmlPage -Blobs @(@{ Name = 'SETUP.EXE'; Length = 4 })
            }
        }
        $blobs = Get-LimsSqlMediaStagingFullListing -AccessToken 'fake-token' -Config $script:TestConfig
        $blobs.Count | Should -Be 4
        ($blobs | Where-Object { $_.Name -eq 'SETUP.EXE' }) | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-BlobContainerListPageAdapter -Times 3
    }

    # Get-LimsSqlMediaStagingFullListing's hard page-count cap (10000, see
    # $maxPages in the real function) exists specifically so a marker that
    # never clears fails closed instead of looping forever or silently
    # returning a truncated listing as success. Running that many mocked
    # round-trips in a unit test is impractical; the cap's presence is
    # reviewed by inspection rather than executed here, and the normal
    # multi-page termination path is already exercised by the test above.
}

Describe 'Get-LimsSqlMediaStagingPlan (orchestration, mocked adapters)' {
    BeforeEach {
        Mock Get-FreeBytesOnDriveAdapter { return [int64]1000000000000 }
        Mock Test-AncestorIsReparsePointAdapter { return $false }
        Mock Get-FileLengthIfExistsAdapter { return $null }
    }

    It 'returns an unblocked plan for a normal single-page listing' {
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'SETUP.EXE'; Length = 100 }, @{ Name = 'x64/setup.exe'; Length = 200 })
        }
        $plan = Get-LimsSqlMediaStagingPlan -AccessToken 'fake-token' -Config $script:TestConfig
        $plan.Blocked | Should -BeFalse
        $plan.Entries.Count | Should -Be 2
        ($plan.Entries | Where-Object { $_.Decision -eq 'Download' }).Count | Should -Be 2
    }

    It 'blocks the plan on a path-rejection fixture' {
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'SETUP.EXE'; Length = 100 }, @{ Name = '../escape.txt'; Length = 1 })
        }
        $plan = Get-LimsSqlMediaStagingPlan -AccessToken 'fake-token' -Config $script:TestConfig
        $plan.Blocked | Should -BeTrue
        $plan.Errors -join ' ' | Should -Match 'traversal'
        Should -Invoke Get-FreeBytesOnDriveAdapter -Times 0
    }

    It 'blocks the plan when a destination directory is an existing junction/symlink' {
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'x64/setup.exe'; Length = 100 })
        }
        Mock Test-AncestorIsReparsePointAdapter {
            param($Path)
            return ($Path -eq 'C:\SQLMedia\SQL2022\x64')
        }
        $plan = Get-LimsSqlMediaStagingPlan -AccessToken 'fake-token' -Config $script:TestConfig
        $plan.Blocked | Should -BeTrue
        $plan.Errors -join ' ' | Should -Match 'reparse point'
    }

    It 'blocks the plan on an insufficient-free-space fixture' {
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'bigfile.iso'; Length = 9999999999999 })
        }
        Mock Get-FreeBytesOnDriveAdapter { return [int64]100 }
        $plan = Get-LimsSqlMediaStagingPlan -AccessToken 'fake-token' -Config $script:TestConfig
        $plan.Blocked | Should -BeTrue
        $plan.Errors -join ' ' | Should -Match 'free bytes'
    }

    It 'decides Skip for a file whose existing length already matches (rerun-safe)' {
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'SETUP.EXE'; Length = 100 }, @{ Name = 'x64/setup.exe'; Length = 200 })
        }
        Mock Get-FileLengthIfExistsAdapter {
            param($Path)
            if ($Path -eq 'C:\SQLMedia\SQL2022\SETUP.EXE') { return [int64]100 }
            return $null
        }
        $plan = Get-LimsSqlMediaStagingPlan -AccessToken 'fake-token' -Config $script:TestConfig
        $plan.Blocked | Should -BeFalse
        ($plan.Entries | Where-Object { $_.BlobName -eq 'SETUP.EXE' }).Decision | Should -Be 'Skip'
        ($plan.Entries | Where-Object { $_.BlobName -eq 'x64/setup.exe' }).Decision | Should -Be 'Download'
    }
}

Describe 'Assert-StagingTargetIdentity (orchestration, mocked adapters) -- fail before any write' {
    It 'throws on a hostname mismatch and never queries the blob listing' {
        Mock Get-ActualComputerNameAdapter { return 'some-other-host' }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        Mock Invoke-BlobContainerListPageAdapter { return New-BlobListingXmlPage -Blobs @() }
        { Assert-StagingTargetIdentity -Config $script:TestConfig } | Should -Throw
        Should -Invoke Invoke-BlobContainerListPageAdapter -Times 0
    }

    It 'throws on an IMDS subscription mismatch' {
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = 'wrong-subscription'; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        { Assert-StagingTargetIdentity -Config $script:TestConfig } | Should -Throw
    }

    It 'passes when hostname and IMDS both match' {
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        { Assert-StagingTargetIdentity -Config $script:TestConfig } | Should -Not -Throw
    }
}

Describe 'Invoke-LimsSqlMediaStaging end-to-end (orchestration, mocked adapters) -- interrupted copy then rerun' {
    BeforeEach {
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { return $true }
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        Mock Set-Tls12SecurityProtocolAdapter { }
        Mock Get-ManagedIdentityAccessTokenAdapter { return 'fake-token-never-logged' }
        Mock Get-FreeBytesOnDriveAdapter { return [int64]1000000000000 }
        Mock Test-AncestorIsReparsePointAdapter { return $false }
        Mock New-StagingDirectoryAdapter { }
        Mock Move-StagingFileIntoPlaceAdapter { }
        Mock Remove-StagingTempFileAdapter { }
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(
                @{ Name = 'SETUP.EXE'; Length = 100 }
                @{ Name = 'x64/setup.exe'; Length = 200 }
            )
        }
        # Simulated on-disk state, mutated by the mocked adapters below to
        # model real interrupted-then-rerun behavior without any real I/O.
        $script:SimulatedDisk = @{}
    }

    It 'first run: a simulated interruption leaves the real destination untouched and fails the run; second run (rerun) completes and skips the already-correct file' {
        # ---- Run 1: SETUP.EXE downloads fully; x64/setup.exe's download is
        # "interrupted" (ends up short) -- the whole run must fail, and
        # SETUP.EXE's real destination must still end up correct because the
        # temp-file-then-verify-then-move sequence already completed for it
        # before the second file's failure was discovered.
        Mock Get-FileLengthIfExistsAdapter {
            param($Path)
            if ($script:SimulatedDisk.ContainsKey($Path)) { return $script:SimulatedDisk[$Path] }
            return $null
        }
        Mock Invoke-BlobDownloadToFileAdapter {
            param($AccessToken, $Config, $BlobName, $DestinationPath)
            if ($BlobName -eq 'SETUP.EXE') {
                $script:SimulatedDisk[$DestinationPath] = [int64]100
            }
            else {
                # Simulated interruption: temp file ends up shorter than expected.
                $script:SimulatedDisk[$DestinationPath] = [int64]50
            }
        }
        Mock Move-StagingFileIntoPlaceAdapter {
            param($TempPath, $DestinationPath)
            $script:SimulatedDisk[$DestinationPath] = $script:SimulatedDisk[$TempPath]
            $script:SimulatedDisk.Remove($TempPath)
        }

        { Invoke-LimsSqlMediaStaging } | Should -Throw -ExpectedMessage '*x64/setup.exe*'

        $script:SimulatedDisk['C:\SQLMedia\SQL2022\SETUP.EXE'] | Should -Be 100
        $script:SimulatedDisk.ContainsKey('C:\SQLMedia\SQL2022\x64\setup.exe') | Should -BeFalse
        Should -Invoke Remove-StagingTempFileAdapter -Times 1

        # ---- Run 2 (rerun): SETUP.EXE already matches -> Skip; only
        # x64/setup.exe is (re-)downloaded, this time completing fully.
        Mock Invoke-BlobDownloadToFileAdapter {
            param($AccessToken, $Config, $BlobName, $DestinationPath)
            $script:SimulatedDisk[$DestinationPath] = [int64]200
        }

        $summary = Invoke-LimsSqlMediaStaging

        $summary.ExpectedFileCount | Should -Be 2
        $summary.VerifiedFileCount | Should -Be 2
        $summary.FilesReused | Should -Be 1
        $summary.FilesCopied | Should -Be 1
        $summary.BytesCopied | Should -Be 200
        $summary.SetupExePath | Should -Be 'C:\SQLMedia\SQL2022\SETUP.EXE'

        # SETUP.EXE's adapter-level download was never invoked a second
        # time for the rerun -- only x64\setup.exe's temp file got a fresh
        # Invoke-BlobDownloadToFileAdapter call this second run.
        Should -Invoke Invoke-BlobDownloadToFileAdapter -Times 1 -ParameterFilter { $BlobName -eq 'x64/setup.exe' }
    }
}

Describe 'Invoke-LimsSqlMediaStaging -- fails closed when SETUP.EXE is absent from the source' {
    It 'throws final verification failure when no SETUP.EXE is present' {
        Mock Test-CurrentIdentityIsAdministratorOrSystemAdapter { return $true }
        Mock Get-ActualComputerNameAdapter { return $script:TestConfig.ExpectedComputerName }
        Mock Get-ImdsComputeMetadataAdapter { return [pscustomobject]@{ subscriptionId = $script:TestConfig.ExpectedSubscriptionId; resourceGroupName = $script:TestConfig.ExpectedResourceGroupName; name = $script:TestConfig.ExpectedVmName } }
        Mock Set-Tls12SecurityProtocolAdapter { }
        Mock Get-ManagedIdentityAccessTokenAdapter { return 'fake-token' }
        Mock Get-FreeBytesOnDriveAdapter { return [int64]1000000000000 }
        Mock Test-AncestorIsReparsePointAdapter { return $false }
        Mock New-StagingDirectoryAdapter { }
        Mock Remove-StagingTempFileAdapter { }
        Mock Invoke-BlobContainerListPageAdapter {
            return New-BlobListingXmlPage -Blobs @(@{ Name = 'readme.txt'; Length = 10 })
        }
        $disk = @{}
        Mock Get-FileLengthIfExistsAdapter { param($Path) if ($disk.ContainsKey($Path)) { return $disk[$Path] }; return $null }
        Mock Invoke-BlobDownloadToFileAdapter { param($DestinationPath) $disk[$DestinationPath] = [int64]10 }
        Mock Move-StagingFileIntoPlaceAdapter { param($TempPath, $DestinationPath) $disk[$DestinationPath] = $disk[$TempPath]; $disk.Remove($TempPath) }

        { Invoke-LimsSqlMediaStaging } | Should -Throw -ExpectedMessage '*SETUP.EXE*'
    }
}

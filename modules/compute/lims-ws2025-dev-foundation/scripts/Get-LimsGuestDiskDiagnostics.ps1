<#
.SYNOPSIS
    Read-only diagnostic report of disk/partition/volume/optical-device/
    platform mapping information relevant to
    Initialize-LimsGuestDataDisks.ps1's disk-identification logic.

.DESCRIPTION
    This script contains NO mutation commands -- it calls only Get-*
    cmdlets and read-only CIM queries, and never Initialize-Disk,
    New-Partition, Format-Volume, Set-CimInstance, or any other
    state-changing operation. It never prints a secret, access token, or
    identity/authentication artifact -- it queries only IMDS's `compute`
    document (never the `identity` endpoint, which is the one that could
    return an access token) and prints only resource identifiers (which the
    operator running this on their own VM already knows).

    Purpose: if Initialize-LimsGuestDataDisks.ps1's Select-NonOsNonTemporaryDiskCandidates
    or Get-DiskPreparationPlan/Get-DvdPreparationPlan fail closed with a
    message like "cannot positively establish..." on a real VM, run this
    script (manually, e.g. via Run Command or an interactive session) and
    share its output so the specific, real-world evidence needed to
    extend/adjust that logic can be reviewed -- rather than guessing.

    This script's output is a set of OBSERVATIONS about the one VM it is
    run on, at the moment it is run -- it is not a Microsoft-documented
    guarantee about any other VM, VM size, OS build, or point in time. The
    only genuinely documented facts it exercises are: Get-Disk's own
    IsBoot/IsSystem/IsOffline/IsReadOnly/OperationalStatus/BusType/
    PartitionStyle (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk),
    Win32_DiskDrive's SCSI addressing (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive),
    MSFT_Partition's AccessPaths/GptType/IsOffline/IsReadOnly
    (https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition),
    Get-Volume's Path property / volume GUID paths
    (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume),
    Win32_CDROMDrive's DeviceID/Name/Drive/MediaLoaded
    (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive),
    and IMDS's documented compute/storageProfile/resourceDisk shape
    (https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service).
    Everything else below (for example, which specific bus/port numbers or
    which exact resourceDisk.size value appear on a given VM size) is a
    per-VM observation, not a documented contract.

    Requires no parameters and no administrator privilege beyond whatever
    the local account already has to read disk/volume/CIM information.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string] $Title)
    Write-Output ''
    Write-Output "===== $Title ====="
}

Write-Output 'LIMS guest disk diagnostics -- READ-ONLY, no mutation commands, no secrets printed.'
Write-Output "Run at: $(Get-Date -Format o)"
Write-Output "Computer name: $env:COMPUTERNAME"
Write-Output "PowerShell version: $($PSVersionTable.PSVersion)"

Write-Section 'IMDS compute identity and storage profile (compute document only -- never the identity/token endpoint)'
try {
    $proxy = New-Object System.Net.WebProxy
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $webSession.Proxy = $proxy
    $imdsCompute = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get `
        -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2025-04-07&format=json' `
        -WebSession $webSession -TimeoutSec 15
    Write-Output "subscriptionId: $($imdsCompute.subscriptionId)"
    Write-Output "resourceGroupName: $($imdsCompute.resourceGroupName)"
    Write-Output "vmName: $($imdsCompute.name)"
    Write-Output "vmSize: $($imdsCompute.vmSize)"
    if ($imdsCompute.storageProfile -and $imdsCompute.storageProfile.resourceDisk) {
        Write-Output "storageProfile.resourceDisk.size (kB): $($imdsCompute.storageProfile.resourceDisk.size)"
    }
    else {
        Write-Output 'storageProfile.resourceDisk: NOT PRESENT in this IMDS response.'
    }
    if ($imdsCompute.storageProfile -and $imdsCompute.storageProfile.dataDisks) {
        foreach ($dd in @($imdsCompute.storageProfile.dataDisks)) {
            Write-Output "dataDisk: lun=$($dd.lun) name=$($dd.name) diskSizeGB=$($dd.diskSizeGB) diskCapacityBytes=$($dd.diskCapacityBytes) managedDisk.id=$($dd.managedDisk.id)"
        }
    }
}
catch {
    Write-Output "IMDS query failed: $($_.Exception.Message)"
}

Write-Section 'Get-Disk (https://learn.microsoft.com/en-us/powershell/module/storage/get-disk)'
Get-Disk | Select-Object Number, UniqueId, FriendlyName, BusType, PartitionStyle, IsBoot, IsSystem, IsOffline, IsReadOnly, OperationalStatus, Size |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'Win32_DiskDrive SCSI addressing (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive)'
Get-CimInstance -ClassName Win32_DiskDrive | Select-Object Index, DeviceID, Model, Size, SCSIBus, SCSIPort, SCSITargetId, SCSILogicalUnit |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'IMDS resourceDisk.size reconciliation (does the documented x1024 conversion actually match any guest disk here?)'
Write-Output 'This section makes the real-world IMDS resourceDisk.size discrepancy (if any) visible without manual arithmetic.'
Write-Output 'resourceDisk.size is documented in kB (https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service, "Storage Profile"); x1024 is the documented, correct kB-to-bytes conversion -- this section does NOT guess any alternate unit.'
try {
    if ($imdsCompute -and $imdsCompute.storageProfile -and $imdsCompute.storageProfile.resourceDisk -and $imdsCompute.storageProfile.resourceDisk.PSObject.Properties.Name -contains 'size') {
        $rawKb = $imdsCompute.storageProfile.resourceDisk.size
        $convertedBytes = [int64]$rawKb * 1024
        Write-Output "Raw IMDS compute.storageProfile.resourceDisk.size: $rawKb (documented unit: kB)"
        Write-Output "Documented x1024 byte conversion: $convertedBytes bytes"
        $nonOsDisksForReconciliation = @(Get-Disk | Where-Object { -not ($_.IsBoot -or $_.IsSystem) })
        if ($nonOsDisksForReconciliation.Count -eq 0) {
            Write-Output 'No non-OS Windows disks found to compare against.'
        }
        else {
            $anyExactMatch = $false
            foreach ($d in $nonOsDisksForReconciliation) {
                $diffBytes = [int64]$d.Size - $convertedBytes
                $reconciles = [math]::Abs($diffBytes) -le 67108864
                if ($reconciles) { $anyExactMatch = $true }
                Write-Output ("  Windows disk {0} (UniqueId={1}): Size={2} bytes, diff from converted resourceDisk.size={3} bytes, reconciles(<=64MiB)={4}" -f $d.Number, $d.UniqueId, $d.Size, $diffBytes, $reconciles)
            }
            if (-not $anyExactMatch) {
                Write-Output 'RESULT: the documented IMDS resourceDisk.size conversion does NOT reconcile with ANY non-OS disk currently attached to this guest. This is the exact real-world condition that causes Select-NonOsNonTemporaryDiskCandidates in Initialize-LimsGuestDataDisks.ps1 to block the whole plan for this VM today.'
            }
            else {
                Write-Output 'RESULT: at least one non-OS disk reconciles with the documented conversion (within tolerance).'
            }
        }
    }
    else {
        Write-Output 'storageProfile.resourceDisk.size was not present in the IMDS response above; no reconciliation possible.'
    }
}
catch {
    Write-Output "Reconciliation check failed: $($_.Exception.Message)"
}

Write-Section 'Get-Partition (https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition)'
Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, GptType, Size, IsOffline, IsReadOnly, @{Name = 'AccessPaths'; Expression = { $_.AccessPaths -join ' | ' } } |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'Get-Volume (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume)'
Get-Volume | Select-Object DriveLetter, FileSystem, FileSystemLabel, AllocationUnitSize, Size, Path |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'Win32_Volume (DVD-ROM-relevant subset, DriveType=5)'
Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveType -eq 5 } | Select-Object DriveLetter, DriveType, Label |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'Win32_CDROMDrive (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-cdromdrive)'
Get-CimInstance -ClassName Win32_CDROMDrive | Select-Object DeviceID, Name, Drive, MediaLoaded, SCSIBus, SCSIPort, SCSITargetId, SCSILogicalUnit |
    Format-Table -AutoSize | Out-String -Width 4096 | Write-Output

Write-Section 'Non-OS disk UniqueId + SCSI addressing (needed ONLY if deliberately enabling the proposed, disabled-by-default customer-attested-binding mode)'
Write-Output 'Initialize-LimsGuestDataDisks.ps1 defines an OPTIONAL, DISABLED-BY-DEFAULT AttestedGuestUniqueId field per approved disk descriptor in Get-ApprovedDiskPreparationAllowlist.'
Write-Output 'It is left empty ("") for every disk today -- automatic identification remains the default path. If, and only if, a human reviewer deliberately decides to enable that proposal for a'
Write-Output 'specific approved disk, the exact Get-Disk.UniqueId values below (joined with each disk''s SCSI bus/port/target/LUN, to help a reviewer tell which physical disk is which) are exactly'
Write-Output 'what would need to be copied into that disk''s AttestedGuestUniqueId allowlist field, after independently confirming (e.g. against the Azure portal/CLI disk resource) that the disk'
Write-Output 'carrying that UniqueId really is the intended managed disk. A UniqueId alone is never treated as proof of the Azure resource relationship by that logic -- it is layered on top of,'
Write-Output 'never a replacement for, the existing exact managed-disk resource ID and LUN checks.'
try {
    $nonOsDisksForAttestation = @(Get-Disk | Where-Object { -not ($_.IsBoot -or $_.IsSystem) })
    if ($nonOsDisksForAttestation.Count -eq 0) {
        Write-Output 'No non-OS Windows disks found.'
    }
    else {
        foreach ($d in $nonOsDisksForAttestation) {
            $scsi = Get-CimInstance -ClassName Win32_DiskDrive | Where-Object { $_.Index -eq $d.Number } | Select-Object -First 1
            Write-Output ("  Windows disk {0}: UniqueId={1}, Size={2} bytes, PartitionStyle={3}, SCSI bus={4}/port={5}/target={6}/LUN={7}" -f `
                    $d.Number, $d.UniqueId, $d.Size, $d.PartitionStyle, $scsi.SCSIBus, $scsi.SCSIPort, $scsi.SCSITargetId, $scsi.SCSILogicalUnit)
        }
    }
}
catch {
    Write-Output "Non-OS disk UniqueId enumeration failed: $($_.Exception.Message)"
}

Write-Output ''
Write-Output 'End of read-only diagnostics. No mutation was performed.'

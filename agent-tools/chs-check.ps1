param()

function Get-VhdChsSizeBytes {
    param([int64]$RequestedBytes)
    $totalSectors = [int64]($RequestedBytes / 512)
    $maxSectors = [int64]65535 * 16 * 255
    if ($totalSectors -gt $maxSectors) { $totalSectors = $maxSectors }

    if ($totalSectors -ge ([int64]65535 * 16 * 63)) {
        $sectorsPerTrack = 255
        $heads = 16
        $cylinderTimesHeads = [int64]($totalSectors / $sectorsPerTrack)
    }
    else {
        $sectorsPerTrack = 17
        $cylinderTimesHeads = [int64]($totalSectors / $sectorsPerTrack)
        $heads = [int64](($cylinderTimesHeads + 1023) / 1024)
        if ($heads -lt 4) { $heads = 4 }
        if ($cylinderTimesHeads -ge ($heads * 1024) -or $heads -gt 16) {
            $sectorsPerTrack = 31
            $heads = 16
            $cylinderTimesHeads = [int64]($totalSectors / $sectorsPerTrack)
        }
        if ($cylinderTimesHeads -ge ($heads * 1024)) {
            $sectorsPerTrack = 63
            $heads = 16
            $cylinderTimesHeads = [int64]($totalSectors / $sectorsPerTrack)
        }
    }
    $cylinders = [int64]($cylinderTimesHeads / $heads)
    return [int64]$cylinders * $heads * $sectorsPerTrack * 512
}

$cases = @(
    @{ Name = 'APP (128 GiB)'; NominalGiB = 128; ActualBytes = 137436250112 },
    @{ Name = 'SQL DATA (1024 GiB)'; NominalGiB = 1024; ActualBytes = 1099506078720 },
    @{ Name = 'SQL LOG (512 GiB)'; NominalGiB = 512; ActualBytes = 549753039360 }
)

foreach ($c in $cases) {
    $nominalBytes = [int64]$c.NominalGiB * 1024 * 1024 * 1024
    $chsBytes = Get-VhdChsSizeBytes -RequestedBytes $nominalBytes
    $match = ($chsBytes -eq $c.ActualBytes)
    Write-Output "$($c.Name): nominal=$nominalBytes chsComputed=$chsBytes actual=$($c.ActualBytes) diffNominal=$($nominalBytes-$c.ActualBytes) chsMatchesActual=$match"
}

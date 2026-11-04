param([Parameter(Mandatory = $true)][string[]]$Paths)

foreach ($path in $Paths) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Normalize any CRLF or lone CR to LF.
    $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $outBytes = $utf8NoBom.GetBytes($normalized)
    [System.IO.File]::WriteAllBytes($path, $outBytes)

    $crCount = ($outBytes | Where-Object { $_ -eq 13 }).Count
    Write-Host "$path -> CR bytes remaining: $crCount, size: $($outBytes.Length) bytes"
}

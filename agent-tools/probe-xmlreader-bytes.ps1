$ErrorActionPreference = 'Stop'

function Test-ParseBytes {
    param([byte[]] $Bytes, [string] $Label)
    Write-Host "=== $Label ($($Bytes.Length) bytes) ==="
    try {
        $memoryStream = [System.IO.MemoryStream]::new($Bytes)
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($memoryStream, $settings)
        $doc = [System.Xml.XmlDocument]::new()
        $doc.Load($reader)
        Write-Host "OK: root='$($doc.DocumentElement.LocalName)'"
    }
    catch {
        $e = $_.Exception
        if ($e.InnerException) { $e = $e.InnerException }
        Write-Host "THREW: $($e.GetType().FullName) :: $($e.Message)"
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($memoryStream) { $memoryStream.Dispose() }
    }
}

$xmlText = '<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs></Blobs><NextMarker></NextMarker></EnumerationResults>'
$utf8NoBomBytes = [System.Text.Encoding]::UTF8.GetBytes($xmlText)
$bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
$utf8WithBomBytes = $bomBytes + $utf8NoBomBytes

Test-ParseBytes -Bytes $utf8NoBomBytes -Label "UTF-8, no BOM"
Test-ParseBytes -Bytes $utf8WithBomBytes -Label "UTF-8, WITH BOM (the real-world mangled case)"
Test-ParseBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes('<Error><Code>ContainerNotFound</Code></Error>')) -Label "Wrong root (well-formed)"
Test-ParseBytes -Bytes ([System.Text.Encoding]::ASCII.GetBytes('not xml at all <<<')) -Label "Malformed"
Test-ParseBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes('<!DOCTYPE foo SYSTEM "http://example.com/evil.dtd"><foo/>')) -Label "DTD (must be prohibited)"
Test-ParseBytes -Bytes @() -Label "Empty"

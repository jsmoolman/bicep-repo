$ErrorActionPreference = 'Stop'
trap {
    Write-Host "TRAPPED ERROR: $_"
    Write-Host $_.ScriptStackTrace
    exit 99
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:18532/")
$listener.Start()
Write-Host "Listener started."

$serverPs = [powershell]::Create()
$null = $serverPs.AddScript({
        param($listener)
        $ctx = $listener.GetContext()
        $bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
        $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs></Blobs><NextMarker></NextMarker></EnumerationResults>')
        $bodyBytes = $bomBytes + $xmlBytes
        $ctx.Response.ContentType = 'application/xml'
        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentLength64 = $bodyBytes.Length
        $ctx.Response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $ctx.Response.OutputStream.Close()
    }).AddArgument($listener)
$asyncResult = $serverPs.BeginInvoke()

Start-Sleep -Milliseconds 300
$response = Invoke-WebRequest -Uri "http://127.0.0.1:18532/" -UseBasicParsing -Method Get

$null = $serverPs.EndInvoke($asyncResult)
$serverPs.Dispose()
$listener.Stop()

Write-Host "Response type: $($response.GetType().FullName)"
Write-Host "StatusCode type: $($response.StatusCode.GetType().FullName), value: $($response.StatusCode)"
Write-Host "Headers type: $($response.Headers.GetType().FullName)"
Write-Host "Headers['Content-Type']: $($response.Headers['Content-Type'])"
Write-Host "Headers ContainsKey method present: $([bool]($response.Headers.PSObject.Methods['ContainsKey']))"
Write-Host "Content type: $($response.Content.GetType().FullName)"
if ($response.Content -is [string]) {
    Write-Host "Content as string, first 10 chars as codepoints:"
    for ($i = 0; $i -lt [Math]::Min(10, $response.Content.Length); $i++) {
        Write-Host ("  [{0}] U+{1:X4}" -f $i, [int][char]$response.Content[$i])
    }
}
Write-Host "RawContentStream present: $([bool]$response.RawContentStream)"
if ($response.RawContentStream) {
    $rcs = $response.RawContentStream
    Write-Host "RawContentStream type: $($rcs.GetType().FullName)"
    Write-Host "RawContentStream.Length: $($rcs.Length)"
    Write-Host "RawContentStream.Position (before reset): $($rcs.Position)"
    Write-Host "RawContentStream.CanSeek: $($rcs.CanSeek)"
    $rcs.Position = 0
    $buf = New-Object byte[] $rcs.Length
    $null = $rcs.Read($buf, 0, $buf.Length)
    Write-Host "First 6 raw bytes: $(($buf[0..5] | ForEach-Object { $_.ToString('X2') }) -join ' ')"
}
Write-Host "RawContentLength present: $([bool]($response.PSObject.Properties['RawContentLength']))"
if ($response.PSObject.Properties['RawContentLength']) { Write-Host "RawContentLength: $($response.RawContentLength)" }

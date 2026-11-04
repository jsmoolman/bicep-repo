Set-Location 'C:\Source\bicep-repo\bicep-repo'
$ErrorActionPreference = 'Stop'
$projectBudget = 100000
$bicepHardLimit = 131072

$bicepFiles = @(Get-ChildItem -Path . -Recurse -Filter '*.bicep')
if ($bicepFiles.Count -eq 0) {
  Write-Host 'No .bicep files found — nothing to check.'
  exit 0
}

$failed = $false
$checked = 0
foreach ($bicepFile in $bicepFiles) {
  $bicepText = Get-Content -Raw -LiteralPath $bicepFile.FullName
  $callMatches = [regex]::Matches($bicepText, "loadTextContent\(\s*'([^']+)'")
  foreach ($m in $callMatches) {
    $relativePath = $m.Groups[1].Value
    $targetPath = Join-Path $bicepFile.DirectoryName $relativePath
    $checked++

    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
      Write-Host "FAIL: $($bicepFile.FullName) calls loadTextContent('$relativePath'), but '$targetPath' does not exist. A missing referenced file is a hard failure, never a silent pass."
      $failed = $true
      continue
    }

    try {
      $bytes = [System.IO.File]::ReadAllBytes($targetPath)
      if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
      }
      $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
      $text = $strictUtf8.GetString($bytes)
    }
    catch {
      Write-Host "FAIL: could not decode '$targetPath' as strict UTF-8: $($_.Exception.Message). A decode error is a hard failure, never a silent pass."
      $failed = $true
      continue
    }

    $normalized = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $length = $normalized.Length

    Write-Host "$($targetPath): $length characters (CRLF-normalized)"
    if ($length -gt $projectBudget) {
      Write-Host "FAIL: '$targetPath' is $length characters (CRLF-normalized), which exceeds this project's $projectBudget-character budget."
      Write-Host "The $projectBudget budget is a conservative margin below Bicep's documented $bicepHardLimit-character loadTextContent() hard limit (BCP184)."
      $failed = $true
    }
  }
}

Write-Host "Checked $checked loadTextContent() reference(s) across $($bicepFiles.Count) .bicep file(s)."
if ($failed) { Write-Host "OVERALL: FAIL"; exit 1 }
Write-Host 'All loadTextContent()-embedded scripts are within the project size budget.'
Write-Host "OVERALL: PASS"

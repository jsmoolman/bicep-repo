$compiledPath = 'C:\Source\bicep-repo\bicep-repo\agent-tools\main.compiled.json'
$scriptPath = 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'

$json = Get-Content -Raw -LiteralPath $compiledPath | ConvertFrom-Json
$actualScript = Get-Content -Raw -LiteralPath $scriptPath

# Structural approach: walk the compiled template's resources to find the Run Command script property.
function Find-ScriptProperties {
    param($Node, [string] $Path = '$')
    $found = @()
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            if ($prop.Name -eq 'script' -and $prop.Value -is [string] -and $prop.Value.Length -gt 1000) {
                $found += [pscustomobject]@{ Path = "$Path.$($prop.Name)"; Value = $prop.Value }
            }
            else {
                $found += Find-ScriptProperties -Node $prop.Value -Path "$Path.$($prop.Name)"
            }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) {
            $found += Find-ScriptProperties -Node $item -Path "$Path[$i]"
            $i++
        }
    }
    return $found
}

$matches = Find-ScriptProperties -Node $json
Write-Output ("Found {0} embedded script-like propert(y/ies) with length > 1000." -f $matches.Count)
foreach ($m in $matches) {
    Write-Output ("Path: {0}; embedded length: {1}" -f $m.Path, $m.Value.Length)
    $normalizedEmbedded = $m.Value -replace "`r`n", "`n"
    $normalizedActual = $actualScript -replace "`r`n", "`n"
    if ($normalizedEmbedded -eq $normalizedActual) {
        Write-Output "  MATCH: embedded script content is IDENTICAL (LF-normalized) to the shortened .ps1 file."
    }
    else {
        Write-Output "  MISMATCH: embedded script content differs from the .ps1 file."
        Write-Output ("  Embedded length: {0}; Actual length: {1}" -f $normalizedEmbedded.Length, $normalizedActual.Length)
    }
}

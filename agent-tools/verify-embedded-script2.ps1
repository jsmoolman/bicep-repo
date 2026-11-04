$j = Get-Content -Raw 'C:\Source\bicep-repo\bicep-repo\agent-tools\main.compiled.json' | ConvertFrom-Json
$embedded = $j.variables.guestDiskPreparationScript
Write-Output ("Embedded variable type: {0}" -f $embedded.GetType().Name)
Write-Output ("Embedded length: {0}" -f $embedded.Length)

$actualScript = Get-Content -Raw -LiteralPath 'C:\Source\bicep-repo\bicep-repo\modules\compute\lims-ws2025-dev-foundation\scripts\Initialize-LimsGuestDataDisks.ps1'
Write-Output ("Actual .ps1 length: {0}" -f $actualScript.Length)

if ($embedded -ceq $actualScript) {
    Write-Output "RESULT: embedded 'guestDiskPreparationScript' variable is BYTE-FOR-BYTE IDENTICAL to the shortened .ps1 file."
}
else {
    $normEmbedded = $embedded -replace "`r`n", "`n"
    $normActual = $actualScript -replace "`r`n", "`n"
    if ($normEmbedded -ceq $normActual) {
        Write-Output "RESULT: embedded variable IDENTICAL after line-ending normalization only (no other differences)."
    }
    else {
        Write-Output "RESULT: MISMATCH -- embedded variable differs from the .ps1 file content."
    }
}

# Also confirm each Run Command resource's source.script references this same variable (not a copy/truncation).
foreach ($r in $j.resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines/runCommands' }) {
    Write-Output ("RunCommand resource name expr: {0}" -f $r.name)
    Write-Output ("  properties.source.script expr: {0}" -f $r.properties.source.script)
}

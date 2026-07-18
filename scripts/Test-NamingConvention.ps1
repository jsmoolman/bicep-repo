<#
.SYNOPSIS
    Validates that resource names in Bicep files conform to the nfi naming convention.

.DESCRIPTION
    Parses Bicep files for resource name declarations and checks them against
    the expected pattern: <type-abbrev>-<workload>-<env>-<region>-<instance>

.PARAMETER Path
    Root path to scan for Bicep files. Defaults to the src/ directory.

.OUTPUTS
    Exits with code 1 if any naming violations are found.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = 'src'
)

$ErrorActionPreference = 'Stop'

# Pattern: <abbrev>-<workload>-<env>-<region>-<instance>
$namingPattern = '^[a-z]{2,6}-[a-z0-9]+-(dev|tst|acc|preprd|prd|mgmt)-(westeurope|northeurope|uksouth|ukwest)(-\d{2})?$'

$bicepFiles = Get-ChildItem -Path $Path -Filter '*.bicep' -Recurse
$violations = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($file in $bicepFiles) {
    $content = Get-Content $file.FullName -Raw
    $nameMatches = [regex]::Matches($content, "name\s*[:=]\s*'([^']+)'")

    foreach ($match in $nameMatches) {
        $name = $match.Groups[1].Value
        if ($name -match '-' -and $name -notmatch $namingPattern -and $name -notmatch '\$\{') {
            $violations.Add([pscustomobject]@{
                File = $file.FullName
                Name = $name
            })
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Warning "Naming convention violations found:"
    $violations | Format-Table -AutoSize
    exit 1
}

Write-Host "All resource names conform to the naming convention." -ForegroundColor Green

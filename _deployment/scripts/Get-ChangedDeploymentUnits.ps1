<#
.SYNOPSIS
    Detects which deployment units have changed in the current PR diff and outputs
    them as an Azure DevOps pipeline variable for downstream jobs.

.DESCRIPTION
    Compares changed files against the known deployment unit paths under src/ and
    config/, then emits a JSON array as the pipeline variable 'changedUnits'.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$BaseBranch = 'origin/main',

    [Parameter()]
    [string]$SourceBranch = 'HEAD'
)

$ErrorActionPreference = 'Stop'

$deploymentUnits = @(
    'platform/core',
    'platform/management',
    'platform/connectivity',
    'platform/identity',
    'platform/security',
    'landing-zones/subscription-vending',
    'landing-zones/baseline',
    'workloads/lims'
)

$changedFiles = git diff --name-only "$BaseBranch...$SourceBranch" 2>&1

$changedUnits = [System.Collections.Generic.List[string]]::new()

foreach ($unit in $deploymentUnits) {
    $unitShortName = $unit.Split('/')[-1]
    $patterns = @(
        "src/$unit/",
        "config/$unitShortName",
        'modules/'
    )

    $isChanged = $changedFiles | Where-Object {
        foreach ($pattern in $patterns) {
            if ($_ -like "*$pattern*") { return $true }
        }
        return $false
    }

    if ($isChanged) {
        $changedUnits.Add($unit)
        Write-Host "Changed: $unit"
    }
}

$json = $changedUnits | ConvertTo-Json -Compress
Write-Host "##vso[task.setvariable variable=changedUnits;isOutput=true]$json"
Write-Host "Changed deployment units: $json"

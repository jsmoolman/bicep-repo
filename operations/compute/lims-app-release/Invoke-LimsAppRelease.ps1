<#
.SYNOPSIS
    Refuses every LIMS APP release action.

.DESCRIPTION
    Pipeline entry point for APP release automation. Capture, deployment,
    configuration, and activation stay refused until release prerequisites
    and exact-target checks are implemented. This script does not call
    Azure, submit a guest command, or change a service. A snapshot-copy
    completion marker is not consulted and is not authorization.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('status', 'capture', 'deploy', 'configure', 'activate')]
    [string] $Action = 'status',

    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'tst', 'acc', 'preprd', 'prd')]
    [string] $EnvironmentName = 'dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'LimsAppRelease.Configuration.ps1')

function Invoke-LimsAppRelease {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [Parameter(Mandatory = $true)] [string] $EnvironmentName
    )

    $decision = Get-LimsAppReleaseExecutionDecision -Action $Action
    if ($decision.Allowed) {
        throw [System.InvalidOperationException]::new("LIMS APP release action '$Action' was marked allowed, but exact-target checks are not implemented. Refusing to continue.")
    }

    Write-Host "LIMS APP release action '$Action' for environment '$EnvironmentName' refused."
    Write-Host $decision.Reason
    Write-Host 'No Azure call, guest command, disk change, or service change was made.'
    Write-Host 'Snapshot-copy completion tags were not consulted.'
    return $decision
}

if ($env:LIMS_APP_RELEASE_DOT_SOURCE_ONLY -ne '1') {
    try {
        Invoke-LimsAppRelease -Action $Action -EnvironmentName $EnvironmentName | Out-Null
    }
    catch {
        Write-Error $_.Exception.Message
    }
    exit 1
}

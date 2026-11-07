<#
    Pester tests for Invoke-LimsAppRelease.ps1.

    These tests call the decision function directly. They do not call
    Azure, submit a Managed Run Command, or run the pipeline.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $env:LIMS_APP_RELEASE_DOT_SOURCE_ONLY = '1'
    . (Join-Path $PSScriptRoot 'Invoke-LimsAppRelease.ps1')
}

Describe 'Invoke-LimsAppRelease' {
    It 'refuses status, capture, deploy, configure, activate, and unknown actions' {
        foreach ($action in @('status', 'capture', 'deploy', 'configure', 'activate', 'migrate', 'stage')) {
            $decision = Invoke-LimsAppRelease -Action $action -EnvironmentName 'dev'
            $decision.Allowed | Should -Be $false
            $decision.Reason | Should -Match 'unavailable|Unsupported'
            $decision.Reason | Should -Not -Match 'limsAppMigCopyCompleted'
        }
    }

    It 'does not treat a snapshot-copy completion value as authorization' {
        $decision = Get-LimsAppReleaseExecutionDecision -Action 'configure'
        $decision.Allowed | Should -Be $false
        $decision.Reason | Should -Match 'snapshot-copy completion marker is not authorization'
        Get-Command Test-CopyCompletedForConfigure -ErrorAction SilentlyContinue | Should -Be $null
    }
}

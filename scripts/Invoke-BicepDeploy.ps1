<#
.SYNOPSIS
    Runs an Azure Bicep deployment for a given template and parameter file.

.PARAMETER TemplateFile
    Path to the Bicep template file.

.PARAMETER ParameterFile
    Path to the .bicepparam parameter file.

.PARAMETER DeploymentScope
    Deployment scope: resourceGroup, subscription, managementGroup, or tenant.

.PARAMETER Location
    Azure region for subscription/managementGroup/tenant scoped deployments.

.PARAMETER ManagementGroupId
    Management group ID (required when DeploymentScope is managementGroup).

.PARAMETER ResourceGroupName
    Resource group name (required when DeploymentScope is resourceGroup).

.PARAMETER SubscriptionId
    Subscription ID (required when DeploymentScope is resourceGroup or subscription).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TemplateFile,

    [Parameter(Mandatory)]
    [string]$ParameterFile,

    [Parameter()]
    [ValidateSet('resourceGroup', 'subscription', 'managementGroup', 'tenant')]
    [string]$DeploymentScope = 'subscription',

    [Parameter()]
    [string]$Location = 'westeurope',

    [Parameter()]
    [string]$ManagementGroupId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

$deploymentName = "deploy-$(Get-Date -Format 'yyyyMMddHHmm')"

$commonArgs = @(
    '--template-file', $TemplateFile
    '--parameters', $ParameterFile
    '--name', $deploymentName
)

if ($PSCmdlet.ShouldProcess($TemplateFile, "Deploy ($DeploymentScope)")) {
    switch ($DeploymentScope) {
        'resourceGroup' {
            az deployment group create @commonArgs `
                --resource-group $ResourceGroupName `
                --subscription $SubscriptionId
        }
        'subscription' {
            az deployment sub create @commonArgs `
                --location $Location
        }
        'managementGroup' {
            az deployment mg create @commonArgs `
                --management-group-id $ManagementGroupId `
                --location $Location
        }
        'tenant' {
            az deployment tenant create @commonArgs `
                --location $Location
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed with exit code $LASTEXITCODE"
    }
}

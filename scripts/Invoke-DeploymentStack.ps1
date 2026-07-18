<#
.SYNOPSIS
    Creates or updates an Azure Deployment Stack for a given template.

.DESCRIPTION
    Deployment Stacks provide lifecycle management for a set of Azure resources
    deployed together, enabling clean deletion of all managed resources.

.PARAMETER StackName
    Name for the deployment stack.

.PARAMETER TemplateFile
    Path to the Bicep template file.

.PARAMETER ParameterFile
    Path to the .bicepparam parameter file.

.PARAMETER DeploymentScope
    Stack scope: resourceGroup, subscription, or managementGroup.

.PARAMETER ActionOnUnmanage
    What to do with resources removed from the template: detachAll or deleteAll.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$StackName,

    [Parameter(Mandatory)]
    [string]$TemplateFile,

    [Parameter(Mandatory)]
    [string]$ParameterFile,

    [Parameter()]
    [ValidateSet('resourceGroup', 'subscription', 'managementGroup')]
    [string]$DeploymentScope = 'subscription',

    [Parameter()]
    [string]$Location = 'westeurope',

    [Parameter()]
    [ValidateSet('detachAll', 'deleteAll')]
    [string]$ActionOnUnmanage = 'detachAll',

    [Parameter()]
    [string]$ManagementGroupId,

    [Parameter()]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

$commonArgs = @(
    '--name', $StackName
    '--template-file', $TemplateFile
    '--parameters', $ParameterFile
    '--action-on-unmanage', $ActionOnUnmanage
    '--deny-settings-mode', 'none'
)

if ($PSCmdlet.ShouldProcess($StackName, "Create/Update Deployment Stack ($DeploymentScope)")) {
    switch ($DeploymentScope) {
        'resourceGroup' {
            az stack group create @commonArgs --resource-group $ResourceGroupName
        }
        'subscription' {
            az stack sub create @commonArgs --location $Location
        }
        'managementGroup' {
            az stack mg create @commonArgs --management-group-id $ManagementGroupId --location $Location
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment stack operation failed with exit code $LASTEXITCODE"
    }
}

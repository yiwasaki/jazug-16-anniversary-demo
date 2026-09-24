#Requires -Modules Az.Accounts, Az.Resources

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerName,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$PackageUploaderPrincipalId
)

$ErrorActionPreference = 'Stop'

$subscriptionId = (Get-AzContext).Subscription.Id
$containerScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/blobServices/default/containers/$ContainerName"
$rbacDeadline = (Get-Date).AddMinutes(10)

do {
    $uploaderRole = @(Get-AzRoleAssignment `
        -ObjectId $PackageUploaderPrincipalId `
        -Scope $containerScope `
        -RoleDefinitionName 'Storage Blob Data Contributor' `
        -AtScope `
        -ErrorAction SilentlyContinue)
    if ($uploaderRole.Count -gt 0) {
        break
    }
    Start-Sleep -Seconds 20
} while ((Get-Date) -lt $rbacDeadline)

if ($uploaderRole.Count -eq 0) {
    throw 'Storage Blob Data Contributorの反映を確認できませんでした。'
}

$operatorPublicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=text').Trim()

try {
    & "$PSScriptRoot/enable-package-upload-access.ps1" `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -OperatorPublicIp $operatorPublicIp

    & "$PSScriptRoot/upload-package.ps1" `
        -StorageAccountName $StorageAccountName `
        -ContainerName $ContainerName `
        -PackagePath $PackagePath
}
finally {
    & "$PSScriptRoot/disable-package-upload-access.ps1" `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -OperatorPublicIp $operatorPublicIp
}
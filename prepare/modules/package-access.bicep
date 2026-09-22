// ============================================================
// modules/package-access.bicep
// パッケージ container への RBAC 付与
// ============================================================

@description('Storage Account 名')
param storageAccountName string

@description('パッケージ格納 container 名')
param packageContainerName string

@description('パッケージをアップロードするユーザーの Microsoft Entra object ID')
param packageUploaderPrincipalId string

@description('VM system-assigned identity の principal ID')
param vmPrincipalId string

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' existing = {
  parent: blobService
  name: packageContainerName
}

resource uploaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(packageContainer.id, packageUploaderPrincipalId, storageBlobDataContributorRoleId)
  scope: packageContainer
  properties: {
    principalId: packageUploaderPrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataContributorRoleId
    )
    principalType: 'User'
  }
}

resource vmReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(packageContainer.id, vmPrincipalId, storageBlobDataReaderRoleId)
  scope: packageContainer
  properties: {
    principalId: vmPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalType: 'ServicePrincipal'
  }
}

output uploaderRoleAssignmentName string = uploaderRoleAssignment.name
output vmReaderRoleAssignmentName string = vmReaderRoleAssignment.name

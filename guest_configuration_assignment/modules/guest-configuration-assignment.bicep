// ============================================================
// modules/guest-configuration-assignment.bicep
// 既存 VM への直接 Guest Configuration Assignment
// ============================================================

targetScope = 'resourceGroup'

@description('デプロイ先リージョン')
param location string

@description('Guest Configuration を適用する VM 名')
param vmName string

@description('Guest Configuration Assignment 名')
param assignmentName string

@description('Guest Configuration package の構成名')
param configurationName string

@description('Guest Configuration package の version')
param configurationVersion string

@description('Guest Configuration Assignment の実行モード')
param assignmentType string

@description('Guest Configuration package の Blob URI')
param contentUri string

@description('Guest Configuration package の SHA-256 hash')
param contentHash string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource guestConfigurationAssignment 'Microsoft.GuestConfiguration/guestConfigurationAssignments@2024-04-05' = {
  name: assignmentName
  scope: vm
  location: location
  properties: {
    guestConfiguration: {
      name: configurationName
      version: configurationVersion
      contentUri: contentUri
      contentHash: contentHash
      assignmentType: assignmentType
      contentManagedIdentity: 'system'
    }
  }
}

output assignmentId string = guestConfigurationAssignment.id

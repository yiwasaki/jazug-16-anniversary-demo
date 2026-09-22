// ============================================================
// main.bicep
// 既存 VM へ Guest Configuration Extension と Assignment を直接デプロイする
// ============================================================

targetScope = 'resourceGroup'

@description('デプロイ先リージョン')
param location string = resourceGroup().location

@description('Guest Configuration を適用する VM 名')
param vmName string

@description('Guest Configuration Assignment 名')
param assignmentName string = 'MachineBaseline'

@description('Guest Configuration package の構成名')
param configurationName string = 'MachineBaseline'

@description('Guest Configuration package の version')
param configurationVersion string = '1.0.0'

@description('Guest Configuration Assignment の実行モード')
@allowed([
  'ApplyAndAutoCorrect'
  'ApplyAndMonitor'
  'Audit'
  'DeployAndAutoCorrect'
])
param assignmentType string = 'ApplyAndAutoCorrect'

@description('Guest Configuration package の Blob URI')
param contentUri string

@description('Guest Configuration package の SHA-256 hash')
param contentHash string

module guestConfigurationExtension './modules/guest-configuration-extension.bicep' = {
  name: 'mod-guest-configuration-extension'
  params: {
    location: location
    vmName: vmName
  }
}

module guestConfigurationAssignment './modules/guest-configuration-assignment.bicep' = {
  name: 'mod-guest-configuration-assignment'
  params: {
    location: location
    vmName: vmName
    assignmentName: assignmentName
    configurationName: configurationName
    configurationVersion: configurationVersion
    assignmentType: assignmentType
    contentUri: contentUri
    contentHash: contentHash
  }
  dependsOn: [
    guestConfigurationExtension
  ]
}

output extensionId string = guestConfigurationExtension.outputs.extensionId
output assignmentId string = guestConfigurationAssignment.outputs.assignmentId

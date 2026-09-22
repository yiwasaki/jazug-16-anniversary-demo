// ============================================================
// modules/guest-configuration-extension.bicep
// 既存 Ubuntu VM への Guest Configuration Extension
// ============================================================

targetScope = 'resourceGroup'

@description('デプロイ先リージョン')
param location string

@description('Guest Configuration Extension を追加する VM 名')
param vmName string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource guestConfigurationExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'GuestConfiguration'
  location: location
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationforLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
    protectedSettings: {}
  }
}

output extensionId string = guestConfigurationExtension.id

// ============================================================
// modules/bastion.bicep
// Bastion Developer
// ============================================================

@description('デプロイ先リージョン')
param location string

@description('リソース名プレフィックス')
param resourcePrefix string

@description('接続先 VNet のリソース ID')
param vnetId string

var bastionName = '${resourcePrefix}-bastion'

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

output bastionName string = bastion.name

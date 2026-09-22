// ============================================================
// main.bicep
// Guest Configuration 検証環境の準備用 Azure 基盤リソース
//
// 使用方法:
//   az deployment group create -g <rg> -f main.bicep \
//     -p location=<region> -p adminPassword=<pw> -p packageUploaderPrincipalId=<oid>
//
// 構成:
//   - VNet + 2 subnet + NSG + VM 用 Standard Public IP
//   - Bastion Developer SKU
//   - Storage Account + private Blob container + Private Endpoint + Private DNS
//   - Ubuntu VM + system-assigned identity
//   - パッケージ container への RBAC (uploader / VM identity)
// ============================================================

targetScope = 'resourceGroup'

@description('デプロイ先リージョン')
param location string = resourceGroup().location

@description('リソース名プレフィックス')
@maxLength(12)
param resourcePrefix string = 'gcpolicy'

@description('VM 管理者ユーザー名')
param adminUsername string = 'azureuser'

@description('VM ログイン用管理者パスワード')
@secure()
@minLength(12)
param adminPassword string

@description('VM サイズ')
@allowed([
  'Standard_B2s'
  'Standard_D2s_v5'
])
param vmSize string = 'Standard_B2s'

@description('VNet CIDR')
param vnetAddressPrefix string = '10.30.0.0/16'

@description('VM 用サブネット CIDR')
param vmSubnetPrefix string = '10.30.1.0/24'

@description('Private Endpoint 用サブネット CIDR')
param privateEndpointSubnetPrefix string = '10.30.2.0/24'

@description('Storage Account 名 (グローバル一意)。指定しない場合は uniqueString で生成する')
param storageAccountName string = ''

@description('構成パッケージ格納コンテナー名')
param packageContainerName string = 'machine-configuration'

@description('構成パッケージをアップロードするユーザーの Microsoft Entra object ID')
param packageUploaderPrincipalId string

var prefix = take(replace(toLower(resourcePrefix), '-', ''), 12)
var effectiveStorageAccountName = empty(storageAccountName)
  ? take('${prefix}pkg${uniqueString(resourceGroup().id)}', 24)
  : storageAccountName

module network './modules/network.bicep' = {
  name: 'mod-network'
  params: {
    location: location
    resourcePrefix: prefix
    vnetAddressPrefix: vnetAddressPrefix
    vmSubnetPrefix: vmSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
  }
}

module bastion './modules/bastion.bicep' = {
  name: 'mod-bastion'
  params: {
    location: location
    resourcePrefix: prefix
    vnetId: network.outputs.vnetId
  }
}

module storage './modules/storage.bicep' = {
  name: 'mod-storage'
  params: {
    location: location
    resourcePrefix: prefix
    storageAccountName: effectiveStorageAccountName
    packageContainerName: packageContainerName
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
  }
}

module vm './modules/vm.bicep' = {
  name: 'mod-vm'
  params: {
    location: location
    resourcePrefix: prefix
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    vmSubnetId: network.outputs.vmSubnetId
    publicIpId: network.outputs.publicIpId
  }
}

module packageAccess './modules/package-access.bicep' = {
  name: 'mod-package-access'
  params: {
    storageAccountName: storage.outputs.storageAccountName
    packageContainerName: storage.outputs.packageContainerName
    packageUploaderPrincipalId: packageUploaderPrincipalId
    vmPrincipalId: vm.outputs.vmPrincipalId
  }
}

output vmName string = vm.outputs.vmName
output vmId string = vm.outputs.vmId
output vmPrincipalId string = vm.outputs.vmPrincipalId
output vnetName string = network.outputs.vnetName
output bastionName string = bastion.outputs.bastionName
output storageAccountName string = storage.outputs.storageAccountName
output packageContainerName string = storage.outputs.packageContainerName
output packageBaseUri string = storage.outputs.packageBaseUri
output packageUploaderPrincipalId string = packageUploaderPrincipalId

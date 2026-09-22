// ============================================================
// modules/network.bicep
// VNet / NSG / VM 用 Public IP
// ============================================================

@description('デプロイ先リージョン')
param location string

@description('リソース名プレフィックス')
param resourcePrefix string

@description('VNet CIDR')
param vnetAddressPrefix string

@description('VM 用サブネット CIDR')
param vmSubnetPrefix string

@description('Private Endpoint 用サブネット CIDR')
param privateEndpointSubnetPrefix string

var vnetName = '${resourcePrefix}-vnet'
var vmSubnetName = 'vm-subnet'
var privateEndpointSubnetName = 'pe-subnet'
var vmNsgName = '${resourcePrefix}-vm-nsg'
var vmPublicIpName = '${resourcePrefix}-vm-pip'

resource vmNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: vmNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromAzureBastion'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyInboundFromInternet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: vmSubnetName
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: {
            id: vmNsg.id
          }
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource vmPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: vmPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output vmSubnetId string = '${vnet.id}/subnets/${vmSubnetName}'
output privateEndpointSubnetId string = '${vnet.id}/subnets/${privateEndpointSubnetName}'
output publicIpId string = vmPublicIp.id
output nsgName string = vmNsg.name

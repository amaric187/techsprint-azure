targetScope = 'resourceGroup'

param location string
param namePrefix string
param developer object
param hubVnetId string
param hubAddressSpace string
param jumpPrivateIp string
param tags object

var vnetName = 'vnet-${namePrefix}-tst-${developer.slug}'

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${namePrefix}-tst-${developer.slug}-egress'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-via-jump-nva'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: jumpPrivateIp
        }
      }
    ]
  }
}

resource appAsg 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: 'asg-${namePrefix}-tst-${developer.slug}-app'
  location: location
  tags: tags
}

resource dbAsg 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: 'asg-${namePrefix}-tst-${developer.slug}-db'
  location: location
  tags: tags
}

resource appNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-tst-${developer.slug}-app'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Hub'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: hubAddressSpace
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-HTTP-From-Hub'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: hubAddressSpace
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-LoadBalancer-Probe'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Deny-Other-VNet-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource dbNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-tst-${developer.slug}-db'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Hub'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: hubAddressSpace
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-MySQL-From-App-ASG'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceApplicationSecurityGroups: [
            {
              id: appAsg.id
            }
          ]
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [
            {
              id: dbAsg.id
            }
          ]
          destinationPortRange: '3306'
        }
      }
      {
        name: 'Deny-Other-VNet-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        developer.addressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: developer.appSubnetCidr
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: appNsg.id
          }
          routeTable: {
            id: routeTable.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
          ]
        }
      }
      {
        name: 'snet-db'
        properties: {
          addressPrefix: developer.dbSubnetCidr
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: dbNsg.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: vnet
  name: 'peer-${developer.slug}-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-app'
}

resource dbSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-db'
}

output vnetId string = vnet.id
output appSubnetId string = appSubnet.id
output dbSubnetId string = dbSubnet.id
output appAsgId string = appAsg.id
output dbAsgId string = dbAsg.id
output spokePeeringId string = spokeToHub.id

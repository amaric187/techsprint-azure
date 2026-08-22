targetScope = 'resourceGroup'

param location string
param namePrefix string
param uniqueSuffix string
param adminUsername string
param sshPublicKey string
param deploymentRunId string
param allowedSshCidr string
param spokeAddressPrefixes array
param tags object

var hubVnetName = 'vnet-${namePrefix}-tst-hub'
var jumpPrivateIp = '10.0.0.4'
var leadPrivateIp = '10.0.1.4'
var jumpVmName = 'vm-${namePrefix}-tst-jump'
var leadVmName = 'vm-${namePrefix}-tst-lead'
var jumpOsDiskName = 'disk-${namePrefix}-tst-jump-os'
var leadOsDiskName = 'disk-${namePrefix}-tst-lead-os'
var nvaScriptFirstPrefix = replace(loadTextContent('../cloud-init/jump-nva.sh'), '__SPOKE_PREFIX_1__', spokeAddressPrefixes[0])
var nvaScript = replace(nvaScriptFirstPrefix, '__SPOKE_PREFIX_2__', spokeAddressPrefixes[1])
var leadScript = loadTextContent('../cloud-init/lead.sh')

resource jumpNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-tst-jump'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Approved-Source'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSshCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-Forwarded-Lead-Traffic'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '10.0.1.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Forwarded-Developer-Internet-Egress'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefixes: spokeAddressPrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Other-Internet-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource leadNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namePrefix}-tst-lead'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Jump-Subnet'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
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

resource leadRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${namePrefix}-tst-lead-egress'
  location: location
  tags: tags
  properties: {
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

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: hubVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-jump'
        properties: {
          addressPrefix: '10.0.0.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: jumpNsg.id
          }
        }
      }
      {
        name: 'snet-lead'
        properties: {
          addressPrefix: '10.0.1.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: leadNsg.id
          }
          routeTable: {
            id: leadRouteTable.id
          }
        }
      }
    ]
  }
}

resource jumpSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: hubVnet
  name: 'snet-jump'
}

resource leadSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: hubVnet
  name: 'snet-lead'
}

resource jumpPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namePrefix}-tst-jump-${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 15
  }
}

resource jumpNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namePrefix}-tst-jump'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: jumpPrivateIp
          subnet: {
            id: jumpSubnet.id
          }
          publicIPAddress: {
            id: jumpPublicIp.id
          }
        }
      }
    ]
  }
}

resource jumpVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: jumpVmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: 'ts-jump'
      adminUsername: adminUsername
      customData: base64(nvaScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: jumpOsDiskName
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumpNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource jumpReady 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: jumpVm
  name: 'wait-for-nva'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    protectedSettings: {
      commandToExecute: 'bash -lc "cloud-init status --wait || true; if [ ! -f /var/lib/techsprint/nva-ready ] || ! grep -qx 2 /var/lib/techsprint/nva-config-version 2>/dev/null; then printf %s ${base64(nvaScript)} | base64 -d | bash; fi; test -f /var/lib/techsprint/nva-ready"'
    }
  }
}

resource leadAsg 'Microsoft.Network/applicationSecurityGroups@2024-05-01' = {
  name: 'asg-${namePrefix}-tst-lead'
  location: location
  tags: tags
}

resource leadNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namePrefix}-tst-lead'
  location: location
  tags: tags
  dependsOn: [
    jumpReady
  ]
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: leadPrivateIp
          subnet: {
            id: leadSubnet.id
          }
          applicationSecurityGroups: [
            {
              id: leadAsg.id
            }
          ]
        }
      }
    ]
  }
}

resource leadVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: leadVmName
  location: location
  tags: tags
  dependsOn: [
    jumpReady
  ]
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: 'ts-lead'
      adminUsername: adminUsername
      customData: base64(leadScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: leadOsDiskName
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: leadNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource leadReady 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: leadVm
  name: 'wait-for-bootstrap'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    protectedSettings: {
      commandToExecute: 'bash -lc "cloud-init status --wait || true; if [ ! -f /var/lib/techsprint/lead-ready ] || ! grep -qx 2 /var/lib/techsprint/lead-bootstrap-version 2>/dev/null; then printf %s ${base64(leadScript)} | base64 -d | bash; fi; test -f /var/lib/techsprint/lead-ready"'
    }
  }
}

resource jumpOsDisk 'Microsoft.Compute/disks@2024-03-02' existing = {
  name: jumpOsDiskName
}

resource leadOsDisk 'Microsoft.Compute/disks@2024-03-02' existing = {
  name: leadOsDiskName
}

resource jumpOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  scope: jumpOsDisk
  properties: {
    tags: tags
  }
  dependsOn: [
    jumpVm
  ]
}

resource leadOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  scope: leadOsDisk
  properties: {
    tags: tags
  }
  dependsOn: [
    leadVm
  ]
}

output hubVnetId string = hubVnet.id
output hubVnetName string = hubVnet.name
output hubAddressSpace string = '10.0.0.0/16'
output jumpPrivateIp string = jumpPrivateIp
output jumpPublicIp string = jumpPublicIp.properties.ipAddress
output leadPrivateIp string = leadPrivateIp
output readinessExtensionId string = leadReady.id

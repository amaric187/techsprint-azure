targetScope = 'resourceGroup'

param location string
param namePrefix string
param uniqueSuffix string
param developer object
param adminUsername string
param sshPublicKey string
param deploymentRunId string
param appSubnetId string
param dbSubnetId string
param appAsgId string
param dbAsgId string

@secure()
param dbPassword string

@secure()
param moodleAdminPassword string

param tags object

var compactSlug = take(replace(developer.slug, '-', ''), 10)
var blobStorageName = take('st${compactSlug}${uniqueSuffix}obj', 24)
var fileStorageName = take('st${compactSlug}${uniqueSuffix}file', 24)
var workloadIdentityName = 'id-${namePrefix}-tst-${developer.slug}-storage'
var internalLoadBalancerName = 'lb-${namePrefix}-tst-${developer.slug}-int'
var dbVmName = 'vm-${namePrefix}-tst-${developer.slug}-db'
var dbOsDiskName = 'disk-${namePrefix}-tst-${developer.slug}-db-os'
var dbDataDiskName = 'disk-${namePrefix}-tst-${developer.slug}-db-data'
var appVmNames = [for index in range(1, 2): 'vm-${namePrefix}-tst-${developer.slug}-app${index}']
var appOsDiskNames = [for index in range(1, 2): 'disk-${namePrefix}-tst-${developer.slug}-app${index}-os']
var appDataDiskNames = [for index in range(1, 2): 'disk-${namePrefix}-tst-${developer.slug}-app${index}-data']
var blobRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var fileMiAdminRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a235d3ee-5935-4cfb-8cc5-a3303ad5995e')

resource workloadIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: workloadIdentityName
  location: location
  tags: tags
}

resource blobStorage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: blobStorageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: tags
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: appSubnetId
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: blobStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource moodleBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
  parent: blobService
  name: 'moodlefiles'
  properties: {
    publicAccess: 'None'
  }
}

resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(moodleBlobContainer.id, workloadIdentity.id, blobRoleDefinitionId)
  scope: moodleBlobContainer
  properties: {
    roleDefinitionId: blobRoleDefinitionId
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource fileStorage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: fileStorageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: tags
  properties: {
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'None'
      defaultSharePermission: 'None'
      smbOAuthSettings: {
        isSmbOAuthEnabled: true
      }
    }
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: appSubnetId
        }
      ]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-06-01' = {
  parent: fileStorage
  name: 'default'
  properties: {}
}

resource backupShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01' = {
  parent: fileService
  name: 'moodlebackup'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 20
  }
}

resource fileRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(fileStorage.id, workloadIdentity.id, fileMiAdminRoleDefinitionId)
  scope: fileStorage
  properties: {
    roleDefinitionId: fileMiAdminRoleDefinitionId
    principalId: workloadIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource internalLoadBalancer 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: internalLoadBalancerName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend-moodle'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: developer.lbPrivateIp
          subnet: {
            id: appSubnetId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'backend-moodle'
      }
    ]
    probes: [
      {
        name: 'probe-http'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/health.html'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 15
          loadDistribution: 'Default'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', internalLoadBalancerName, 'frontend-moodle')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalancerName, 'backend-moodle')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', internalLoadBalancerName, 'probe-http')
          }
        }
      }
    ]
  }
}

resource availabilitySet 'Microsoft.Compute/availabilitySets@2024-03-01' = {
  name: 'avail-${namePrefix}-tst-${developer.slug}-app'
  location: location
  tags: tags
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

resource dbNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namePrefix}-tst-${developer.slug}-db'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: developer.dbPrivateIp
          subnet: {
            id: dbSubnetId
          }
          applicationSecurityGroups: [
            {
              id: dbAsgId
            }
          ]
        }
      }
    ]
  }
}

resource dbDataDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: dbDataDiskName
  location: location
  tags: tags
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: 32
  }
}

var dbScript = replace(
  replace(
    replace(loadTextContent('../cloud-init/db.sh'), '__DB_PASSWORD__', dbPassword),
    '__APP_SUBNET_CIDR__',
    developer.appSubnetCidr
  ),
  '__DEVELOPER_SLUG__',
  developer.slug
)

resource dbVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: dbVmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_A1_v2'
    }
    osProfile: {
      computerName: take('${developer.slug}-db', 15)
      adminUsername: adminUsername
      customData: base64(dbScript)
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
        // Standard_A1_v2 je Hyper-V Gen1 VM, zato DB mora koristiti Gen1 Ubuntu sliku.
        sku: 'server-gen1'
        version: 'latest'
      }
      osDisk: {
        name: dbOsDiskName
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: dbDataDisk.name
          createOption: 'Attach'
          deleteOption: 'Delete'
          caching: 'ReadWrite'
          managedDisk: {
            id: dbDataDisk.id
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: dbNic.id
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

resource dbReady 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: dbVm
  name: 'wait-for-database'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    protectedSettings: {
      commandToExecute: 'bash -lc "cloud-init status --wait || true; if [ ! -f /var/lib/techsprint/db-ready ] || ! grep -qx 2 /var/lib/techsprint/db-bootstrap-version 2>/dev/null; then printf %s ${base64(dbScript)} | base64 -d | bash; fi; test -f /var/lib/techsprint/db-ready"'
    }
  }
}

resource appDataDisks 'Microsoft.Compute/disks@2024-03-02' = [for (diskName, index) in appDataDiskNames: {
  name: diskName
  location: location
  tags: tags
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: 32
  }
}]

resource appNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for (privateIp, index) in developer.appPrivateIps: {
  name: 'nic-${namePrefix}-tst-${developer.slug}-app${index + 1}'
  location: location
  tags: tags
  dependsOn: [
    internalLoadBalancer
  ]
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
          subnet: {
            id: appSubnetId
          }
          applicationSecurityGroups: [
            {
              id: appAsgId
            }
          ]
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalancerName, 'backend-moodle')
            }
          ]
        }
      }
    ]
  }
}]

var appScriptTemplate = loadTextContent('../cloud-init/app.sh')
var appScriptDeveloper = replace(appScriptTemplate, '__DEVELOPER_SLUG__', developer.slug)
var appScriptWwwRoot = replace(appScriptDeveloper, '__MOODLE_WWWROOT__', 'http://${developer.moodleHostname}:${developer.localPort}')
var appScriptDbIp = replace(appScriptWwwRoot, '__DB_PRIVATE_IP__', developer.dbPrivateIp)
var appScriptDbPassword = replace(appScriptDbIp, '__DB_PASSWORD__', dbPassword)
var appScriptAdminPassword = replace(appScriptDbPassword, '__MOODLE_ADMIN_PASSWORD__', moodleAdminPassword)
var appScriptLbIp = replace(appScriptAdminPassword, '__LB_PRIVATE_IP__', developer.lbPrivateIp)
var appScriptBlob = replace(appScriptLbIp, '__BLOB_STORAGE_NAME__', blobStorageName)
var appScriptEnvironment = replace(appScriptBlob, '__FILE_STORAGE_NAME__', fileStorageName)
var appScripts = [for (privateIp, index) in developer.appPrivateIps: replace(appScriptEnvironment, '__APP_INDEX__', string(index))]
var appLauncherTemplate = loadTextContent('../cloud-init/app-launcher.sh')

resource appVms 'Microsoft.Compute/virtualMachines@2024-11-01' = [for (vmName, index) in appVmNames: {
  name: vmName
  location: location
  tags: tags
  dependsOn: [
    dbReady
    blobRoleAssignment
    fileRoleAssignment
    backupShare
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${workloadIdentity.id}': {}
    }
  }
  properties: {
    availabilitySet: {
      id: availabilitySet.id
    }
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: take('${developer.slug}-app${index + 1}', 15)
      adminUsername: adminUsername
      // Cloud-init samo pokrece pozadinski worker i odmah zavrsava. Dugi Moodle
      // bootstrap zato ne blokira provisioning VM-a niti Azure ekstenziju.
      // Managed Identity clientId je runtime vrijednost pa se zamjena radi
      // izravno u tijelu resursa, a ne unutar Bicep for-varijable.
      customData: base64(replace(
        appLauncherTemplate,
        '__APP_SCRIPT_B64__',
        base64(replace(appScripts[index], '__MANAGED_IDENTITY_CLIENT_ID__', workloadIdentity.properties.clientId))
      ))
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
        name: appOsDiskNames[index]
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: appDataDisks[index].name
          createOption: 'Attach'
          deleteOption: 'Delete'
          caching: 'ReadWrite'
          managedDisk: {
            id: appDataDisks[index].id
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: appNics[index].id
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
}]

// Ekstenzija samo pokrece pozadinski fallback worker i odmah zavrsava.
// Dugi Moodle bootstrap prati deploy.ps1, cime se izbjegava fiksni 90-minutni
// timeout Azure Custom Script ekstenzije.
resource appBootstrapLauncher 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [for (vmName, index) in appVmNames: {
  parent: appVms[index]
  name: 'launch-moodle-bootstrap'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deploymentRunId
    protectedSettings: {
      commandToExecute: 'printf %s ${base64(replace(appLauncherTemplate, '__APP_SCRIPT_B64__', base64(replace(appScripts[index], '__MANAGED_IDENTITY_CLIENT_ID__', workloadIdentity.properties.clientId))))} | base64 -d | bash'
    }
  }
}]

resource dbOsDisk 'Microsoft.Compute/disks@2024-03-02' existing = {
  name: dbOsDiskName
}

resource appOsDisks 'Microsoft.Compute/disks@2024-03-02' existing = [for diskName in appOsDiskNames: {
  name: diskName
}]

resource dbOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  scope: dbOsDisk
  properties: {
    tags: tags
  }
  dependsOn: [
    dbVm
  ]
}

resource appOsDiskTags 'Microsoft.Resources/tags@2021-04-01' = [for (diskName, index) in appOsDiskNames: {
  name: 'default'
  scope: appOsDisks[index]
  properties: {
    tags: tags
  }
  dependsOn: [
    appVms[index]
  ]
}]

output internalLoadBalancerIp string = developer.lbPrivateIp
output appPrivateIps array = developer.appPrivateIps
output dbPrivateIp string = developer.dbPrivateIp
output blobStorageAccountName string = blobStorage.name
output fileStorageAccountName string = fileStorage.name
output workloadIdentityClientId string = workloadIdentity.properties.clientId
output appVmNames array = appVmNames
output bootstrapLauncherIds array = [for (vmName, index) in appVmNames: appBootstrapLauncher[index].id]

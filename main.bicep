targetScope = 'subscription'

@description('Azure regija za shared hub resurse.')
param location string = 'switzerlandnorth'

@description('Kratki prefiks projekta koji ulazi u nazive resursa.')
param namePrefix string = 'techsprint'

@description('Kratki globalno jedinstveni sufiks (mala slova i brojevi).')
@minLength(4)
@maxLength(6)
param uniqueSuffix string

@description('Administratorsko korisnicko ime unutar Linux VM-ova.')
param adminUsername string = 'azureadmin'

@description('SSH javni kljuc koji se postavlja na sve VM-ove.')
param sshPublicKey string

@description('Jedinstvena oznaka pokretanja koja prisiljava ponovnu readiness provjeru VM ekstenzija.')
param deploymentRunId string

@description('Javna IPv4 adresa/range s koje je dopusten SSH prema Jump Hostu.')
param allowedSshCidr string

@description('Objekt postojeceg DevOps Lead korisnika s Microsoft Entra objectId vrijednosti.')
param lead object

@description('Developer objekti generirani iz CSV datoteke.')
param developers array

@secure()
@description('Lozinke za bazu i Moodle administratora po developer slugu.')
param environmentSecrets object

@description('Obavezni tagovi projekta.')
param tags object = {
  project: 'techsprint'
  environment: 'testing'
}

var regionCode = location == 'westeurope' ? 'weu' : take(toLower(replace(location, ' ', '')), 3)
var hubResourceGroupName = 'rg-${namePrefix}-tst-shared-${regionCode}'
var developerResourceGroupNames = [for developer in developers: 'rg-${namePrefix}-tst-${developer.environmentCode}-${regionCode}']
var powerRoleGuid = guid(subscription().id, '${namePrefix}-vm-power-operator')
var powerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerRoleGuid)

resource hubResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hubResourceGroupName
  location: location
  tags: union(tags, {
    role: 'shared'
  })
}

resource developerResourceGroups 'Microsoft.Resources/resourceGroups@2024-03-01' = [for (developer, index) in developers: {
  name: developerResourceGroupNames[index]
  location: location
  tags: union(tags, {
    owner: developer.slug
    role: 'developer-environment'
  })
}]

resource vmPowerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: powerRoleGuid
  properties: {
    roleName: 'TechSprint VM Power Operator'
    description: 'Minimalna prava za pregled i start, deallocate, power off i restart virtualnih masina.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/instanceView/read'
          'Microsoft.Compute/virtualMachines/start/action'
          'Microsoft.Compute/virtualMachines/deallocate/action'
          'Microsoft.Compute/virtualMachines/powerOff/action'
          'Microsoft.Compute/virtualMachines/restart/action'
          'Microsoft.Compute/disks/read'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Resources/subscriptions/resourceGroups/resources/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

module hub 'modules/hub.bicep' = {
  name: 'deploy-shared-hub'
  scope: hubResourceGroup
  params: {
    location: location
    namePrefix: namePrefix
    uniqueSuffix: uniqueSuffix
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    deploymentRunId: deploymentRunId
    allowedSshCidr: allowedSshCidr
    spokeAddressPrefixes: [
      '10.16.0.0/12'
      '10.32.0.0/12'
    ]
    tags: union(tags, {
      role: 'shared'
    })
  }
}

module developerNetworks 'modules/developer-network.bicep' = [for (developer, index) in developers: {
  name: 'network-${developer.slug}'
  scope: developerResourceGroups[index]
  params: {
    location: developer.location
    namePrefix: namePrefix
    developer: developer
    hubVnetId: hub.outputs.hubVnetId
    hubAddressSpace: hub.outputs.hubAddressSpace
    jumpPrivateIp: hub.outputs.jumpPrivateIp
    tags: union(tags, {
      owner: developer.slug
      role: 'developer-environment'
    })
  }
}]

module hubPeerings 'modules/hub-peering.bicep' = [for (developer, index) in developers: {
  name: 'hub-peering-${developer.slug}'
  scope: hubResourceGroup
  params: {
    hubVnetName: hub.outputs.hubVnetName
    spokeName: developer.slug
    spokeVnetId: developerNetworks[index].outputs.vnetId
  }
}]

module developerWorkloads 'modules/developer-workload.bicep' = [for (developer, index) in developers: {
  name: 'workload-${developer.slug}'
  scope: developerResourceGroups[index]
  dependsOn: [
    hubPeerings[index]
  ]
  params: {
    location: developer.location
    namePrefix: namePrefix
    uniqueSuffix: uniqueSuffix
    developer: developer
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    deploymentRunId: deploymentRunId
    appSubnetId: developerNetworks[index].outputs.appSubnetId
    dbSubnetId: developerNetworks[index].outputs.dbSubnetId
    appAsgId: developerNetworks[index].outputs.appAsgId
    dbAsgId: developerNetworks[index].outputs.dbAsgId
    dbPassword: environmentSecrets[developer.slug].dbPassword
    moodleAdminPassword: environmentSecrets[developer.slug].moodleAdminPassword
    tags: union(tags, {
      owner: developer.slug
      role: 'developer-environment'
    })
  }
}]

module developerPowerAssignments 'modules/resource-group-rbac.bicep' = [for (developer, index) in developers: {
  name: 'rbac-developer-${developer.slug}'
  scope: developerResourceGroups[index]
  params: {
    roleDefinitionId: powerRoleId
    principalId: developer.objectId
    principalType: 'User'
  }
  dependsOn: [
    vmPowerRole
  ]
}]

module leadPowerOnDeveloperGroups 'modules/resource-group-rbac.bicep' = [for (developer, index) in developers: {
  name: 'rbac-lead-${developer.slug}'
  scope: developerResourceGroups[index]
  params: {
    roleDefinitionId: powerRoleId
    principalId: lead.objectId
    principalType: 'User'
  }
  dependsOn: [
    vmPowerRole
  ]
}]

module leadPowerOnHub 'modules/resource-group-rbac.bicep' = {
  name: 'rbac-lead-shared'
  scope: hubResourceGroup
  params: {
    roleDefinitionId: powerRoleId
    principalId: lead.objectId
    principalType: 'User'
  }
  dependsOn: [
    vmPowerRole
  ]
}

output environments array = [for (developer, index) in developers: {
  developer: developer.displayName
  slug: developer.slug
  location: developer.location
  principalObjectId: developer.objectId
  resourceGroup: developerResourceGroupNames[index]
  internalLoadBalancerIp: developer.lbPrivateIp
  moodleTunnel: 'ssh -N -L ${developer.localPort}:${developer.lbPrivateIp}:80 ${adminUsername}@${hub.outputs.jumpPublicIp}'
  localMoodleUrl: 'http://${developer.moodleHostname}:${developer.localPort}'
  appPrivateIps: developer.appPrivateIps
  appVmNames: developerWorkloads[index].outputs.appVmNames
  dbPrivateIp: developer.dbPrivateIp
}]

output deploymentSummary object = {
  jumpPublicIp: hub.outputs.jumpPublicIp
  jumpPrivateIp: hub.outputs.jumpPrivateIp
  leadPrivateIp: hub.outputs.leadPrivateIp
  leadObjectId: lead.objectId
  sshToJump: 'ssh ${adminUsername}@${hub.outputs.jumpPublicIp}'
  sshToLead: 'ssh -A -J ${adminUsername}@${hub.outputs.jumpPublicIp} ${adminUsername}@${hub.outputs.leadPrivateIp}'
}

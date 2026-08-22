targetScope = 'resourceGroup'

param roleDefinitionId string
param principalId string

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, roleDefinitionId, principalId)
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}

output assignmentId string = assignment.id

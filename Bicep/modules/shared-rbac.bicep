// DNS and storage data-plane roles for the watchdog. Mirrors terraform/rbac.tf.
targetScope = 'resourceGroup'

param principalId string
param storageAccountName string
param privateDnsZoneName string

var blobOwner = '/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '/providers/Microsoft.Authorization/roleDefinitions/974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableContributor = '/providers/Microsoft.Authorization/roleDefinitions/0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var dnsContributor = '/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDnsZoneName
}

resource blobOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, principalId, blobOwner)
  scope: storage
  properties: {
    roleDefinitionId: blobOwner
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, principalId, queueContributor)
  scope: storage
  properties: {
    roleDefinitionId: queueContributor
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource tableContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, principalId, tableContributor)
  scope: storage
  properties: {
    roleDefinitionId: tableContributor
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource dnsContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(zone.id, principalId, dnsContributor)
  scope: zone
  properties: {
    roleDefinitionId: dnsContributor
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

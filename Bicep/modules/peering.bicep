// One direction of VNet peering. Mirrors azurerm_virtual_network_peering in terraform/main.tf.
targetScope = 'resourceGroup'

param peeringName string
param localVnetName string
param remoteVnetId string

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  name: '${localVnetName}/${peeringName}'
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

output peeringName string = peeringName

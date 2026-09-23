// Optional test-client subnet on the primary VNet. Mirrors azurerm_subnet.client in terraform/main.tf.
targetScope = 'resourceGroup'

param vnetName string
param subnetName string = 'snet-client'
param addressPrefix string

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: '${vnetName}/${subnetName}'
  properties: {
    addressPrefix: addressPrefix
  }
}

output subnetId string = subnet.id

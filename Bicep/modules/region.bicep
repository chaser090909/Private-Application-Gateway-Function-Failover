// Regional stack. Mirrors terraform/modules/region.
targetScope = 'resourceGroup'

@description('Azure region for this stack. Terraform: location.')
param location string

@description('Tags applied to every resource in this region. Terraform: tags.')
param tags object

@description('Name of the regional virtual network. Terraform: vnet_name.')
param vnetName string

@description('Address space of the regional virtual network. Terraform: vnet_address_space.')
param vnetAddressSpace array

@description('Name of the Application Gateway subnet. Terraform: appgw_subnet_name.')
param appgwSubnetName string

@description('CIDR of the Application Gateway subnet. Terraform: appgw_subnet_prefix.')
param appgwSubnetPrefix string

@description('Name of the Container Instances subnet. Terraform: aci_subnet_name.')
param aciSubnetName string

@description('CIDR of the Container Instances subnet. Terraform: aci_subnet_prefix.')
param aciSubnetPrefix string

@description('Name of the NAT gateway. Terraform: nat_gateway_name.')
param natGatewayName string

@description('Name of the NAT gateway public IP. Terraform: nat_public_ip_name.')
param natPublicIpName string

@description('Name of the backend container group. Terraform: container_group_name.')
param containerGroupName string

@description('Backend container image. Terraform: container_image.')
param containerImage string

@description('Port the backend container listens on. Terraform: container_port.')
param containerPort int

@description('vCPU allocated to the backend container. Terraform: container_cpu.')
param containerCpu int

@description('Memory in GB allocated to the backend container. Terraform: container_memory_in_gb.')
param containerMemoryInGb int

@description('Name of the Application Gateway. Terraform: appgw_name.')
param appgwName string

@description('Static private frontend IP. Terraform: appgw_private_ip.')
param appgwPrivateIp string

@description('Fixed instance count. Terraform: appgw_capacity.')
param appgwCapacity int

@description('Path the custom probe requests. Terraform: health_probe_path.')
param healthProbePath string

@description('Shared workspace that receives this gateway metrics and access logs. Terraform: log_analytics_workspace_id.')
param logAnalyticsWorkspaceId string

var frontendIpName = 'feip-private'
var frontendPortName = 'feport-http'
var gatewayIpName = 'gwip'
var backendPoolName = 'bepool-aci'
var httpSettingName = 'behttp-80'
var listenerName = 'listener-http'
var probeName = 'probe-aci'
var ruleName = 'rule-http'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: vnetAddressSpace
    }
  }
}

resource natPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: natPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
  }
}

// Delegation is what allows a private-only gateway with no public IP.
resource appgwSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: appgwSubnetName
  properties: {
    addressPrefix: appgwSubnetPrefix
    delegations: [
      {
        name: 'appgw-network-isolation'
        properties: {
          serviceName: 'Microsoft.Network/applicationGateways'
        }
      }
    ]
  }
}

// A private container group has no outbound path of its own. NAT is the image pull path.
resource aciSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: aciSubnetName
  properties: {
    addressPrefix: aciSubnetPrefix
    natGateway: {
      id: nat.id
    }
    delegations: [
      {
        name: 'aci'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
}

resource aci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Private'
      ports: [
        {
          protocol: 'TCP'
          port: containerPort
        }
      ]
    }
    subnetIds: [
      {
        id: aciSubnet.id
      }
    ]
    containers: [
      {
        name: 'app'
        properties: {
          image: containerImage
          resources: {
            requests: {
              cpu: containerCpu
              memoryInGB: containerMemoryInGb
            }
          }
          ports: [
            {
              port: containerPort
              protocol: 'TCP'
            }
          ]
        }
      }
    ]
  }
}

resource appgw 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appgwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: appgwCapacity
    }
    gatewayIPConfigurations: [
      {
        name: gatewayIpName
        properties: {
          subnet: {
            id: appgwSubnet.id
          }
        }
      }
    ]
    // Private frontend only. No public IP. Requires EnableApplicationGatewayNetworkIsolation.
    frontendIPConfigurations: [
      {
        name: frontendIpName
        properties: {
          privateIPAddress: appgwPrivateIp
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: appgwSubnet.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: frontendPortName
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
        properties: {
          backendAddresses: [
            {
              ipAddress: aci.properties.ipAddress.ip
            }
          ]
        }
      }
    ]
    // Bare IPs in the pool, so the probe sends an explicit host header.
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: healthProbePath
          port: containerPort
          interval: 15
          timeout: 10
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: httpSettingName
        properties: {
          port: containerPort
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appgwName, probeName)
          }
        }
      }
    ]
    httpListeners: [
      {
        name: listenerName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appgwName, frontendIpName)
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appgwName, frontendPortName)
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: ruleName
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appgwName, listenerName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appgwName, backendPoolName)
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appgwName, httpSettingName)
          }
        }
      }
    ]
  }
}

resource appgwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: appgw
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output appgwName string = appgw.name
output appgwId string = appgw.id
output appgwPrivateIp string = appgwPrivateIp
output containerGroupName string = aci.name
output containerPrivateIp string = aci.properties.ipAddress.ip

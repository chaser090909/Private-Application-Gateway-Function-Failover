// Private Application Gateway DR.
// Bicep port of terraform/. Parameter names follow terraform/variables.tf.
// Deployed values live in main.bicepparam and follow terraform/terraform.tfvars.
//
// Function code is published after this deployment, from terraform/function:
//   az functionapp deployment source config-zip --build-remote true
// See the watchdog output for the resource group and app name.
targetScope = 'subscription'

@description('Terraform: primary_resource_group_name')
param primaryResourceGroupName string

@description('Terraform: secondary_resource_group_name')
param secondaryResourceGroupName string

@description('Terraform: shared_resource_group_name')
param sharedResourceGroupName string

@description('Terraform: primary_location')
param primaryLocation string

@description('Terraform: secondary_location')
param secondaryLocation string

@description('Terraform: shared_location. Empty uses primaryLocation.')
param sharedLocation string = ''

@description('Terraform: tags')
param tags object

@description('Terraform: primary_vnet_address_space')
param primaryVnetAddressSpace array

@description('Terraform: secondary_vnet_address_space')
param secondaryVnetAddressSpace array

@description('Terraform: primary_appgw_subnet_prefix')
param primaryAppgwSubnetPrefix string

@description('Terraform: secondary_appgw_subnet_prefix')
param secondaryAppgwSubnetPrefix string

@description('Terraform: primary_aci_subnet_prefix')
param primaryAciSubnetPrefix string

@description('Terraform: secondary_aci_subnet_prefix')
param secondaryAciSubnetPrefix string

@description('Terraform: client_subnet_prefix')
param clientSubnetPrefix string

@description('Terraform: primary_appgw_private_ip')
param primaryAppgwPrivateIp string

@description('Terraform: secondary_appgw_private_ip')
param secondaryAppgwPrivateIp string

@description('Terraform: container_image')
param containerImage string

@description('Terraform: container_port')
param containerPort int

@description('Terraform: container_cpu')
param containerCpu int

@description('Terraform: container_memory_in_gb')
param containerMemoryInGb int

@description('Terraform: appgw_capacity')
param appgwCapacity int

@description('Terraform: health_probe_path')
param healthProbePath string

@description('Terraform: private_dns_zone_name')
param privateDnsZoneName string

@description('Terraform: dns_record_name')
param dnsRecordName string

@description('Terraform: dns_record_ttl')
param dnsRecordTtl int

@description('Creates the A record on the first deployment. Set false before a later deployment so a failover is not reset to the primary IP. Terraform uses ignore_changes on the record.')
param seedDnsRecord bool = true

@description('Terraform: app_service_plan_sku')
param appServicePlanSku string

@description('Terraform: python_version')
param pythonVersion string

@description('Terraform: watchdog_schedule')
param watchdogSchedule string

@description('Terraform: backend_healthy_states')
param backendHealthyStates array

@description('Terraform: log_retention_in_days')
param logRetentionInDays int

@description('Terraform: alert_email_address')
param alertEmailAddress string

@description('Terraform: unhealthy_host_threshold')
param unhealthyHostThreshold int

@description('Terraform: deploy_test_vm')
param deployTestVm bool

@description('Terraform: test_vm_size')
param testVmSize string = 'Standard_B2s_v2'

@description('Terraform: test_vm_admin_username')
param testVmAdminUsername string = 'azureuser'

@description('Terraform: test_vm_ssh_public_key')
param testVmSshPublicKey string = ''

var sharedLocationValue = empty(sharedLocation) ? primaryLocation : sharedLocation
var suffix = substring(uniqueString(subscription().id, primaryResourceGroupName, secondaryResourceGroupName, sharedResourceGroupName), 0, 8)
var roleDefinitionGuid = guid(subscription().id, 'Private AppGW DR Watchdog', suffix)

resource primaryRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: primaryResourceGroupName
  location: primaryLocation
  tags: tags
}

resource secondaryRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: secondaryResourceGroupName
  location: secondaryLocation
  tags: tags
}

resource sharedRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: sharedResourceGroupName
  location: sharedLocationValue
  tags: tags
}

resource watchdogRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefinitionGuid
  properties: {
    roleName: 'Private AppGW DR Watchdog (${suffix})'
    description: 'Read container group state, Application Gateway backend health, and gateway probe metrics. Grants no write access.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.ContainerInstance/containerGroups/read'
          'Microsoft.Network/applicationGateways/read'
          'Microsoft.Network/applicationGateways/backendhealth/action'
          'Microsoft.Insights/metrics/read'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

module workspace 'modules/workspace.bicep' = {
  name: 'workspace'
  scope: sharedRg
  params: {
    location: sharedLocationValue
    tags: tags
    suffix: suffix
    logRetentionInDays: logRetentionInDays
  }
}

module primary 'modules/region.bicep' = {
  name: 'primary'
  scope: primaryRg
  params: {
    location: primaryLocation
    tags: tags
    vnetName: 'vnet-eus-dr'
    vnetAddressSpace: primaryVnetAddressSpace
    appgwSubnetName: 'snet-appgw-eus'
    appgwSubnetPrefix: primaryAppgwSubnetPrefix
    aciSubnetName: 'snet-aci-eus'
    aciSubnetPrefix: primaryAciSubnetPrefix
    natGatewayName: 'nat-aci-eus'
    natPublicIpName: 'pip-nat-eus'
    containerGroupName: 'aci-eus-dr'
    containerImage: containerImage
    containerPort: containerPort
    containerCpu: containerCpu
    containerMemoryInGb: containerMemoryInGb
    appgwName: 'agw-eus-dr'
    appgwPrivateIp: primaryAppgwPrivateIp
    appgwCapacity: appgwCapacity
    healthProbePath: healthProbePath
    logAnalyticsWorkspaceId: workspace.outputs.workspaceId
  }
}

module secondary 'modules/region.bicep' = {
  name: 'secondary'
  scope: secondaryRg
  params: {
    location: secondaryLocation
    tags: tags
    vnetName: 'vnet-cus-dr'
    vnetAddressSpace: secondaryVnetAddressSpace
    appgwSubnetName: 'snet-appgw-cus'
    appgwSubnetPrefix: secondaryAppgwSubnetPrefix
    aciSubnetName: 'snet-aci-cus'
    aciSubnetPrefix: secondaryAciSubnetPrefix
    natGatewayName: 'nat-aci-cus'
    natPublicIpName: 'pip-nat-cus'
    containerGroupName: 'aci-cus-dr'
    containerImage: containerImage
    containerPort: containerPort
    containerCpu: containerCpu
    containerMemoryInGb: containerMemoryInGb
    appgwName: 'agw-cus-dr'
    appgwPrivateIp: secondaryAppgwPrivateIp
    appgwCapacity: appgwCapacity
    healthProbePath: healthProbePath
    logAnalyticsWorkspaceId: workspace.outputs.workspaceId
  }
}

module peerPrimary 'modules/peering.bicep' = {
  name: 'peer-eus-to-cus'
  scope: primaryRg
  params: {
    peeringName: 'peer-eus-to-cus'
    localVnetName: primary.outputs.vnetName
    remoteVnetId: secondary.outputs.vnetId
  }
}

module peerSecondary 'modules/peering.bicep' = {
  name: 'peer-cus-to-eus'
  scope: secondaryRg
  params: {
    peeringName: 'peer-cus-to-eus'
    localVnetName: secondary.outputs.vnetName
    remoteVnetId: primary.outputs.vnetId
  }
}

module clientSubnet 'modules/client-subnet.bicep' = {
  name: 'client-subnet'
  scope: primaryRg
  params: {
    vnetName: primary.outputs.vnetName
    addressPrefix: clientSubnetPrefix
  }
}

module dns 'modules/dns.bicep' = {
  name: 'dns'
  scope: sharedRg
  params: {
    tags: tags
    privateDnsZoneName: privateDnsZoneName
    dnsRecordName: dnsRecordName
    dnsRecordTtl: dnsRecordTtl
    primaryVnetId: primary.outputs.vnetId
    secondaryVnetId: secondary.outputs.vnetId
    primaryAppgwPrivateIp: primary.outputs.appgwPrivateIp
    seedDnsRecord: seedDnsRecord
  }
}

module watchdog 'modules/function.bicep' = {
  name: 'watchdog'
  scope: sharedRg
  params: {
    location: sharedLocationValue
    tags: tags
    suffix: suffix
    appServicePlanSku: appServicePlanSku
    pythonVersion: pythonVersion
    watchdogSchedule: watchdogSchedule
    sharedResourceGroupName: sharedResourceGroupName
    privateDnsZoneName: dns.outputs.zoneName
    dnsRecordName: dnsRecordName
    dnsRecordTtl: dnsRecordTtl
    primaryResourceGroupName: primaryResourceGroupName
    primaryContainerGroupName: primary.outputs.containerGroupName
    primaryAppgwName: primary.outputs.appgwName
    primaryAppgwPrivateIp: primary.outputs.appgwPrivateIp
    secondaryResourceGroupName: secondaryResourceGroupName
    secondaryContainerGroupName: secondary.outputs.containerGroupName
    secondaryAppgwName: secondary.outputs.appgwName
    secondaryAppgwPrivateIp: secondary.outputs.appgwPrivateIp
    backendHealthyStates: backendHealthyStates
    appInsightsConnectionString: workspace.outputs.connectionString
    appInsightsInstrumentationKey: workspace.outputs.instrumentationKey
  }
}

module rbacPrimary 'modules/regional-rbac.bicep' = {
  name: 'rbac-primary'
  scope: primaryRg
  params: {
    principalId: watchdog.outputs.principalId
    roleDefinitionId: watchdogRole.id
  }
}

module rbacSecondary 'modules/regional-rbac.bicep' = {
  name: 'rbac-secondary'
  scope: secondaryRg
  params: {
    principalId: watchdog.outputs.principalId
    roleDefinitionId: watchdogRole.id
  }
}

module rbacShared 'modules/shared-rbac.bicep' = {
  name: 'rbac-shared'
  scope: sharedRg
  params: {
    principalId: watchdog.outputs.principalId
    storageAccountName: watchdog.outputs.storageAccountName
    privateDnsZoneName: dns.outputs.zoneName
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: sharedRg
  params: {
    location: sharedLocationValue
    tags: tags
    alertEmailAddress: alertEmailAddress
    failoverWebhookUri: 'https://${watchdog.outputs.defaultHostName}/api/region-failover?code=${watchdog.outputs.hostKey}'
    unhealthyHostThreshold: unhealthyHostThreshold
    primaryAppgwId: primary.outputs.appgwId
    primaryAppgwName: primary.outputs.appgwName
    primaryLocation: primaryLocation
    secondaryAppgwId: secondary.outputs.appgwId
    secondaryAppgwName: secondary.outputs.appgwName
    secondaryLocation: secondaryLocation
    primaryResourceGroupId: primaryRg.id
    logAnalyticsWorkspaceId: workspace.outputs.workspaceId
    dnsRecordName: dnsRecordName
    privateDnsZoneName: privateDnsZoneName
    healthProbePath: healthProbePath
    primaryAppgwPrivateIp: primary.outputs.appgwPrivateIp
    secondaryAppgwPrivateIp: secondary.outputs.appgwPrivateIp
  }
}

module portalDashboard 'modules/dashboard.bicep' = {
  name: 'portal-dashboard'
  scope: sharedRg
  params: {
    location: sharedLocationValue
    tags: tags
    suffix: suffix
    workspaceId: workspace.outputs.workspaceId
    appInsightsId: workspace.outputs.appInsightsId
    appInsightsName: workspace.outputs.appInsightsName
    primaryAppgwId: primary.outputs.appgwId
    primaryAppgwName: primary.outputs.appgwName
    primaryLocation: primaryLocation
    primaryAppgwPrivateIp: primary.outputs.appgwPrivateIp
    secondaryAppgwId: secondary.outputs.appgwId
    secondaryAppgwName: secondary.outputs.appgwName
    secondaryLocation: secondaryLocation
    secondaryAppgwPrivateIp: secondary.outputs.appgwPrivateIp
    dnsRecordName: dnsRecordName
    privateDnsZoneName: privateDnsZoneName
    healthProbePath: healthProbePath
    alertEmailAddress: alertEmailAddress
  }
}

module testVm 'modules/test-vm.bicep' = if (deployTestVm) {
  name: 'test-vm'
  scope: primaryRg
  params: {
    location: primaryLocation
    tags: tags
    subnetId: clientSubnet.outputs.subnetId
    vmSize: testVmSize
    adminUsername: testVmAdminUsername
    sshPublicKey: testVmSshPublicKey
  }
}

output resourceGroups object = {
  primary: primaryRg.name
  secondary: secondaryRg.name
  shared: sharedRg.name
}

output primaryAppgw object = {
  resourceGroup: primaryRg.name
  name: primary.outputs.appgwName
  privateIp: primary.outputs.appgwPrivateIp
  backendAciIp: primary.outputs.containerPrivateIp
  backendAciName: primary.outputs.containerGroupName
}

output secondaryAppgw object = {
  resourceGroup: secondaryRg.name
  name: secondary.outputs.appgwName
  privateIp: secondary.outputs.appgwPrivateIp
  backendAciIp: secondary.outputs.containerPrivateIp
  backendAciName: secondary.outputs.containerGroupName
}

output applicationFqdn string = '${dnsRecordName}.${privateDnsZoneName}'

output watchdog object = {
  name: watchdog.outputs.name
  hostname: watchdog.outputs.defaultHostName
  planSku: appServicePlanSku
  principalId: watchdog.outputs.principalId
  schedule: watchdogSchedule
  codePath: 'terraform/function'
}

output monitoring object = {
  workspace: workspace.outputs.workspaceName
  applicationInsights: workspace.outputs.appInsightsName
  actionGroup: monitoring.outputs.failoverActionGroupName
  emailActionGroup: monitoring.outputs.emailActionGroupName
  workbook: monitoring.outputs.workbookName
  portalDashboard: portalDashboard.outputs.dashboardName
  alerts: [
    'alert-primary-probe-down'
    'alert-secondary-probe-down'
    'alert-aci-stopped'
    'alert-watchdog-exceptions'
    'alert-secondary-region-up'
    'alert-failback-primary'
  ]
}

output vnetPeeringState object = {
  primaryToSecondary: peerPrimary.outputs.peeringName
  secondaryToPrimary: peerSecondary.outputs.peeringName
}

output testVmPublicIp string = deployTestVm ? testVm!.outputs.publicIp : ''

output suffix string = suffix

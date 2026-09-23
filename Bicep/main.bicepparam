using './main.bicep'

// Values follow terraform/terraform.tfvars where that file sets them, and
// terraform/variables.tf defaults everywhere else. Names of VNets, subnets,
// gateways, and the container groups are the literals in terraform/main.tf.

// primary_resource_group_name
param primaryResourceGroupName = 'rg-appgw-primary-eus'

// secondary_resource_group_name
param secondaryResourceGroupName = 'rg-appgw-secondary-cus'

// shared_resource_group_name
param sharedResourceGroupName = 'rg-appgw-shared-group'

// primary_location
param primaryLocation = 'eastus'

// secondary_location
param secondaryLocation = 'centralus'

// shared_location is commented out in terraform.tfvars and falls back to primary_location.

// tags
param tags = {
  businessUnit: 'OMP'
  costCenter: 'CIS'
  env: 'Dev'
  owner: 'chase.goebel@ibm.com'
}

// primary_vnet_address_space
param primaryVnetAddressSpace = [
  '10.1.0.0/16'
]

// secondary_vnet_address_space
param secondaryVnetAddressSpace = [
  '10.2.0.0/16'
]

// primary_appgw_subnet_prefix
param primaryAppgwSubnetPrefix = '10.1.1.0/24'

// secondary_appgw_subnet_prefix
param secondaryAppgwSubnetPrefix = '10.2.1.0/24'

// primary_aci_subnet_prefix
param primaryAciSubnetPrefix = '10.1.2.0/24'

// secondary_aci_subnet_prefix
param secondaryAciSubnetPrefix = '10.2.2.0/24'

// client_subnet_prefix
param clientSubnetPrefix = '10.1.10.0/24'

// primary_appgw_private_ip
param primaryAppgwPrivateIp = '10.1.1.10'

// secondary_appgw_private_ip
param secondaryAppgwPrivateIp = '10.2.1.10'

// container_image
param containerImage = 'mcr.microsoft.com/azuredocs/aci-helloworld'

// container_port
param containerPort = 80

// container_cpu
param containerCpu = 1

// container_memory_in_gb
param containerMemoryInGb = 1

// appgw_capacity
param appgwCapacity = 1

// health_probe_path
param healthProbePath = '/'

// private_dns_zone_name
param privateDnsZoneName = 'internal.contoso.com'

// dns_record_name
param dnsRecordName = 'ContainerApp'

// dns_record_ttl
param dnsRecordTtl = 30

// First deployment seeds ContainerApp at the primary gateway. Set false on a
// later deployment so the watchdog's A record is left alone.
param seedDnsRecord = true

// app_service_plan_sku
param appServicePlanSku = 'B1'

// python_version
param pythonVersion = '3.11'

// watchdog_schedule
param watchdogSchedule = '*/30 * * * * *'

// backend_healthy_states
param backendHealthyStates = [
  'Up'
  'Healthy'
]

// log_retention_in_days
param logRetentionInDays = 30

// alert_email_address
param alertEmailAddress = 'chase.goebel@ibm.com'

// unhealthy_host_threshold
param unhealthyHostThreshold = 1

// deploy_test_vm
param deployTestVm = false

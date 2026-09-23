data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

locals {
  subscription_id = coalesce(var.subscription_id, data.azurerm_client_config.current.subscription_id)
  shared_location = coalesce(var.shared_location, var.primary_location)
}

resource "random_string" "suffix" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# Regional groups can be torn down independently. The shared group holds
# everything that must survive the loss of either region: the DNS record clients
# resolve, the watchdog that moves it, and all monitoring.
resource "azurerm_resource_group" "primary" {
  name     = var.primary_resource_group_name
  location = var.primary_location
  tags     = var.tags
}

resource "azurerm_resource_group" "secondary" {
  name     = var.secondary_resource_group_name
  location = var.secondary_location
  tags     = var.tags
}

resource "azurerm_resource_group" "shared" {
  name     = var.shared_resource_group_name
  location = local.shared_location
  tags     = var.tags
}

module "primary" {
  source = "./modules/region"

  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_location
  tags                = var.tags

  vnet_name          = "vnet-eus-dr"
  vnet_address_space = var.primary_vnet_address_space

  appgw_subnet_name   = "snet-appgw-eus"
  appgw_subnet_prefix = var.primary_appgw_subnet_prefix
  aci_subnet_name     = "snet-aci-eus"
  aci_subnet_prefix   = var.primary_aci_subnet_prefix

  nat_gateway_name   = "nat-aci-eus"
  nat_public_ip_name = "pip-nat-eus"

  container_group_name   = "aci-eus-dr"
  container_image        = var.container_image
  container_port         = var.container_port
  container_cpu          = var.container_cpu
  container_memory_in_gb = var.container_memory_in_gb

  appgw_name        = "agw-eus-dr"
  appgw_private_ip  = var.primary_appgw_private_ip
  appgw_capacity    = var.appgw_capacity
  health_probe_path = var.health_probe_path

  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id
}

module "secondary" {
  source = "./modules/region"

  resource_group_name = azurerm_resource_group.secondary.name
  location            = var.secondary_location
  tags                = var.tags

  vnet_name          = "vnet-cus-dr"
  vnet_address_space = var.secondary_vnet_address_space

  appgw_subnet_name   = "snet-appgw-cus"
  appgw_subnet_prefix = var.secondary_appgw_subnet_prefix
  aci_subnet_name     = "snet-aci-cus"
  aci_subnet_prefix   = var.secondary_aci_subnet_prefix

  nat_gateway_name   = "nat-aci-cus"
  nat_public_ip_name = "pip-nat-cus"

  container_group_name   = "aci-cus-dr"
  container_image        = var.container_image
  container_port         = var.container_port
  container_cpu          = var.container_cpu
  container_memory_in_gb = var.container_memory_in_gb

  appgw_name        = "agw-cus-dr"
  appgw_private_ip  = var.secondary_appgw_private_ip
  appgw_capacity    = var.appgw_capacity
  health_probe_path = var.health_probe_path

  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id
}

# Peering lets the test VM in the primary VNet reach the secondary gateway, so a
# single client can verify both regions. The watchdog does not depend on it: it
# reads state from ARM rather than probing the private frontends.
resource "azurerm_virtual_network_peering" "primary_to_secondary" {
  name                         = "peer-eus-to-cus"
  resource_group_name          = azurerm_resource_group.primary.name
  virtual_network_name         = module.primary.vnet_name
  remote_virtual_network_id    = module.secondary.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "secondary_to_primary" {
  name                         = "peer-cus-to-eus"
  resource_group_name          = azurerm_resource_group.secondary.name
  virtual_network_name         = module.secondary.vnet_name
  remote_virtual_network_id    = module.primary.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_subnet" "client" {
  name                 = "snet-client"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = module.primary.vnet_name
  address_prefixes     = [var.client_subnet_prefix]
}

locals {
  frontend_ip_name   = "feip-private"
  frontend_port_name = "feport-http"
  gateway_ip_name    = "gwip"
  backend_pool_name  = "bepool-aci"
  http_setting_name  = "behttp-80"
  listener_name      = "listener-http"
  probe_name         = "probe-aci"
  rule_name          = "rule-http"
}

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# Delegation to Microsoft.Network/applicationGateways is what allows the
# gateway to run with a private frontend and no public IP.
resource "azurerm_subnet" "appgw" {
  name                 = var.appgw_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.appgw_subnet_prefix]

  delegation {
    name = "appgw-network-isolation"

    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "aci" {
  name                 = var.aci_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aci_subnet_prefix]

  delegation {
    name = "aci"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# A container group with a private IP has no outbound path of its own, so the
# NAT gateway is what lets it pull its image from the registry.
resource "azurerm_public_ip" "nat" {
  name                = var.nat_public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  allocation_method   = "Static"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = var.nat_gateway_name
  resource_group_name     = var.resource_group_name
  location                = var.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aci" {
  subnet_id      = azurerm_subnet.aci.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_container_group" "this" {
  name                = var.container_group_name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [azurerm_subnet.aci.id]
  restart_policy      = "Always"
  tags                = var.tags

  container {
    name   = "app"
    image  = var.container_image
    cpu    = var.container_cpu
    memory = var.container_memory_in_gb

    ports {
      port     = var.container_port
      protocol = "TCP"
    }
  }

  # Without outbound access through the NAT gateway the image pull fails.
  depends_on = [
    azurerm_nat_gateway_public_ip_association.this,
    azurerm_subnet_nat_gateway_association.aci,
  ]
}

resource "azurerm_application_gateway" "this" {
  name                = var.appgw_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = var.appgw_capacity
  }

  gateway_ip_configuration {
    name      = local.gateway_ip_name
    subnet_id = azurerm_subnet.appgw.id
  }

  # Private frontend only. Omitting public_ip_address_id is what makes this a
  # private-only gateway and requires the network isolation feature flag.
  frontend_ip_configuration {
    name                          = local.frontend_ip_name
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address            = var.appgw_private_ip
    private_ip_address_allocation = "Static"
  }

  frontend_port {
    name = local.frontend_port_name
    port = 80
  }

  backend_address_pool {
    name         = local.backend_pool_name
    ip_addresses = [azurerm_container_group.this.ip_address]
  }

  # The backend pool holds bare IPs, so the probe carries an explicit host
  # header rather than deriving one from a backend FQDN that does not exist.
  probe {
    name                = local.probe_name
    protocol            = "Http"
    host                = "127.0.0.1"
    path                = var.health_probe_path
    port                = var.container_port
    interval            = 15
    timeout             = 10
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                  = local.http_setting_name
    port                  = var.container_port
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 30
    probe_name            = local.probe_name
  }

  http_listener {
    name                           = local.listener_name
    frontend_ip_configuration_name = local.frontend_ip_name
    frontend_port_name             = local.frontend_port_name
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = local.rule_name
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.listener_name
    backend_address_pool_name  = local.backend_pool_name
    backend_http_settings_name = local.http_setting_name
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# Feeds HealthyHostCount and UnhealthyHostCount into the shared workspace so the
# dashboard can chart both regions side by side. The failover path itself reads
# live backend health from ARM and does not wait on this pipeline.
resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

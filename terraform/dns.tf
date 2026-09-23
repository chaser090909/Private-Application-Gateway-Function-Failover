resource "azurerm_private_dns_zone" "lab" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.shared.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "primary" {
  name                 = "link-eus"
  private_dns_zone_id  = azurerm_private_dns_zone.lab.id
  virtual_network_id   = module.primary.vnet_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "secondary" {
  name                 = "link-cus"
  private_dns_zone_id  = azurerm_private_dns_zone.lab.id
  virtual_network_id   = module.secondary.vnet_id
  registration_enabled = false
  tags                 = var.tags
}

# This record is the failover mechanism: clients only ever resolve it, so
# repointing it moves traffic. Terraform seeds it at the primary gateway and then
# hands ownership to the watchdog, which is why it ignores changes to records.
# Without that, the first plan after a failover would propose dragging traffic
# back to the dead region.
resource "azurerm_private_dns_a_record" "app" {
  name                = var.dns_record_name
  private_dns_zone_id = azurerm_private_dns_zone.lab.id
  ttl                 = var.dns_record_ttl
  records             = [module.primary.appgw_private_ip]
  tags                = var.tags

  lifecycle {
    ignore_changes = [records]
  }
}

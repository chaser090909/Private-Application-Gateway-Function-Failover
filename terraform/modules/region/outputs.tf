output "vnet_id" {
  description = "Resource ID of the regional virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the regional virtual network."
  value       = azurerm_virtual_network.this.name
}

output "appgw_name" {
  description = "Name of the Application Gateway."
  value       = azurerm_application_gateway.this.name
}

output "appgw_id" {
  description = "Resource ID of the Application Gateway."
  value       = azurerm_application_gateway.this.id
}

output "appgw_private_ip" {
  description = "Private frontend IP of the Application Gateway."
  value       = azurerm_application_gateway.this.frontend_ip_configuration[0].private_ip_address
}

output "container_group_name" {
  description = "Name of the backend container group."
  value       = azurerm_container_group.this.name
}

output "container_group_id" {
  description = "Resource ID of the backend container group, used to scope the activity log alert."
  value       = azurerm_container_group.this.id
}

output "container_private_ip" {
  description = "Private IP of the backend container group, which is the gateway's backend pool member."
  value       = azurerm_container_group.this.ip_address
}

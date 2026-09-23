output "resource_groups" {
  description = "The three resource groups this stack is split across."
  value = {
    primary   = azurerm_resource_group.primary.name
    secondary = azurerm_resource_group.secondary.name
    shared    = azurerm_resource_group.shared.name
  }
}

output "primary_appgw" {
  description = "Primary Application Gateway name, private frontend IP, and backend member."
  value = {
    resource_group   = azurerm_resource_group.primary.name
    name             = module.primary.appgw_name
    private_ip       = module.primary.appgw_private_ip
    backend_aci_ip   = module.primary.container_private_ip
    backend_aci_name = module.primary.container_group_name
  }
}

output "secondary_appgw" {
  description = "Secondary Application Gateway name, private frontend IP, and backend member."
  value = {
    resource_group   = azurerm_resource_group.secondary.name
    name             = module.secondary.appgw_name
    private_ip       = module.secondary.appgw_private_ip
    backend_aci_ip   = module.secondary.container_private_ip
    backend_aci_name = module.secondary.container_group_name
  }
}

output "application_fqdn" {
  description = "Name clients resolve. Points at whichever region is currently healthy."
  value       = "${var.dns_record_name}.${var.private_dns_zone_name}"
}

output "watchdog" {
  description = "Watchdog Function App identifiers, including the managed identity that holds all its permissions."
  value = {
    name         = azurerm_linux_function_app.watchdog.name
    hostname     = azurerm_linux_function_app.watchdog.default_hostname
    plan_sku     = azurerm_service_plan.watchdog.sku_name
    principal_id = azurerm_linux_function_app.watchdog.identity[0].principal_id
    schedule     = var.watchdog_schedule
  }
}

output "monitoring" {
  description = "Monitoring resources backing the dashboard and the failover alerts."
  value = {
    workspace            = azurerm_log_analytics_workspace.shared.name
    application_insights = azurerm_application_insights.shared.name
    action_group         = azurerm_monitor_action_group.failover.name
    email_action_group   = one(azurerm_monitor_action_group.notify[*].name)
    workbook             = azurerm_application_insights_workbook.dashboard.display_name
    portal_dashboard     = local.portal_dashboard_title
    alerts = concat(
      [for alert in azurerm_monitor_metric_alert.unhealthy_hosts : alert.name],
      [
        azurerm_monitor_activity_log_alert.container_stopped.name,
        azurerm_monitor_scheduled_query_rules_alert_v2.watchdog_failing.name,
        azurerm_monitor_scheduled_query_rules_alert_v2.secondary_region_up.name,
        azurerm_monitor_scheduled_query_rules_alert_v2.failback_primary.name,
      ],
    )
  }
}

output "vnet_peering_state" {
  description = "Peering names in each direction."
  value = {
    primary_to_secondary = azurerm_virtual_network_peering.primary_to_secondary.name
    secondary_to_primary = azurerm_virtual_network_peering.secondary_to_primary.name
  }
}

output "test_vm_public_ip" {
  description = "Public IP of the optional test VM, or null when it is not deployed."
  value       = var.deploy_test_vm ? azurerm_public_ip.test_vm[0].ip_address : null
}

output "failover_webhook_uri" {
  description = "Endpoint the action group posts to. Contains a host key, so it is sensitive."
  value       = local.failover_webhook_uri
  sensitive   = true
}

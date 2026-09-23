# Everything the watchdog does to ARM runs as its system-assigned managed
# identity. There are no keys and no service principal secrets anywhere in this
# stack, so these role assignments are the complete list of what it can do.

locals {
  watchdog_principal_id = azurerm_linux_function_app.watchdog.identity[0].principal_id

  regional_resource_group_ids = {
    primary   = azurerm_resource_group.primary.id
    secondary = azurerm_resource_group.secondary.id
  }
}

# Reader would cover the read operations but not backendhealth, which is a
# POST action. Network Contributor covers it but grants far too much, so the
# watchdog gets a purpose-built role with exactly these operations.
resource "azurerm_role_definition" "watchdog" {
  name        = "Private AppGW DR Watchdog (${random_string.suffix.result})"
  scope       = data.azurerm_subscription.current.id
  description = "Read container group state, Application Gateway backend health, and gateway probe metrics. Grants no write access."

  permissions {
    actions = [
      "Microsoft.ContainerInstance/containerGroups/read",
      "Microsoft.Network/applicationGateways/read",
      "Microsoft.Network/applicationGateways/backendhealth/action",
      "Microsoft.Insights/metrics/read",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "watchdog_regional" {
  for_each = local.regional_resource_group_ids

  scope              = each.value
  role_definition_id = azurerm_role_definition.watchdog.role_definition_resource_id
  principal_id       = local.watchdog_principal_id
  principal_type     = "ServicePrincipal"
}

# The only write permission the watchdog holds, scoped to the single zone that
# holds the failover record.
resource "azurerm_role_assignment" "watchdog_dns" {
  scope                = azurerm_private_dns_zone.lab.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = local.watchdog_principal_id
  principal_type       = "ServicePrincipal"
}

# AzureWebJobsStorage runs on the managed identity too, which is why the Function
# App carries no storage account key. Blob covers the timer's singleton lease and
# schedule state; queue and table cover the runtime's own bookkeeping.
resource "azurerm_role_assignment" "watchdog_storage" {
  for_each = toset([
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ])

  scope                = azurerm_storage_account.watchdog.id
  role_definition_name = each.value
  principal_id         = local.watchdog_principal_id
  principal_type       = "ServicePrincipal"
}

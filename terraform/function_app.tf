locals {
  watchdog_app_name    = "func-appgw-dr-${random_string.suffix.result}"
  storage_account_name = "stagwdr${random_string.suffix.result}"
  watchdog_zip_path    = abspath("${path.module}/.artifacts/watchdog.zip")
}

resource "azurerm_storage_account" "watchdog" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = local.shared_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_service_plan" "watchdog" {
  name                = "plan-appgw-dr-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  os_type             = "Linux"
  sku_name            = var.app_service_plan_sku
  tags                = var.tags
}

resource "azurerm_linux_function_app" "watchdog" {
  name                = local.watchdog_app_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  service_plan_id     = azurerm_service_plan.watchdog.id

  # Keyless storage. Terraform emits AzureWebJobsStorage__accountName instead of
  # a connection string, and the data-plane roles in rbac.tf back it.
  storage_account_name          = azurerm_storage_account.watchdog.name
  storage_uses_managed_identity = true

  https_only                  = true
  builtin_logging_enabled     = true
  functions_extension_version = "~4"

  identity {
    type = "SystemAssigned"
  }

  site_config {
    # A dedicated plan idles its workers out without this, which would stall the
    # 30-second timer. It is the reason the plan is B1 rather than Consumption.
    always_on  = true
    ftps_state = "Disabled"

    application_stack {
      python_version = var.python_version
    }

    application_insights_connection_string = azurerm_application_insights.shared.connection_string
    application_insights_key               = azurerm_application_insights.shared.instrumentation_key
  }

  app_settings = {
    # An Oryx build on the platform is what actually installs azure-identity and
    # the ARM SDKs. Publishing a prebuilt package with WEBSITE_RUN_FROM_PACKAGE
    # leaves them missing and the app imports nothing, so both build flags stay
    # on and WEBSITE_RUN_FROM_PACKAGE is deliberately absent.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
    # Python v2 indexing. Without this the timer and the failover webhook
    # deploy but never appear, so the action group posts into a 404.
    AzureWebJobsFeatureFlags = "EnableWorkerIndexing"

    AZURE_SUBSCRIPTION_ID = local.subscription_id
    WATCHDOG_SCHEDULE     = var.watchdog_schedule

    DNS_RESOURCE_GROUP = azurerm_resource_group.shared.name
    DNS_ZONE_NAME      = azurerm_private_dns_zone.lab.name
    DNS_RECORD_NAME    = var.dns_record_name
    DNS_RECORD_TTL     = tostring(var.dns_record_ttl)

    PRIMARY_RESOURCE_GROUP  = azurerm_resource_group.primary.name
    PRIMARY_CONTAINER_GROUP = module.primary.container_group_name
    PRIMARY_APPGW_NAME      = module.primary.appgw_name
    PRIMARY_APPGW_IP        = module.primary.appgw_private_ip

    SECONDARY_RESOURCE_GROUP  = azurerm_resource_group.secondary.name
    SECONDARY_CONTAINER_GROUP = module.secondary.container_group_name
    SECONDARY_APPGW_NAME      = module.secondary.appgw_name
    SECONDARY_APPGW_IP        = module.secondary.appgw_private_ip

    BACKEND_HEALTHY_STATES = join(",", var.backend_healthy_states)
  }
}

data "archive_file" "watchdog" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = local.watchdog_zip_path
}

# --build-remote true is the whole point: it runs an Oryx build on the platform
# so requirements.txt is actually installed. The provider's zip_deploy_file
# uploads the package as-is, which is how azure-identity ends up missing and the
# watchdog silently never runs.
resource "terraform_data" "publish_watchdog" {
  count = var.deploy_function_code ? 1 : 0

  triggers_replace = {
    package  = data.archive_file.watchdog.output_base64sha256
    app_name = azurerm_linux_function_app.watchdog.name
  }

  provisioner "local-exec" {
    # PowerShell supports the UNC workspace path. Terraform's default cmd.exe
    # interpreter does not, and can also pass the surrounding quotes through
    # to Azure CLI as part of the subscription value.
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "az functionapp deployment source config-zip --subscription ${local.subscription_id} --resource-group '${azurerm_resource_group.shared.name}' --name '${azurerm_linux_function_app.watchdog.name}' --src '${data.archive_file.watchdog.output_path}' --build-remote true"
  }

  # The identity must be able to read state and write DNS before the first timer
  # tick fires, otherwise the initial executions just log authorization failures.
  depends_on = [
    azurerm_role_assignment.watchdog_regional,
    azurerm_role_assignment.watchdog_dns,
    azurerm_role_assignment.watchdog_storage,
  ]
}

# Deferred until the app exists, then used to build the action group webhook URL.
data "azurerm_function_app_host_keys" "watchdog" {
  name                = azurerm_linux_function_app.watchdog.name
  resource_group_name = azurerm_resource_group.shared.name

  depends_on = [terraform_data.publish_watchdog]
}

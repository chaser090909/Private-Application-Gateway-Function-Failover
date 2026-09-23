locals {
  # The action group posts here. Auth is the host key rather than an anonymous
  # endpoint, so an arbitrary caller cannot trigger a region failover.
  failover_webhook_uri = "https://${azurerm_linux_function_app.watchdog.default_hostname}/api/region-failover?code=${data.azurerm_function_app_host_keys.watchdog.default_function_key}"

  monitored_gateways = {
    primary = {
      appgw_id   = module.primary.appgw_id
      appgw_name = module.primary.appgw_name
    }
    secondary = {
      appgw_id   = module.secondary.appgw_id
      appgw_name = module.secondary.appgw_name
    }
  }
}

resource "azurerm_log_analytics_workspace" "shared" {
  name                = "law-appgw-dr-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_in_days
  tags                = var.tags
}

# Workspace-based, so the watchdog's traces land in the same workspace the
# gateway metrics do and the dashboard can query both in one place.
resource "azurerm_application_insights" "shared" {
  name                = "appi-appgw-dr-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  workspace_id        = azurerm_log_analytics_workspace.shared.id
  application_type    = "web"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Action groups
# ---------------------------------------------------------------------------

# Primary probe down and primary container stop land here. Email goes out and
# the webhook runs the watchdog, which moves DNS to the secondary region when
# the primary probe is actually down.
resource "azurerm_monitor_action_group" "failover" {
  name                = "ag-appgw-dr-failover"
  resource_group_name = azurerm_resource_group.shared.name
  short_name          = "agwdr"
  tags                = var.tags

  webhook_receiver {
    name                    = "region-failover"
    service_uri             = local.failover_webhook_uri
    use_common_alert_schema = true
  }

  dynamic "email_receiver" {
    for_each = var.alert_email_address == "" ? [] : [var.alert_email_address]

    content {
      name                    = "ops"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# Watchdog exceptions must not call the webhook. A function that is already
# throwing would just be invoked again.
resource "azurerm_monitor_action_group" "notify" {
  count = var.alert_email_address == "" ? 0 : 1

  name                = "ag-appgw-dr-email"
  resource_group_name = azurerm_resource_group.shared.name
  short_name          = "agwemail"
  tags                = var.tags

  email_receiver {
    name                    = "ops"
    email_address           = var.alert_email_address
    use_common_alert_schema = true
  }
}

# ---------------------------------------------------------------------------
# Failure alerts
# ---------------------------------------------------------------------------

# UnhealthyHostCount >= 1 over a one-minute window. Each gateway has a single
# backend member, so one unhealthy host means the custom probe (probe-aci) is down.
# The primary alert emails the failover action group, which also calls the
# watchdog and moves DNS to the secondary region.
resource "azurerm_monitor_metric_alert" "unhealthy_hosts" {
  for_each = local.monitored_gateways

  name                = each.key == "primary" ? "alert-primary-probe-down" : "alert-secondary-probe-down"
  resource_group_name = azurerm_resource_group.shared.name
  scopes              = [each.value.appgw_id]
  description = each.key == "primary" ? (
    "Primary custom probe on ${each.value.appgw_name} is down (UnhealthyHostCount). Emails the action group and fails over to the secondary region."
    ) : (
    "Secondary custom probe on ${each.value.appgw_name} is down (UnhealthyHostCount). Emails the action group. The watchdog will not move traffic onto an unhealthy secondary."
  )
  severity      = 1
  frequency     = "PT1M"
  window_size   = "PT1M"
  auto_mitigate = true
  tags          = var.tags

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "UnhealthyHostCount"
    # This metric is published only as Average, one series per backend pool.
    aggregation = "Average"
    operator    = "GreaterThanOrEqual"
    threshold   = var.unhealthy_host_threshold

    dimension {
      name     = "BackendSettingsPool"
      operator = "Include"
      values   = ["*"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.failover.id
  }
}

# Stopping the primary backend is the drill's failure injection and a plausible
# real incident, and the activity log surfaces it faster than any metric.
resource "azurerm_monitor_activity_log_alert" "container_stopped" {
  name                = "alert-aci-stopped"
  resource_group_name = azurerm_resource_group.shared.name
  location            = "global"
  scopes              = [azurerm_resource_group.primary.id]
  description         = "The primary backend container group was stopped. Emails the action group and fails over to the secondary region."
  tags                = var.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.ContainerInstance/containerGroups/stop/action"
    status         = "Succeeded"
  }

  action {
    action_group_id = azurerm_monitor_action_group.failover.id
  }
}

# A watchdog that throws on every tick cannot fail anything over, and nothing
# else in the stack would notice. Unhandled exceptions are exactly how a missing
# dependency shows up, so this is the alert that catches a broken deployment.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "watchdog_failing" {
  name                    = "alert-watchdog-exceptions"
  resource_group_name     = azurerm_resource_group.shared.name
  location                = local.shared_location
  scopes                  = [azurerm_log_analytics_workspace.shared.id]
  description             = "The watchdog is raising unhandled exceptions and may not be able to fail over."
  severity                = 1
  enabled                 = true
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = var.tags

  criteria {
    query                   = <<-KQL
      AppExceptions
      | where AppRoleName startswith "func-appgw-dr"
      | summarize Exceptions = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "Exceptions"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = concat(
      azurerm_monitor_action_group.notify[*].id,
      var.alert_email_address == "" ? [azurerm_monitor_action_group.failover.id] : [],
    )
  }
}

# Email only. The watchdog logs SECONDARY_REGION_UP while Central US can serve,
# so this stays fired for a healthy secondary and resolves once those logs stop.
# It does not call the failover webhook.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "secondary_region_up" {
  name                    = "alert-secondary-region-up"
  resource_group_name     = azurerm_resource_group.shared.name
  location                = local.shared_location
  scopes                  = [azurerm_log_analytics_workspace.shared.id]
  description             = "Secondary region is up. Emails the action group. Does not move DNS."
  severity                = 2
  enabled                 = true
  evaluation_frequency    = "PT1M"
  window_duration         = "PT5M"
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = var.tags

  criteria {
    query                   = <<-KQL
      AppTraces
      | where AppRoleName startswith "func-appgw-dr"
      | where Message has "SECONDARY_REGION_UP"
      | summarize Events = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "Events"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = concat(
      azurerm_monitor_action_group.notify[*].id,
      var.alert_email_address == "" ? [azurerm_monitor_action_group.failover.id] : [],
    )
  }
}

# Email only. Logged once, when the watchdog actually repoints DNS at East US.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "failback_primary" {
  name                    = "alert-failback-primary"
  resource_group_name     = azurerm_resource_group.shared.name
  location                = local.shared_location
  scopes                  = [azurerm_log_analytics_workspace.shared.id]
  description             = "Traffic was sent back to the primary region. Emails the action group."
  severity                = 2
  enabled                 = true
  evaluation_frequency    = "PT1M"
  window_duration         = "PT5M"
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = var.tags

  criteria {
    query                   = <<-KQL
      AppTraces
      | where AppRoleName startswith "func-appgw-dr"
      | where Message has "FAILBACK_PRIMARY"
      | summarize Events = count()
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "Events"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = concat(
      azurerm_monitor_action_group.notify[*].id,
      var.alert_email_address == "" ? [azurerm_monitor_action_group.failover.id] : [],
    )
  }
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

resource "random_uuid" "dashboard" {}

# Queries the workspace rather than the metrics API, so healthy-host history,
# gateway access logs, and the watchdog's own decisions sit on one page. Metric
# ingestion into the workspace lags by a few minutes; the failover path does not
# depend on it.
resource "azurerm_application_insights_workbook" "dashboard" {
  name                = random_uuid.dashboard.result
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  display_name        = "Private Application Gateway DR"
  description         = "Custom probe health for both gateways, secondary-region-up, and failback to primary."
  category            = "workbook"
  source_id           = lower(azurerm_log_analytics_workspace.shared.id)
  tags                = var.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "title"
        content = {
          json = join("\n", [
            "# Private Application Gateway DR",
            "",
            "`${var.dns_record_name}.${var.private_dns_zone_name}` resolves to whichever region is healthy.",
            "",
            "Custom probe `probe-aci` requests `${var.health_probe_path}` and matches HTTP 200-399. A host is unhealthy when that probe fails.",
            "When the primary probe is down, `alert-primary-probe-down` emails `${var.alert_email_address}` and the failover action group moves DNS to the secondary gateway.",
            "`alert-secondary-region-up` emails when Central US can serve. `alert-failback-primary` emails when traffic is sent back to East US.",
            "",
            "| Region | Gateway | Private frontend |",
            "| --- | --- | --- |",
            "| Primary (${var.primary_location}) | ${module.primary.appgw_name} | ${module.primary.appgw_private_ip} |",
            "| Secondary (${var.secondary_location}) | ${module.secondary.appgw_name} | ${module.secondary.appgw_private_ip} |",
          ])
        }
      },
      {
        type = 3
        name = "current-state"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 1
          title         = "Probe health by gateway"
          timeContext   = { durationMs = 3600000 }
          visualization = "table"
          query         = <<-KQL
            AzureMetrics
            | where ResourceProvider =~ "MICROSOFT.NETWORK"
            | where MetricName in ("HealthyHostCount", "UnhealthyHostCount")
            | extend Gateway = tostring(split(ResourceId, "/")[-1])
            | extend Hosts = iff(isnull(Average), coalesce(Maximum, Total), Average)
            | summarize arg_max(TimeGenerated, Hosts) by Gateway, MetricName
            | summarize
                Healthy = maxif(Hosts, MetricName == "HealthyHostCount"),
                Unhealthy = maxif(Hosts, MetricName == "UnhealthyHostCount"),
                AsOf = max(TimeGenerated)
                by Gateway
            | extend ProbeHealth = case(
                Unhealthy > 0, "Down",
                Healthy > 0, "Up",
                "Unknown")
            | project Gateway, ProbeHealth, Healthy = round(Healthy, 1), Unhealthy = round(Unhealthy, 1), AsOf
            | order by Gateway asc
          KQL
        }
      },
      {
        type = 3
        name = "healthy-hosts"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 0
          title         = "Healthy hosts by gateway"
          timeContext   = { durationMs = 14400000 }
          visualization = "timechart"
          query         = <<-KQL
            AzureMetrics
            | where ResourceProvider =~ "MICROSOFT.NETWORK"
            | where MetricName == "HealthyHostCount"
            | extend Gateway = tostring(split(ResourceId, "/")[-1])
            | extend Hosts = iff(isnull(Average), coalesce(Maximum, Total), Average)
            | summarize HealthyHosts = avg(Hosts) by bin(TimeGenerated, 5m), Gateway
          KQL
        }
      },
      {
        type = 3
        name = "unhealthy-hosts"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 0
          title         = "Unhealthy hosts by gateway (primary probe-down alert)"
          timeContext   = { durationMs = 14400000 }
          visualization = "timechart"
          query         = <<-KQL
            AzureMetrics
            | where ResourceProvider =~ "MICROSOFT.NETWORK"
            | where MetricName == "UnhealthyHostCount"
            | extend Gateway = tostring(split(ResourceId, "/")[-1])
            | extend Hosts = iff(isnull(Average), coalesce(Maximum, Total), Average)
            | summarize UnhealthyHosts = avg(Hosts) by bin(TimeGenerated, 5m), Gateway
          KQL
        }
      },
      {
        type = 3
        name = "failover-decisions"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 0
          title         = "Probe decisions and DNS moves"
          timeContext   = { durationMs = 14400000 }
          visualization = "table"
          query         = <<-KQL
            AppTraces
            | where AppRoleName startswith "func-appgw-dr"
            | where Message has "PROBE_HEALTH" or Message has "repointed" or Message has "FAILBACK_PRIMARY"
            | project TimeGenerated, SeverityLevel, Message
            | order by TimeGenerated desc
            | take 200
          KQL
        }
      },
      {
        type = 3
        name = "secondary-region-up"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 1
          title         = "Secondary region up (alert-secondary-region-up)"
          timeContext   = { durationMs = 3600000 }
          visualization = "table"
          query         = <<-KQL
            AppTraces
            | where AppRoleName startswith "func-appgw-dr"
            | where Message has "SECONDARY_REGION_UP"
            | summarize Signals = count(), LastSeen = max(TimeGenerated)
            | extend Status = iff(LastSeen > ago(10m), "Up", "No recent signal")
            | project Status, Signals, LastSeen
          KQL
        }
      },
      {
        type = 3
        name = "failback-primary"
        content = {
          version       = "KqlItem/1.0"
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          size          = 0
          title         = "Traffic sent back to primary (alert-failback-primary)"
          timeContext   = { durationMs = 14400000 }
          visualization = "table"
          query         = <<-KQL
            AppTraces
            | where AppRoleName startswith "func-appgw-dr"
            | where Message has "FAILBACK_PRIMARY"
            | project TimeGenerated, Message
            | order by TimeGenerated desc
            | take 50
          KQL
        }
      },
    ]
    fallbackResourceIds = [azurerm_log_analytics_workspace.shared.id]
  })
}

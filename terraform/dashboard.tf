# Portal dashboard in the shared resource group. The workbook remains the
# detailed log view. This page is the one-screen read: who is healthy, whether
# Central US can serve, and what each alert does.

locals {
  portal_dashboard_title = "Private Application Gateway DR"
  portal_dashboard_name  = uuidv5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "portal-dashboard-${random_string.suffix.result}")

  probe_health_kql = <<-KQL
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
    | extend Probe = case(Unhealthy > 0, "Down", Healthy > 0, "Up", "Unknown")
    | project Gateway, Probe, Healthy = round(Healthy, 1), Unhealthy = round(Unhealthy, 1), AsOf
    | order by Gateway asc
  KQL

  secondary_up_kql = <<-KQL
    AppTraces
    | where AppRoleName startswith "func-appgw-dr"
    | where Message has "SECONDARY_REGION_UP"
    | summarize Signals = count(), LastSeen = max(TimeGenerated)
    | extend Status = iff(LastSeen > ago(10m), "Up", "No recent signal")
    | project Status, Signals, LastSeen
  KQL

  decisions_kql = <<-KQL
    AppTraces
    | where AppRoleName startswith "func-appgw-dr"
    | where Message has "PROBE_HEALTH" or Message has "repointed" or Message has "FAILBACK_PRIMARY"
    | project TimeGenerated, SeverityLevel, Message
    | order by TimeGenerated desc
    | take 40
  KQL

  failback_kql = <<-KQL
    AppTraces
    | where AppRoleName startswith "func-appgw-dr"
    | where Message has "FAILBACK_PRIMARY"
    | project TimeGenerated, Message
    | order by TimeGenerated desc
    | take 20
  KQL

  dashboard_header_md = <<-MD
    # Private Application Gateway DR

    **${var.dns_record_name}.${var.private_dns_zone_name}** follows the healthy gateway. Probe `probe-aci` requests `${var.health_probe_path}` and matches HTTP 200-399.

    | | Primary | Secondary |
    | --- | --- | --- |
    | Region | ${var.primary_location} | ${var.secondary_location} |
    | Gateway | ${module.primary.appgw_name} | ${module.secondary.appgw_name} |
    | Private IP | ${module.primary.appgw_private_ip} | ${module.secondary.appgw_private_ip} |

    Charts are live metrics. Log tiles wait a few minutes for workspace ingestion. The page time range is the last 4 hours.
  MD

  dashboard_alerts_md = <<-MD
    ## Alerts

    | Alert | When it fires | What it does |
    | --- | --- | --- |
    | alert-primary-probe-down | Primary unhealthy hosts at or above 1 | Emails and moves DNS to the secondary |
    | alert-aci-stopped | Primary container stop succeeds | Emails and moves DNS to the secondary |
    | alert-secondary-probe-down | Secondary unhealthy hosts at or above 1 | Emails. Traffic stays off a dead secondary |
    | alert-secondary-region-up | `SECONDARY_REGION_UP` is logged | Emails while Central US can serve |
    | alert-failback-primary | `FAILBACK_PRIMARY` is logged | Emails when DNS returns to the primary |
    | alert-watchdog-exceptions | The watchdog throws | Emails only. Does not call the webhook |

    Failover mail is **ag-appgw-dr-failover** to ${var.alert_email_address}. Status mail is **ag-appgw-dr-email**.
  MD

  dashboard_log_tiles = [
    {
      key      = "probe-health"
      x        = 0
      y        = 4
      col_span = 7
      row_span = 5
      title    = "Probe health"
      subtitle = "Down when unhealthy hosts are above 0"
      query    = local.probe_health_kql
    },
    {
      key      = "secondary-up"
      x        = 7
      y        = 4
      col_span = 5
      row_span = 5
      title    = "Secondary region"
      subtitle = "Up while Central US can serve"
      query    = local.secondary_up_kql
    },
    {
      key      = "decisions"
      x        = 0
      y        = 13
      col_span = 8
      row_span = 5
      title    = "Probe decisions and DNS moves"
      subtitle = "Watchdog log"
      query    = local.decisions_kql
    },
    {
      key      = "failback"
      x        = 8
      y        = 13
      col_span = 4
      row_span = 5
      title    = "Traffic sent back to primary"
      subtitle = "alert-failback-primary"
      query    = local.failback_kql
    },
  ]
}

resource "azurerm_portal_dashboard" "dr" {
  name                = local.portal_dashboard_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.shared_location
  tags = merge(var.tags, {
    "hidden-title" = local.portal_dashboard_title
  })

  dashboard_properties = jsonencode({
    lenses = {
      "0" = {
        order = 0
        parts = {
          for idx, part in concat(
            [local.dashboard_header_part, local.dashboard_unhealthy_part, local.dashboard_healthy_part, local.dashboard_watchdog_part, local.dashboard_alerts_part],
            local.dashboard_log_parts,
          ) : tostring(idx) => part
        }
      }
    }
    metadata = {
      model = {
        timeRange = {
          value = {
            relative = {
              duration = 4
              timeUnit = 1
            }
          }
          type = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
        }
        filterLocale = {
          value = "en-us"
        }
        filters = {
          value = {
            MsPortalFx_TimeRange = {
              model = {
                format      = "utc"
                granularity = "auto"
                relative    = "4h"
              }
              displayCache = {
                name  = "UTC Time"
                value = "Past 4 hours"
              }
            }
          }
        }
      }
    }
  })
}

locals {
  dashboard_header_part = {
    position = { x = 0, y = 0, colSpan = 12, rowSpan = 4 }
    metadata = {
      inputs = []
      type   = "Extension/HubsExtension/PartType/MarkdownPart"
      settings = {
        content = {
          settings = {
            content     = local.dashboard_header_md
            title       = ""
            subtitle    = ""
            markdownUri = null
          }
        }
      }
    }
  }

  dashboard_alerts_part = {
    position = { x = 6, y = 18, colSpan = 6, rowSpan = 5 }
    metadata = {
      inputs = []
      type   = "Extension/HubsExtension/PartType/MarkdownPart"
      settings = {
        content = {
          settings = {
            content     = local.dashboard_alerts_md
            title       = "Alerts"
            subtitle    = "Shared resource group"
            markdownUri = null
          }
        }
      }
    }
  }

  dashboard_unhealthy_part = {
    position = { x = 0, y = 9, colSpan = 6, rowSpan = 4 }
    metadata = local.dashboard_host_chart.unhealthy
  }

  dashboard_healthy_part = {
    position = { x = 6, y = 9, colSpan = 6, rowSpan = 4 }
    metadata = local.dashboard_host_chart.healthy
  }

  dashboard_host_chart = {
    unhealthy = local.dashboard_metric_chart["unhealthy"]
    healthy   = local.dashboard_metric_chart["healthy"]
  }

  dashboard_metric_chart = {
    for metric in [
      {
        key    = "unhealthy"
        name   = "UnhealthyHostCount"
        title  = "Unhealthy hosts"
        legend = "Probe down when this stays at 1"
      },
      {
        key    = "healthy"
        name   = "HealthyHostCount"
        title  = "Healthy hosts"
        legend = "Probe up when this stays at 1"
      },
      ] : metric.key => {
      inputs = [
        { name = "sharedTimeRange", isOptional = true },
        {
          name       = "options"
          isOptional = true
          value = {
            chart = {
              metrics = [
                {
                  resourceMetadata = { id = module.primary.appgw_id }
                  name             = metric.name
                  aggregationType  = 4
                  namespace        = "microsoft.network/applicationgateways"
                  metricVisualization = {
                    displayName         = "Primary"
                    resourceDisplayName = module.primary.appgw_name
                    color               = metric.key == "unhealthy" ? "#D13438" : "#107C10"
                  }
                },
                {
                  resourceMetadata = { id = module.secondary.appgw_id }
                  name             = metric.name
                  aggregationType  = 4
                  namespace        = "microsoft.network/applicationgateways"
                  metricVisualization = {
                    displayName         = "Secondary"
                    resourceDisplayName = module.secondary.appgw_name
                    color               = metric.key == "unhealthy" ? "#CA5010" : "#0078D4"
                  }
                },
              ]
              title     = metric.title
              titleKind = 2
              visualization = {
                chartType = 2
                legendVisualization = {
                  isVisible    = true
                  position     = 2
                  hideSubtitle = false
                }
                axisVisualization = {
                  x = { isVisible = true, axisType = 2 }
                  y = { isVisible = true, axisType = 1 }
                }
              }
              timespan = {
                relative    = { duration = 14400000 }
                showUTCTime = false
                grain       = 1
              }
            }
          }
        },
      ]
      type = "Extension/HubsExtension/PartType/MonitorChartPart"
      settings = {
        content = {
          options = {
            chart = {
              metrics = [
                {
                  resourceMetadata = { id = module.primary.appgw_id }
                  name             = metric.name
                  aggregationType  = 4
                  namespace        = "microsoft.network/applicationgateways"
                  metricVisualization = {
                    displayName         = "Primary"
                    resourceDisplayName = module.primary.appgw_name
                  }
                },
                {
                  resourceMetadata = { id = module.secondary.appgw_id }
                  name             = metric.name
                  aggregationType  = 4
                  namespace        = "microsoft.network/applicationgateways"
                  metricVisualization = {
                    displayName         = "Secondary"
                    resourceDisplayName = module.secondary.appgw_name
                  }
                },
              ]
              title     = metric.title
              titleKind = 2
              visualization = {
                chartType = 2
                legendVisualization = {
                  isVisible = true
                  position  = 2
                }
              }
            }
          }
        }
      }
      partHeader = {
        title    = metric.title
        subtitle = metric.legend
      }
    }
  }

  dashboard_watchdog_part = {
    position = { x = 0, y = 18, colSpan = 6, rowSpan = 5 }
    metadata = {
      inputs = [
        { name = "sharedTimeRange", isOptional = true },
        {
          name       = "options"
          isOptional = true
          value = {
            chart = {
              metrics = [
                {
                  resourceMetadata = { id = azurerm_application_insights.shared.id }
                  name             = "requests/count"
                  aggregationType  = 7
                  namespace        = "microsoft.insights/components"
                  metricVisualization = {
                    displayName         = "Runs"
                    resourceDisplayName = azurerm_application_insights.shared.name
                    color               = "#0078D4"
                  }
                },
                {
                  resourceMetadata = { id = azurerm_application_insights.shared.id }
                  name             = "exceptions/count"
                  aggregationType  = 7
                  namespace        = "microsoft.insights/components"
                  metricVisualization = {
                    displayName         = "Exceptions"
                    resourceDisplayName = azurerm_application_insights.shared.name
                    color               = "#D13438"
                  }
                },
              ]
              title     = "Watchdog"
              titleKind = 2
              visualization = {
                chartType = 2
                legendVisualization = {
                  isVisible = true
                  position  = 2
                }
                axisVisualization = {
                  x = { isVisible = true, axisType = 2 }
                  y = { isVisible = true, axisType = 1 }
                }
              }
              timespan = {
                relative    = { duration = 14400000 }
                showUTCTime = false
                grain       = 1
              }
            }
          }
        },
      ]
      type = "Extension/HubsExtension/PartType/MonitorChartPart"
      settings = {
        content = {
          options = {
            chart = {
              title     = "Watchdog"
              titleKind = 2
              visualization = {
                chartType = 2
              }
            }
          }
        }
      }
      partHeader = {
        title    = "Watchdog"
        subtitle = "Runs should be steady. Exceptions should stay at 0"
      }
    }
  }

  dashboard_log_parts = [
    for tile in local.dashboard_log_tiles : {
      position = {
        x       = tile.x
        y       = tile.y
        colSpan = tile.col_span
        rowSpan = tile.row_span
      }
      metadata = {
        inputs = [
          { name = "resourceTypeMode", isOptional = true },
          { name = "ComponentId", isOptional = true },
          {
            name       = "Scope"
            isOptional = true
            value = {
              resourceIds = [azurerm_log_analytics_workspace.shared.id]
            }
          },
          {
            name       = "PartId"
            isOptional = true
            value      = uuidv5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "${random_string.suffix.result}-${tile.key}")
          },
          { name = "Version", value = "2.0", isOptional = true },
          { name = "TimeRange", value = "PT4H", isOptional = true },
          { name = "DashboardId", isOptional = true },
          { name = "DraftRequestParameters", isOptional = true },
          { name = "Query", value = tile.query, isOptional = true },
          { name = "ControlType", value = "AnalyticsGrid", isOptional = true },
          { name = "SpecificChart", isOptional = true },
          { name = "PartTitle", value = tile.title, isOptional = true },
          { name = "PartSubTitle", value = tile.subtitle, isOptional = true },
          { name = "Dimensions", isOptional = true },
          { name = "LegendOptions", isOptional = true },
          { name = "IsQueryContainTimeRange", value = false, isOptional = true },
        ]
        type = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
        settings = {
          content = {
            Query                   = tile.query
            ControlType             = "AnalyticsGrid"
            PartTitle               = tile.title
            PartSubTitle            = tile.subtitle
            IsQueryContainTimeRange = false
          }
        }
        partHeader = {
          title    = tile.title
          subtitle = tile.subtitle
        }
      }
    }
  ]
}

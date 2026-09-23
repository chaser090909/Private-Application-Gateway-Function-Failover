// Shared-group portal dashboard. Mirrors terraform/dashboard.tf.
targetScope = 'resourceGroup'

param location string
param tags object
param suffix string
param workspaceId string
param appInsightsId string
param appInsightsName string
param primaryAppgwId string
param primaryAppgwName string
param primaryLocation string
param primaryAppgwPrivateIp string
param secondaryAppgwId string
param secondaryAppgwName string
param secondaryLocation string
param secondaryAppgwPrivateIp string
param dnsRecordName string
param privateDnsZoneName string
param healthProbePath string
param alertEmailAddress string

var title = 'Private Application Gateway DR'

var probeHealthKql = '''
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
'''

var secondaryUpKql = '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "SECONDARY_REGION_UP"
| summarize Signals = count(), LastSeen = max(TimeGenerated)
| extend Status = iff(LastSeen > ago(10m), "Up", "No recent signal")
| project Status, Signals, LastSeen
'''

var decisionsKql = '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "PROBE_HEALTH" or Message has "repointed" or Message has "FAILBACK_PRIMARY"
| project TimeGenerated, SeverityLevel, Message
| order by TimeGenerated desc
| take 40
'''

var failbackKql = '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "FAILBACK_PRIMARY"
| project TimeGenerated, Message
| order by TimeGenerated desc
| take 20
'''

var headerMd = '# Private Application Gateway DR\n\n**${dnsRecordName}.${privateDnsZoneName}** follows the healthy gateway. Probe `probe-aci` requests `${healthProbePath}` and matches HTTP 200-399.\n\n| | Primary | Secondary |\n| --- | --- | --- |\n| Region | ${primaryLocation} | ${secondaryLocation} |\n| Gateway | ${primaryAppgwName} | ${secondaryAppgwName} |\n| Private IP | ${primaryAppgwPrivateIp} | ${secondaryAppgwPrivateIp} |\n\nCharts are live metrics. Log tiles wait a few minutes for workspace ingestion. The page time range is the last 4 hours.'

var alertsMd = '## Alerts\n\n| Alert | When it fires | What it does |\n| --- | --- | --- |\n| alert-primary-probe-down | Primary unhealthy hosts at or above 1 | Emails and moves DNS to the secondary |\n| alert-aci-stopped | Primary container stop succeeds | Emails and moves DNS to the secondary |\n| alert-secondary-probe-down | Secondary unhealthy hosts at or above 1 | Emails. Traffic stays off a dead secondary |\n| alert-secondary-region-up | `SECONDARY_REGION_UP` is logged | Emails while Central US can serve |\n| alert-failback-primary | `FAILBACK_PRIMARY` is logged | Emails when DNS returns to the primary |\n| alert-watchdog-exceptions | The watchdog throws | Emails only. Does not call the webhook |\n\nFailover mail is **ag-appgw-dr-failover** to ${alertEmailAddress}. Status mail is **ag-appgw-dr-email**.'

func markdownPart(x int, y int, colSpan int, rowSpan int, content string, partTitle string, subtitle string) object => {
  position: {
    x: x
    y: y
    colSpan: colSpan
    rowSpan: rowSpan
  }
  metadata: {
    inputs: []
    type: 'Extension/HubsExtension/PartType/MarkdownPart'
    settings: {
      content: {
        settings: {
          content: content
          title: partTitle
          subtitle: subtitle
          markdownUri: null
        }
      }
    }
  }
}

func hostChart(metricName string, chartTitle string, subtitle string, primaryColor string, secondaryColor string, primaryId string, primaryName string, secondaryId string, secondaryName string) object => {
  inputs: [
    {
      name: 'sharedTimeRange'
      isOptional: true
    }
    {
      name: 'options'
      isOptional: true
      value: {
        chart: {
          metrics: [
            {
              resourceMetadata: {
                id: primaryId
              }
              name: metricName
              aggregationType: 4
              namespace: 'microsoft.network/applicationgateways'
              metricVisualization: {
                displayName: 'Primary'
                resourceDisplayName: primaryName
                color: primaryColor
              }
            }
            {
              resourceMetadata: {
                id: secondaryId
              }
              name: metricName
              aggregationType: 4
              namespace: 'microsoft.network/applicationgateways'
              metricVisualization: {
                displayName: 'Secondary'
                resourceDisplayName: secondaryName
                color: secondaryColor
              }
            }
          ]
          title: chartTitle
          titleKind: 2
          visualization: {
            chartType: 2
            legendVisualization: {
              isVisible: true
              position: 2
              hideSubtitle: false
            }
            axisVisualization: {
              x: {
                isVisible: true
                axisType: 2
              }
              y: {
                isVisible: true
                axisType: 1
              }
            }
          }
          timespan: {
            relative: {
              duration: 14400000
            }
            showUTCTime: false
            grain: 1
          }
        }
      }
    }
  ]
  type: 'Extension/HubsExtension/PartType/MonitorChartPart'
  settings: {
    content: {
      options: {
        chart: {
          title: chartTitle
          titleKind: 2
          visualization: {
            chartType: 2
          }
        }
      }
    }
  }
  partHeader: {
    title: chartTitle
    subtitle: subtitle
  }
}

func logPart(x int, y int, colSpan int, rowSpan int, partKey string, partTitle string, subtitle string, query string, scopeId string, workspace string, nameSuffix string) object => {
  position: {
    x: x
    y: y
    colSpan: colSpan
    rowSpan: rowSpan
  }
  metadata: {
    inputs: [
      {
        name: 'resourceTypeMode'
        isOptional: true
      }
      {
        name: 'ComponentId'
        isOptional: true
      }
      {
        name: 'Scope'
        isOptional: true
        value: {
          resourceIds: [
            workspace
          ]
        }
      }
      {
        name: 'PartId'
        isOptional: true
        value: guid(scopeId, nameSuffix, partKey)
      }
      {
        name: 'Version'
        value: '2.0'
        isOptional: true
      }
      {
        name: 'TimeRange'
        value: 'PT4H'
        isOptional: true
      }
      {
        name: 'DashboardId'
        isOptional: true
      }
      {
        name: 'DraftRequestParameters'
        isOptional: true
      }
      {
        name: 'Query'
        value: query
        isOptional: true
      }
      {
        name: 'ControlType'
        value: 'AnalyticsGrid'
        isOptional: true
      }
      {
        name: 'SpecificChart'
        isOptional: true
      }
      {
        name: 'PartTitle'
        value: partTitle
        isOptional: true
      }
      {
        name: 'PartSubTitle'
        value: subtitle
        isOptional: true
      }
      {
        name: 'Dimensions'
        isOptional: true
      }
      {
        name: 'LegendOptions'
        isOptional: true
      }
      {
        name: 'IsQueryContainTimeRange'
        value: false
        isOptional: true
      }
    ]
    type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
    settings: {
      content: {
        Query: query
        ControlType: 'AnalyticsGrid'
        PartTitle: partTitle
        PartSubTitle: subtitle
        IsQueryContainTimeRange: false
      }
    }
    partHeader: {
      title: partTitle
      subtitle: subtitle
    }
  }
}

var partList = [
  markdownPart(0, 0, 12, 4, headerMd, '', '')
  logPart(0, 4, 7, 5, 'probe-health', 'Probe health', 'Down when unhealthy hosts are above 0', probeHealthKql, resourceGroup().id, workspaceId, suffix)
  logPart(7, 4, 5, 5, 'secondary-up', 'Secondary region', 'Up while Central US can serve', secondaryUpKql, resourceGroup().id, workspaceId, suffix)
  {
    position: {
      x: 0
      y: 9
      colSpan: 6
      rowSpan: 4
    }
    metadata: hostChart('UnhealthyHostCount', 'Unhealthy hosts', 'Probe down when this stays at 1', '#D13438', '#CA5010', primaryAppgwId, primaryAppgwName, secondaryAppgwId, secondaryAppgwName)
  }
  {
    position: {
      x: 6
      y: 9
      colSpan: 6
      rowSpan: 4
    }
    metadata: hostChart('HealthyHostCount', 'Healthy hosts', 'Probe up when this stays at 1', '#107C10', '#0078D4', primaryAppgwId, primaryAppgwName, secondaryAppgwId, secondaryAppgwName)
  }
  logPart(0, 13, 8, 5, 'decisions', 'Probe decisions and DNS moves', 'Watchdog log', decisionsKql, resourceGroup().id, workspaceId, suffix)
  logPart(8, 13, 4, 5, 'failback', 'Traffic sent back to primary', 'alert-failback-primary', failbackKql, resourceGroup().id, workspaceId, suffix)
  {
    position: {
      x: 0
      y: 18
      colSpan: 6
      rowSpan: 5
    }
    metadata: {
      inputs: [
        {
          name: 'sharedTimeRange'
          isOptional: true
        }
        {
          name: 'options'
          isOptional: true
          value: {
            chart: {
              metrics: [
                {
                  resourceMetadata: {
                    id: appInsightsId
                  }
                  name: 'requests/count'
                  aggregationType: 7
                  namespace: 'microsoft.insights/components'
                  metricVisualization: {
                    displayName: 'Runs'
                    resourceDisplayName: appInsightsName
                    color: '#0078D4'
                  }
                }
                {
                  resourceMetadata: {
                    id: appInsightsId
                  }
                  name: 'exceptions/count'
                  aggregationType: 7
                  namespace: 'microsoft.insights/components'
                  metricVisualization: {
                    displayName: 'Exceptions'
                    resourceDisplayName: appInsightsName
                    color: '#D13438'
                  }
                }
              ]
              title: 'Watchdog'
              titleKind: 2
              visualization: {
                chartType: 2
                legendVisualization: {
                  isVisible: true
                  position: 2
                }
                axisVisualization: {
                  x: {
                    isVisible: true
                    axisType: 2
                  }
                  y: {
                    isVisible: true
                    axisType: 1
                  }
                }
              }
              timespan: {
                relative: {
                  duration: 14400000
                }
                showUTCTime: false
                grain: 1
              }
            }
          }
        }
      ]
      type: 'Extension/HubsExtension/PartType/MonitorChartPart'
      settings: {
        content: {
          options: {
            chart: {
              title: 'Watchdog'
              titleKind: 2
              visualization: {
                chartType: 2
              }
            }
          }
        }
      }
      partHeader: {
        title: 'Watchdog'
        subtitle: 'Runs should be steady. Exceptions should stay at 0'
      }
    }
  }
  markdownPart(6, 18, 6, 5, alertsMd, 'Alerts', 'Shared resource group')
]

resource dashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: guid(resourceGroup().id, title, suffix)
  location: location
  tags: union(tags, {
    'hidden-title': title
  })
  properties: {
    lenses: [
      {
        order: 0
        parts: json(string(partList))
      }
    ]
    metadata: {
      model: {
        timeRange: {
          value: {
            relative: {
              duration: 4
              timeUnit: 1
            }
          }
          type: 'MsPortalFx.Composition.Configuration.ValueTypes.TimeRange'
        }
        filterLocale: {
          value: 'en-us'
        }
        filters: {
          value: {
            MsPortalFx_TimeRange: {
              model: {
                format: 'utc'
                granularity: 'auto'
                relative: '4h'
              }
              displayCache: {
                name: 'UTC Time'
                value: 'Past 4 hours'
              }
            }
          }
        }
      }
    }
  }
}

output dashboardName string = title

// Action groups, alerts, and the probe-health workbook. Mirrors terraform/monitoring.tf.
targetScope = 'resourceGroup'

param location string
param tags object
param alertEmailAddress string
@secure()
param failoverWebhookUri string
param unhealthyHostThreshold int
param primaryAppgwId string
param primaryAppgwName string
param primaryLocation string
param secondaryAppgwId string
param secondaryAppgwName string
param secondaryLocation string
param primaryResourceGroupId string
param logAnalyticsWorkspaceId string
param dnsRecordName string
param privateDnsZoneName string
param healthProbePath string
param primaryAppgwPrivateIp string
param secondaryAppgwPrivateIp string

var emailReceivers = empty(alertEmailAddress) ? [] : [
  {
    name: 'ops'
    emailAddress: alertEmailAddress
    useCommonAlertSchema: true
  }
]

resource failover 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-appgw-dr-failover'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'agwdr'
    enabled: true
    emailReceivers: emailReceivers
    webhookReceivers: [
      {
        name: 'region-failover'
        serviceUri: failoverWebhookUri
        useCommonAlertSchema: true
      }
    ]
  }
}

resource notify 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmailAddress)) {
  name: 'ag-appgw-dr-email'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'agwemail'
    enabled: true
    emailReceivers: emailReceivers
  }
}

var emailOnlyGroupIds = empty(alertEmailAddress) ? [failover.id] : [notify!.id]

resource primaryProbeDown 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-primary-probe-down'
  location: 'global'
  tags: tags
  properties: {
    description: 'Primary custom probe on ${primaryAppgwName} is down (UnhealthyHostCount). Emails the action group and fails over to the secondary region.'
    severity: 1
    enabled: true
    scopes: [
      primaryAppgwId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT1M'
    targetResourceType: 'Microsoft.Network/applicationGateways'
    targetResourceRegion: primaryLocation
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'UnhealthyHostCount'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'UnhealthyHostCount'
          metricNamespace: 'Microsoft.Network/applicationGateways'
          operator: 'GreaterThanOrEqual'
          threshold: unhealthyHostThreshold
          timeAggregation: 'Average'
          dimensions: [
            {
              name: 'BackendSettingsPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: failover.id
      }
    ]
  }
}

resource secondaryProbeDown 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-secondary-probe-down'
  location: 'global'
  tags: tags
  properties: {
    description: 'Secondary custom probe on ${secondaryAppgwName} is down (UnhealthyHostCount). Emails the action group. The watchdog will not move traffic onto an unhealthy secondary.'
    severity: 1
    enabled: true
    scopes: [
      secondaryAppgwId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT1M'
    targetResourceType: 'Microsoft.Network/applicationGateways'
    targetResourceRegion: secondaryLocation
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'UnhealthyHostCount'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'UnhealthyHostCount'
          metricNamespace: 'Microsoft.Network/applicationGateways'
          operator: 'GreaterThanOrEqual'
          threshold: unhealthyHostThreshold
          timeAggregation: 'Average'
          dimensions: [
            {
              name: 'BackendSettingsPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: failover.id
      }
    ]
  }
}

resource containerStopped 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-aci-stopped'
  location: 'global'
  tags: tags
  properties: {
    scopes: [
      primaryResourceGroupId
    ]
    description: 'The primary backend container group was stopped. Emails the action group and fails over to the secondary region.'
    enabled: true
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.ContainerInstance/containerGroups/stop/action'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: failover.id
        }
      ]
    }
  }
}

resource watchdogFailing 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-watchdog-exceptions'
  location: location
  tags: tags
  properties: {
    displayName: 'alert-watchdog-exceptions'
    description: 'The watchdog is raising unhandled exceptions and may not be able to fail over.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: '''
AppExceptions
| where AppRoleName startswith "func-appgw-dr"
| summarize Exceptions = count()
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'Exceptions'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: emailOnlyGroupIds
    }
  }
}

resource secondaryRegionUp 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-secondary-region-up'
  location: location
  tags: tags
  properties: {
    displayName: 'alert-secondary-region-up'
    description: 'Secondary region is up. Emails the action group. Does not move DNS.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "SECONDARY_REGION_UP"
| summarize Events = count()
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'Events'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: emailOnlyGroupIds
    }
  }
}

resource failbackPrimary 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-failback-primary'
  location: location
  tags: tags
  properties: {
    displayName: 'alert-failback-primary'
    description: 'Traffic was sent back to the primary region. Emails the action group.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "FAILBACK_PRIMARY"
| summarize Events = count()
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'Events'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: emailOnlyGroupIds
    }
  }
}

var titleMarkdown = '# Private Application Gateway DR\n\n`${dnsRecordName}.${privateDnsZoneName}` resolves to whichever region is healthy.\n\nCustom probe `probe-aci` requests `${healthProbePath}` and matches HTTP 200-399. A host is unhealthy when that probe fails.\nWhen the primary probe is down, `alert-primary-probe-down` emails `${alertEmailAddress}` and the failover action group moves DNS to the secondary gateway.\n`alert-secondary-region-up` emails when Central US can serve. `alert-failback-primary` emails when traffic is sent back to East US.\n\n| Region | Gateway | Private frontend |\n| --- | --- | --- |\n| Primary (${primaryLocation}) | ${primaryAppgwName} | ${primaryAppgwPrivateIp} |\n| Secondary (${secondaryLocation}) | ${secondaryAppgwName} | ${secondaryAppgwPrivateIp} |'

var workbookData = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      name: 'title'
      content: {
        json: titleMarkdown
      }
    }
    {
      type: 3
      name: 'current-state'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 1
        title: 'Probe health by gateway'
        timeContext: {
          durationMs: 3600000
        }
        visualization: 'table'
        query: '''
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
'''
      }
    }
    {
      type: 3
      name: 'healthy-hosts'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 0
        title: 'Healthy hosts by gateway'
        timeContext: {
          durationMs: 14400000
        }
        visualization: 'timechart'
        query: '''
AzureMetrics
| where ResourceProvider =~ "MICROSOFT.NETWORK"
| where MetricName == "HealthyHostCount"
| extend Gateway = tostring(split(ResourceId, "/")[-1])
| extend Hosts = iff(isnull(Average), coalesce(Maximum, Total), Average)
| summarize HealthyHosts = avg(Hosts) by bin(TimeGenerated, 5m), Gateway
'''
      }
    }
    {
      type: 3
      name: 'unhealthy-hosts'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 0
        title: 'Unhealthy hosts by gateway (primary probe-down alert)'
        timeContext: {
          durationMs: 14400000
        }
        visualization: 'timechart'
        query: '''
AzureMetrics
| where ResourceProvider =~ "MICROSOFT.NETWORK"
| where MetricName == "UnhealthyHostCount"
| extend Gateway = tostring(split(ResourceId, "/")[-1])
| extend Hosts = iff(isnull(Average), coalesce(Maximum, Total), Average)
| summarize UnhealthyHosts = avg(Hosts) by bin(TimeGenerated, 5m), Gateway
'''
      }
    }
    {
      type: 3
      name: 'failover-decisions'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 0
        title: 'Probe decisions and DNS moves'
        timeContext: {
          durationMs: 14400000
        }
        visualization: 'table'
        query: '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "PROBE_HEALTH" or Message has "repointed" or Message has "FAILBACK_PRIMARY"
| project TimeGenerated, SeverityLevel, Message
| order by TimeGenerated desc
| take 200
'''
      }
    }
    {
      type: 3
      name: 'secondary-region-up'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 1
        title: 'Secondary region up (alert-secondary-region-up)'
        timeContext: {
          durationMs: 3600000
        }
        visualization: 'table'
        query: '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "SECONDARY_REGION_UP"
| summarize Signals = count(), LastSeen = max(TimeGenerated)
| extend Status = iff(LastSeen > ago(10m), "Up", "No recent signal")
| project Status, Signals, LastSeen
'''
      }
    }
    {
      type: 3
      name: 'failback-primary'
      content: {
        version: 'KqlItem/1.0'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        size: 0
        title: 'Traffic sent back to primary (alert-failback-primary)'
        timeContext: {
          durationMs: 14400000
        }
        visualization: 'table'
        query: '''
AppTraces
| where AppRoleName startswith "func-appgw-dr"
| where Message has "FAILBACK_PRIMARY"
| project TimeGenerated, Message
| order by TimeGenerated desc
| take 50
'''
      }
    }
  ]
  fallbackResourceIds: [
    logAnalyticsWorkspaceId
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'Private Application Gateway DR')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'Private Application Gateway DR'
    description: 'Custom probe health for both gateways, secondary-region-up, and failback to primary.'
    category: 'workbook'
    sourceId: toLower(logAnalyticsWorkspaceId)
    serializedData: string(workbookData)
  }
}

output failoverActionGroupName string = failover.name
output emailActionGroupName string = empty(alertEmailAddress) ? '' : notify!.name
output workbookName string = workbook.properties.displayName

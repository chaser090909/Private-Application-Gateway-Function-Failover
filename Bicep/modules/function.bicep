// Watchdog Function App. Mirrors terraform/function_app.tf.
//
// Code is not published from this template. After the deployment finishes, run
// the same command Terraform uses:
//   az functionapp deployment source config-zip --subscription <sub> --resource-group <shared> --name <function> --src <zip of terraform/function> --build-remote true
// WEBSITE_RUN_FROM_PACKAGE stays unset so that remote build installs requirements.txt.
targetScope = 'resourceGroup'

param location string
param tags object
param suffix string
param appServicePlanSku string
param pythonVersion string
param watchdogSchedule string
param sharedResourceGroupName string
param privateDnsZoneName string
param dnsRecordName string
param dnsRecordTtl int
param primaryResourceGroupName string
param primaryContainerGroupName string
param primaryAppgwName string
param primaryAppgwPrivateIp string
param secondaryResourceGroupName string
param secondaryContainerGroupName string
param secondaryAppgwName string
param secondaryAppgwPrivateIp string
param backendHealthyStates array
param appInsightsConnectionString string
@secure()
param appInsightsInstrumentationKey string

var storageAccountName = 'stagwdr${suffix}'
var planName = 'plan-appgw-dr-${suffix}'
var functionAppName = 'func-appgw-dr-${suffix}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: appServicePlanSku
    tier: 'Basic'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      alwaysOn: true
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableWorkerIndexing'
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsightsInstrumentationKey
        }
        {
          name: 'AZURE_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'WATCHDOG_SCHEDULE'
          value: watchdogSchedule
        }
        {
          name: 'DNS_RESOURCE_GROUP'
          value: sharedResourceGroupName
        }
        {
          name: 'DNS_ZONE_NAME'
          value: privateDnsZoneName
        }
        {
          name: 'DNS_RECORD_NAME'
          value: dnsRecordName
        }
        {
          name: 'DNS_RECORD_TTL'
          value: string(dnsRecordTtl)
        }
        {
          name: 'PRIMARY_RESOURCE_GROUP'
          value: primaryResourceGroupName
        }
        {
          name: 'PRIMARY_CONTAINER_GROUP'
          value: primaryContainerGroupName
        }
        {
          name: 'PRIMARY_APPGW_NAME'
          value: primaryAppgwName
        }
        {
          name: 'PRIMARY_APPGW_IP'
          value: primaryAppgwPrivateIp
        }
        {
          name: 'SECONDARY_RESOURCE_GROUP'
          value: secondaryResourceGroupName
        }
        {
          name: 'SECONDARY_CONTAINER_GROUP'
          value: secondaryContainerGroupName
        }
        {
          name: 'SECONDARY_APPGW_NAME'
          value: secondaryAppgwName
        }
        {
          name: 'SECONDARY_APPGW_IP'
          value: secondaryAppgwPrivateIp
        }
        {
          name: 'BACKEND_HEALTHY_STATES'
          value: join(backendHealthyStates, ',')
        }
      ]
    }
  }
}

var hostKeys = listKeys('${functionApp.id}/host/default', '2023-12-01')

output name string = functionApp.name
output principalId string = functionApp.identity.principalId
output defaultHostName string = functionApp.properties.defaultHostName
output storageAccountName string = storage.name
@secure()
output hostKey string = hostKeys.functionKeys.default

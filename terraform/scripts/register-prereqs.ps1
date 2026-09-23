<#
.SYNOPSIS
Registers the resource providers and the private Application Gateway feature flag
that terraform apply depends on.

.DESCRIPTION
A private-only Application Gateway (a v2 gateway with no public frontend) is
gated behind the EnableApplicationGatewayNetworkIsolation feature. Feature
registration is a subscription-level, one-time operation that Terraform does not
model, so run this once before the first apply.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId = $env:ARM_SUBSCRIPTION_ID,
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}

foreach ($provider in 'Microsoft.Network', 'Microsoft.ContainerInstance', 'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.Authorization') {
    Write-Host "Registering $provider"
    az provider register --namespace $provider --wait | Out-Null
}

Write-Host 'Registering EnableApplicationGatewayNetworkIsolation'
az feature register --namespace Microsoft.Network --name EnableApplicationGatewayNetworkIsolation | Out-Null

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $state = az feature show --namespace Microsoft.Network --name EnableApplicationGatewayNetworkIsolation --query properties.state -o tsv
    Write-Host "EnableApplicationGatewayNetworkIsolation=$state"
    if ($state -eq 'Registered') { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

if ($state -ne 'Registered') {
    throw "Feature did not reach Registered within $TimeoutMinutes minutes. Re-run this script before applying."
}

# Propagates the newly registered feature into the provider.
az provider register --namespace Microsoft.Network --wait | Out-Null
Write-Host 'Prerequisites are in place.'

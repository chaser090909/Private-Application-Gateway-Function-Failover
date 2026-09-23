<#
.SYNOPSIS
Validates the deployed stack and runs a failover drill against it.

.DESCRIPTION
Reads the Terraform outputs, so run it from the directory holding the state.

  validate  Inventory, backend pool health, current DNS target, alert status.
  failover  Stops the primary container and waits for the watchdog to repoint
            DNS at the secondary gateway.
  restore   Starts both containers and waits for the watchdog to fail back.
  webhook   Posts a synthetic alert to /api/region-failover and prints the
            watchdog's decision, without changing anything itself.
#>
[CmdletBinding()]
param(
    [ValidateSet('validate', 'failover', 'restore', 'webhook')]
    [string]$Action = 'validate',
    [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'

$tf = terraform output -json | ConvertFrom-Json
$groups = $tf.resource_groups.value
$primary = $tf.primary_appgw.value
$secondary = $tf.secondary_appgw.value
$fqdn = $tf.application_fqdn.value
$record, $zone = $fqdn -split '\.', 2

function Get-DnsTarget {
    az network private-dns record-set a show -g $groups.shared -z $zone -n $record `
        --query 'aRecords[0].ipv4Address' -o tsv
}

function Wait-ForDnsTarget([string]$Ip, [string]$Label) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $current = Get-DnsTarget
        Write-Host "DNS=$current"
        if ($current -eq $Ip) {
            Write-Host "PASS: $fqdn now resolves to the $Label region ($Ip)"
            return
        }
        Start-Sleep -Seconds 10
    }
    throw "DNS did not reach $Ip within $TimeoutMinutes minutes."
}

function Show-Inventory {
    Write-Host "`n== Resource groups =="
    $groups | Format-List

    foreach ($region in $primary, $secondary) {
        Write-Host "`n== $($region.name) ($($region.resource_group)) =="
        az container show -g $region.resource_group -n $region.backend_aci_name `
            --query '{Name:name,State:instanceView.state,IP:ipAddress.ip}' -o table
        az network application-gateway show -g $region.resource_group -n $region.name `
            --query '{Name:name,State:provisioningState,PrivateIP:frontendIPConfigurations[0].privateIPAddress}' -o table
        az network application-gateway show-backend-health -g $region.resource_group -n $region.name `
            --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address,Health:health}' -o table
    }

    Write-Host "`n== DNS =="
    Write-Host "$fqdn -> $(Get-DnsTarget)"

    Write-Host "`n== Alerts =="
    az monitor metrics alert list -g $groups.shared --query '[].{Name:name,Enabled:enabled,Severity:severity}' -o table
    az monitor activity-log alert list -g $groups.shared --query '[].{Name:name,Enabled:enabled}' -o table

    Write-Host "`n== Watchdog =="
    az functionapp function list -g $groups.shared -n $tf.watchdog.value.name `
        --query '[].{Function:name,Trigger:config.bindings[0].type}' -o table
}

switch ($Action) {
    'validate' { Show-Inventory }

    'failover' {
        Write-Host "Stopping $($primary.backend_aci_name) to take the primary region down"
        az container stop -g $primary.resource_group -n $primary.backend_aci_name -o none
        Wait-ForDnsTarget $secondary.private_ip 'secondary'
    }

    'restore' {
        Write-Host "Starting $($primary.backend_aci_name) so the watchdog can fail back"
        az container start -g $primary.resource_group -n $primary.backend_aci_name -o none
        az container start -g $secondary.resource_group -n $secondary.backend_aci_name -o none
        Wait-ForDnsTarget $primary.private_ip 'primary'
        Show-Inventory
    }

    'webhook' {
        # The watchdog re-reads live state rather than trusting the payload, so
        # this proves the endpoint works without asserting anything false.
        $uri = terraform output -raw failover_webhook_uri
        $body = @{
            schemaId = 'azureMonitorCommonAlertSchema'
            data     = @{ essentials = @{ alertRule = 'manual-drill'; monitorCondition = 'Fired'; alertTargetIDs = @() } }
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/json' |
            ConvertTo-Json -Depth 5
    }
}

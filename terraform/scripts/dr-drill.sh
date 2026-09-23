#!/usr/bin/env bash
# Validates the deployed stack and runs a failover drill against it.
# Reads the Terraform outputs, so run it from the directory holding the state.
#
#   ./dr-drill.sh validate   Inventory, backend health, DNS target, alert status.
#   ./dr-drill.sh failover   Stop the primary container, wait for DNS to move.
#   ./dr-drill.sh restore    Start both containers, wait for the watchdog to fail back.
#   ./dr-drill.sh webhook    Post a synthetic alert and print the decision.
set -Eeuo pipefail

ACTION="${1:-validate}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"

command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

TF=$(terraform output -json)
SHARED_RG=$(jq -r '.resource_groups.value.shared' <<<"$TF")
FQDN=$(jq -r '.application_fqdn.value' <<<"$TF")
RECORD="${FQDN%%.*}"
ZONE="${FQDN#*.}"
WATCHDOG=$(jq -r '.watchdog.value.name' <<<"$TF")

PRIMARY_RG=$(jq -r '.primary_appgw.value.resource_group' <<<"$TF")
PRIMARY_GW=$(jq -r '.primary_appgw.value.name' <<<"$TF")
PRIMARY_IP=$(jq -r '.primary_appgw.value.private_ip' <<<"$TF")
PRIMARY_ACI=$(jq -r '.primary_appgw.value.backend_aci_name' <<<"$TF")

SECONDARY_RG=$(jq -r '.secondary_appgw.value.resource_group' <<<"$TF")
SECONDARY_GW=$(jq -r '.secondary_appgw.value.name' <<<"$TF")
SECONDARY_IP=$(jq -r '.secondary_appgw.value.private_ip' <<<"$TF")
SECONDARY_ACI=$(jq -r '.secondary_appgw.value.backend_aci_name' <<<"$TF")

dns_target(){
  az network private-dns record-set a show -g "$SHARED_RG" -z "$ZONE" -n "$RECORD" \
    --query 'aRecords[0].ipv4Address' -o tsv
}

wait_for_dns(){
  local want=$1 label=$2 deadline
  deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
  while (( $(date +%s) < deadline )); do
    current=$(dns_target)
    echo "DNS=$current"
    if [[ "$current" == "$want" ]]; then
      echo "PASS: $FQDN now resolves to the $label region ($want)"
      return 0
    fi
    sleep 10
  done
  echo "DNS did not reach $want within ${TIMEOUT_MINUTES} minutes." >&2
  return 1
}

region_report(){
  local rg=$1 gw=$2 aci=$3
  echo; echo "== $gw ($rg) =="
  az container show -g "$rg" -n "$aci" --query '{Name:name,State:instanceView.state,IP:ipAddress.ip}' -o table
  az network application-gateway show -g "$rg" -n "$gw" \
    --query '{Name:name,State:provisioningState,PrivateIP:frontendIPConfigurations[0].privateIPAddress}' -o table
  az network application-gateway show-backend-health -g "$rg" -n "$gw" \
    --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address,Health:health}' -o table
}

inventory(){
  echo '== Resource groups =='
  jq -r '.resource_groups.value | to_entries[] | "\(.key): \(.value)"' <<<"$TF"

  region_report "$PRIMARY_RG" "$PRIMARY_GW" "$PRIMARY_ACI"
  region_report "$SECONDARY_RG" "$SECONDARY_GW" "$SECONDARY_ACI"

  echo; echo '== DNS =='
  echo "$FQDN -> $(dns_target)"

  echo; echo '== Alerts =='
  az monitor metrics alert list -g "$SHARED_RG" --query '[].{Name:name,Enabled:enabled,Severity:severity}' -o table
  az monitor activity-log alert list -g "$SHARED_RG" --query '[].{Name:name,Enabled:enabled}' -o table

  echo; echo '== Watchdog =='
  az functionapp function list -g "$SHARED_RG" -n "$WATCHDOG" \
    --query '[].{Function:name,Trigger:config.bindings[0].type}' -o table
}

case "$ACTION" in
  validate) inventory ;;

  failover)
    echo "Stopping $PRIMARY_ACI to take the primary region down"
    az container stop -g "$PRIMARY_RG" -n "$PRIMARY_ACI" -o none
    wait_for_dns "$SECONDARY_IP" secondary
    ;;

  restore)
    echo "Starting $PRIMARY_ACI so the watchdog can fail back"
    az container start -g "$PRIMARY_RG" -n "$PRIMARY_ACI" -o none
    az container start -g "$SECONDARY_RG" -n "$SECONDARY_ACI" -o none
    wait_for_dns "$PRIMARY_IP" primary
    inventory
    ;;

  webhook)
    # The watchdog re-reads live state rather than trusting the payload, so this
    # proves the endpoint works without asserting anything false.
    uri=$(terraform output -raw failover_webhook_uri)
    curl -sS -X POST "$uri" -H 'Content-Type: application/json' -d '{
      "schemaId": "azureMonitorCommonAlertSchema",
      "data": { "essentials": { "alertRule": "manual-drill", "monitorCondition": "Fired", "alertTargetIDs": [] } }
    }' | jq .
    ;;

  *) echo "Usage: $0 validate|failover|restore|webhook" >&2; exit 1 ;;
esac

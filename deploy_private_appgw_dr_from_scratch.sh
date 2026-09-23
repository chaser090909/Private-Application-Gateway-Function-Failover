#!/usr/bin/env bash
set -Eeuo pipefail

# Deploys the complete private Application Gateway DR lab from scratch.
# Idempotent: existing resources are reused where practical.
# Run in Azure Cloud Shell Bash:
#   chmod +x deploy_private_appgw_dr_from_scratch.sh
#   ./deploy_private_appgw_dr_from_scratch.sh deploy
#   ./deploy_private_appgw_dr_from_scratch.sh validate
#   ./deploy_private_appgw_dr_from_scratch.sh test
#   ./deploy_private_appgw_dr_from_scratch.sh restore
#   ./deploy_private_appgw_dr_from_scratch.sh delete

ACTION="${1:-deploy}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || true)}"
RG="${RG:-rg-private-appgw-dr-lab}"
EUS="${EUS:-eastus}"
CUS="${CUS:-centralus}"

TAG_BUSINESS_UNIT="${TAG_BUSINESS_UNIT:-OMP}"
TAG_COST_CENTER="${TAG_COST_CENTER:-CIS}"
TAG_ENV="${TAG_ENV:-Dev}"
TAG_OWNER="${TAG_OWNER:-abraham.arumbaka@ibm.com}"

VNET_EUS="${VNET_EUS:-vnet-eus-dr}"
VNET_CUS="${VNET_CUS:-vnet-cus-dr}"
VNET_EUS_PREFIX="10.10.0.0/16"
VNET_CUS_PREFIX="10.20.0.0/16"
SNET_AGW_EUS="snet-appgw-eus"; SNET_AGW_CUS="snet-appgw-cus"
SNET_ACI_EUS="snet-aci-eus"; SNET_ACI_CUS="snet-aci-cus"
SNET_CLIENT="snet-client"; SNET_FUNC="snet-func-dr"
PREFIX_AGW_EUS="10.10.1.0/24"; PREFIX_AGW_CUS="10.20.1.0/24"
PREFIX_ACI_EUS="10.10.2.0/24"; PREFIX_ACI_CUS="10.20.2.0/24"
PREFIX_CLIENT="10.10.10.0/24"; PREFIX_FUNC="10.20.50.0/27"

ACI_EUS="aci-eus-dr"; ACI_CUS="aci-cus-dr"
AGW_EUS="agw-eus-dr"; AGW_CUS="agw-cus-dr"
AGW_EUS_IP="10.10.1.10"; AGW_CUS_IP="10.20.1.10"
DNS_ZONE="lab.internal"; DNS_RECORD="app"
NAT_EUS="nat-aci-eus"; NAT_CUS="nat-aci-cus"
PIP_NAT_EUS="pip-nat-eus"; PIP_NAT_CUS="pip-nat-cus"
CLIENT_VM="vm-test"; CLIENT_USER="azureuser"

UNIQUE_FILE="$HOME/.private_appgw_dr_unique"
if [[ -f "$UNIQUE_FILE" ]]; then UNIQUE=$(cat "$UNIQUE_FILE"); else UNIQUE=$(openssl rand -hex 4); echo "$UNIQUE" > "$UNIQUE_FILE"; fi
FUNC_NAME="${FUNC_NAME:-func-private-agw-dr-$UNIQUE}"
STORAGE_NAME="${STORAGE_NAME:-stagwdr$UNIQUE}"
FUNCTION_DIR="$HOME/private-agw-dr-function"

log(){ printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
exists(){ az "$@" >/dev/null 2>&1; }

preflight(){
 command -v az >/dev/null || die "Azure CLI is required"
 command -v zip >/dev/null || die "zip is required"
 command -v python >/dev/null || die "python is required"
 [[ -n "$SUBSCRIPTION_ID" ]] || die "Run az login first"
 az account set --subscription "$SUBSCRIPTION_ID"
 log "Azure context"
 az account show --query '{Subscription:name,Id:id,Tenant:tenantId}' -o table
}

register_providers(){
 log "Registering resource providers and private Application Gateway feature"
 for p in Microsoft.Network Microsoft.ContainerInstance Microsoft.Web Microsoft.Storage Microsoft.App; do az provider register --namespace "$p" --wait; done
 az feature register --namespace Microsoft.Network --name EnableApplicationGatewayNetworkIsolation >/dev/null || true
 for _ in {1..60}; do
   state=$(az feature show --namespace Microsoft.Network --name EnableApplicationGatewayNetworkIsolation --query properties.state -o tsv 2>/dev/null || true)
   echo "EnableApplicationGatewayNetworkIsolation=$state"
   [[ "$state" == Registered ]] && break
   sleep 15
 done
 [[ "${state:-}" == Registered ]] || die "Network isolation feature did not register"
 az provider register --namespace Microsoft.Network --wait
}

ensure_rg(){
  if exists group show -n "$RG"; then
    az group update -n "$RG" \
      --tags businessUnit="$TAG_BUSINESS_UNIT" costCenter="$TAG_COST_CENTER" env="$TAG_ENV" owner="$TAG_OWNER" \
      -o none
  else
    az group create -n "$RG" -l "$EUS" \
      --tags businessUnit="$TAG_BUSINESS_UNIT" costCenter="$TAG_COST_CENTER" env="$TAG_ENV" owner="$TAG_OWNER" \
      -o none
  fi
}
ensure_vnet(){ local n=$1 l=$2 p=$3; exists network vnet show -g "$RG" -n "$n" || az network vnet create -g "$RG" -n "$n" -l "$l" --address-prefixes "$p" -o none; }
ensure_subnet(){
 local v=$1 n=$2 p=$3 delegation=${4:-}
 if ! exists network vnet subnet show -g "$RG" --vnet-name "$v" -n "$n"; then
   if [[ -n "$delegation" ]]; then az network vnet subnet create -g "$RG" --vnet-name "$v" -n "$n" --address-prefixes "$p" --delegations "$delegation" -o none
   else az network vnet subnet create -g "$RG" --vnet-name "$v" -n "$n" --address-prefixes "$p" -o none; fi
 fi
}

networking(){
 log "Creating VNets and delegated subnets"
 ensure_vnet "$VNET_EUS" "$EUS" "$VNET_EUS_PREFIX"; ensure_vnet "$VNET_CUS" "$CUS" "$VNET_CUS_PREFIX"
 ensure_subnet "$VNET_EUS" "$SNET_AGW_EUS" "$PREFIX_AGW_EUS" Microsoft.Network/applicationGateways
 ensure_subnet "$VNET_CUS" "$SNET_AGW_CUS" "$PREFIX_AGW_CUS" Microsoft.Network/applicationGateways
 ensure_subnet "$VNET_EUS" "$SNET_ACI_EUS" "$PREFIX_ACI_EUS" Microsoft.ContainerInstance/containerGroups
 ensure_subnet "$VNET_CUS" "$SNET_ACI_CUS" "$PREFIX_ACI_CUS" Microsoft.ContainerInstance/containerGroups
 ensure_subnet "$VNET_EUS" "$SNET_CLIENT" "$PREFIX_CLIENT"
 ensure_subnet "$VNET_CUS" "$SNET_FUNC" "$PREFIX_FUNC" Microsoft.App/environments

 id1=$(az network vnet show -g "$RG" -n "$VNET_EUS" --query id -o tsv); id2=$(az network vnet show -g "$RG" -n "$VNET_CUS" --query id -o tsv)
 exists network vnet peering show -g "$RG" --vnet-name "$VNET_EUS" -n peer-eus-to-cus || az network vnet peering create -g "$RG" --vnet-name "$VNET_EUS" -n peer-eus-to-cus --remote-vnet "$id2" --allow-vnet-access -o none
 exists network vnet peering show -g "$RG" --vnet-name "$VNET_CUS" -n peer-cus-to-eus || az network vnet peering create -g "$RG" --vnet-name "$VNET_CUS" -n peer-cus-to-eus --remote-vnet "$id1" --allow-vnet-access -o none
}

nat(){
 log "Creating NAT Gateways for ACI image pulls"
 for spec in "$PIP_NAT_EUS $NAT_EUS $EUS $VNET_EUS $SNET_ACI_EUS" "$PIP_NAT_CUS $NAT_CUS $CUS $VNET_CUS $SNET_ACI_CUS"; do
   read -r pip nat loc vnet subnet <<< "$spec"
   exists network public-ip show -g "$RG" -n "$pip" || az network public-ip create -g "$RG" -n "$pip" -l "$loc" --sku Standard --allocation-method Static -o none
   exists network nat gateway show -g "$RG" -n "$nat" || az network nat gateway create -g "$RG" -n "$nat" -l "$loc" --public-ip-addresses "$pip" --idle-timeout 10 -o none
   az network vnet subnet update -g "$RG" --vnet-name "$vnet" -n "$subnet" --nat-gateway "$nat" -o none
 done
}

deploy_aci(){
 local n=$1 loc=$2 vnet=$3 subnet=$4
 if ! exists container show -g "$RG" -n "$n"; then
   log "Creating $n"
   az container create -g "$RG" -n "$n" -l "$loc" --image mcr.microsoft.com/azuredocs/aci-helloworld --os-type Linux --cpu 1 --memory 1 --ports 80 --ip-address Private --vnet "$vnet" --subnet "$subnet" -o none
 fi
 state=$(az container show -g "$RG" -n "$n" --query instanceView.state -o tsv)
 [[ "$state" == Running ]] || az container start -g "$RG" -n "$n" -o none
}

create_appgw(){
 local n=$1 loc=$2 vnet=$3 subnet=$4 private_ip=$5 backend_ip=$6
 if exists network application-gateway show -g "$RG" -n "$n"; then log "Reusing $n"; return; fi
 log "Creating private-only Application Gateway $n; this can take 10-20 minutes"
 az network application-gateway create -g "$RG" -n "$n" -l "$loc" --sku Standard_v2 --capacity 1 --vnet-name "$vnet" --subnet "$subnet" --private-ip-address "$private_ip" --public-ip-address "" --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http --servers "$backend_ip" --priority 100 -o none
}

backends_and_gateways(){
 deploy_aci "$ACI_EUS" "$EUS" "$VNET_EUS" "$SNET_ACI_EUS"; deploy_aci "$ACI_CUS" "$CUS" "$VNET_CUS" "$SNET_ACI_CUS"
 ACI_EUS_IP=$(az container show -g "$RG" -n "$ACI_EUS" --query ipAddress.ip -o tsv); ACI_CUS_IP=$(az container show -g "$RG" -n "$ACI_CUS" --query ipAddress.ip -o tsv)
 [[ -n "$ACI_EUS_IP" && -n "$ACI_CUS_IP" ]] || die "ACI private IP not available"
 create_appgw "$AGW_EUS" "$EUS" "$VNET_EUS" "$SNET_AGW_EUS" "$AGW_EUS_IP" "$ACI_EUS_IP"
 create_appgw "$AGW_CUS" "$CUS" "$VNET_CUS" "$SNET_AGW_CUS" "$AGW_CUS_IP" "$ACI_CUS_IP"
}

dns(){
 log "Creating Private DNS"
 exists network private-dns zone show -g "$RG" -n "$DNS_ZONE" || az network private-dns zone create -g "$RG" -n "$DNS_ZONE" -o none
 id1=$(az network vnet show -g "$RG" -n "$VNET_EUS" --query id -o tsv); id2=$(az network vnet show -g "$RG" -n "$VNET_CUS" --query id -o tsv)
 exists network private-dns link vnet show -g "$RG" -z "$DNS_ZONE" -n link-eus || az network private-dns link vnet create -g "$RG" -z "$DNS_ZONE" -n link-eus -v "$id1" -e false -o none
 exists network private-dns link vnet show -g "$RG" -z "$DNS_ZONE" -n link-cus || az network private-dns link vnet create -g "$RG" -z "$DNS_ZONE" -n link-cus -v "$id2" -e false -o none
 exists network private-dns record-set a show -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" || az network private-dns record-set a create -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --ttl 30 -o none
 az network private-dns record-set a update -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --set ttl=30 --set "a_records=[{\"ipv4Address\":\"$AGW_EUS_IP\"}]" -o none
}

client_vm(){
 log "Creating optional test VM"
 if ! exists vm show -g "$RG" -n "$CLIENT_VM"; then
   az vm create -g "$RG" -n "$CLIENT_VM" -l "$EUS" --image Ubuntu2204 --size Standard_B2s_v2 --vnet-name "$VNET_EUS" --subnet "$SNET_CLIENT" --admin-username "$CLIENT_USER" --generate-ssh-keys --public-ip-sku Standard -o none || log "VM creation skipped or failed due to quota. Lab resources remain usable."
 fi
}

write_function(){
 mkdir -p "$FUNCTION_DIR"
 cat > "$FUNCTION_DIR/host.json" <<'HOST'
{"version":"2.0"}
HOST
 cat > "$FUNCTION_DIR/requirements.txt" <<'REQ'
azure-functions
azure-identity
azure-mgmt-privatedns
requests
REQ
 cat > "$FUNCTION_DIR/function_app.py" <<'PY'
import logging, os
import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.privatedns import PrivateDnsManagementClient
from azure.mgmt.privatedns.models import ARecord, RecordSet
app=func.FunctionApp()
sub=os.environ['AZURE_SUBSCRIPTION_ID']; rg=os.environ['DNS_RESOURCE_GROUP']; zone=os.environ['DNS_ZONE_NAME']; record=os.environ['DNS_RECORD_NAME']
eus_url=os.environ['EUS_HEALTH_URL']; cus_url=os.environ['CUS_HEALTH_URL']; eus_ip=os.environ['EUS_APPGW_IP']; cus_ip=os.environ['CUS_APPGW_IP']
dns=PrivateDnsManagementClient(DefaultAzureCredential(),sub)
def probe(region,url):
 try:
  r=requests.get(url,timeout=5,allow_redirects=False,headers={'Connection':'close'}); ok=200<=r.status_code<400; logging.info('%s status=%s healthy=%s',region,r.status_code,ok); return ok
 except requests.RequestException as exc: logging.warning('%s failed: %s',region,exc); return False
def ips():
 rs=dns.record_sets.get(rg,zone,'A',record); return sorted(x.ipv4_address for x in (rs.a_records or []))
def set_target(ip,region):
 old=ips()
 if old==[ip]: return
 dns.record_sets.create_or_update(rg,zone,'A',record,RecordSet(ttl=30,a_records=[ARecord(ipv4_address=ip)])); logging.warning('DNS %s -> %s (%s)',old,ip,region)
@app.timer_trigger(schedule='%TIMER_SCHEDULE%',arg_name='timer',run_on_startup=False,use_monitor=True)
def private_appgw_dr_controller(timer: func.TimerRequest):
 eus=probe('EUS',eus_url); cus=probe('CUS',cus_url); logging.info('EUS=%s CUS=%s DNS=%s',eus,cus,ips())
 if eus: set_target(eus_ip,'EUS')
 elif cus: set_target(cus_ip,'CUS')
 else: logging.critical('Both regions unavailable; DNS unchanged')
PY
 python -m py_compile "$FUNCTION_DIR/function_app.py"
}

function_app(){
 log "Creating and deploying Function App"
 exists storage account show -g "$RG" -n "$STORAGE_NAME" || az storage account create -g "$RG" -n "$STORAGE_NAME" -l "$CUS" --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --min-tls-version TLS1_2 -o none
 if ! exists functionapp show -g "$RG" -n "$FUNC_NAME"; then
   vid=$(az network vnet show -g "$RG" -n "$VNET_CUS" --query id -o tsv)
   az functionapp create -g "$RG" -n "$FUNC_NAME" --storage-account "$STORAGE_NAME" --flexconsumption-location "$CUS" --runtime python --runtime-version 3.11 --vnet "$vid" --subnet "$SNET_FUNC" -o none
 fi
 az functionapp identity assign -g "$RG" -n "$FUNC_NAME" -o none
 pid=$(az functionapp identity show -g "$RG" -n "$FUNC_NAME" --query principalId -o tsv); zid=$(az network private-dns zone show -g "$RG" -n "$DNS_ZONE" --query id -o tsv)
 az role assignment create --assignee-object-id "$pid" --assignee-principal-type ServicePrincipal --role "Private DNS Zone Contributor" --scope "$zid" -o none 2>/dev/null || true
 az functionapp config appsettings set -g "$RG" -n "$FUNC_NAME" --settings "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID" "DNS_RESOURCE_GROUP=$RG" "DNS_ZONE_NAME=$DNS_ZONE" "DNS_RECORD_NAME=$DNS_RECORD" "EUS_HEALTH_URL=http://$AGW_EUS_IP/" "CUS_HEALTH_URL=http://$AGW_CUS_IP/" "EUS_APPGW_IP=$AGW_EUS_IP" "CUS_APPGW_IP=$AGW_CUS_IP" 'TIMER_SCHEDULE=*/30 * * * * *' -o none
 write_function
 (cd "$FUNCTION_DIR"; rm -f function.zip; zip -q function.zip host.json requirements.txt function_app.py)
 az functionapp deployment source config-zip -g "$RG" -n "$FUNC_NAME" --src "$FUNCTION_DIR/function.zip" --build-remote true
 az functionapp restart -g "$RG" -n "$FUNC_NAME"
}

validate(){
 log "Inventory"
 az container list -g "$RG" --query '[].{Name:name,Location:location,State:instanceView.state,IP:ipAddress.ip}' -o table
 az network application-gateway list -g "$RG" --query '[].{Name:name,State:provisioningState,PrivateIP:frontendIPConfigurations[0].privateIPAddress}' -o table
 az network private-dns record-set a show -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --query '{TTL:ttl,IPs:a_records[].ipv4Address}' -o yaml
 az functionapp function list -g "$RG" -n "$FUNC_NAME" --query '[].{Function:name,Trigger:config.bindings[0].type}' -o table || true
 log "Backend health"
 for gw in "$AGW_EUS" "$AGW_CUS"; do az network application-gateway show-backend-health -g "$RG" -n "$gw" --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address,Health:health}' -o table || true; done
}

test_dr(){
 log "Resetting normal state"
 az container start -g "$RG" -n "$ACI_EUS" -o none || true; az container start -g "$RG" -n "$ACI_CUS" -o none || true
 az network private-dns record-set a update -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --set ttl=30 --set "a_records=[{\"ipv4Address\":\"$AGW_EUS_IP\"}]" -o none
 log "Stopping EUS ACI"
 az container stop -g "$RG" -n "$ACI_EUS" -o none
 for _ in {1..60}; do ip=$(az network private-dns record-set a show -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --query 'a_records[0].ipv4Address' -o tsv); echo "DNS=$ip"; [[ "$ip" == "$AGW_CUS_IP" ]] && { log "PASS: failover to CUS"; return; }; sleep 10; done
 die "DNS did not switch to CUS"
}

restore(){ az container start -g "$RG" -n "$ACI_EUS" -o none || true; az container start -g "$RG" -n "$ACI_CUS" -o none || true; az network private-dns record-set a update -g "$RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --set ttl=30 --set "a_records=[{\"ipv4Address\":\"$AGW_EUS_IP\"}]" -o none; validate; }

deploy_all(){ preflight; register_providers; ensure_rg; networking; nat; backends_and_gateways; dns; client_vm; function_app; sleep 60; validate; log "Deployment complete. Function=$FUNC_NAME"; }

case "$ACTION" in
 deploy) deploy_all ;;
 validate) preflight; validate ;;
 test) preflight; test_dr ;;
 restore) preflight; restore ;;
 delete) preflight; az group delete -n "$RG" --yes --no-wait; log "Delete started for $RG" ;;
 *) die "Usage: $0 deploy|validate|test|restore|delete" ;;
esac

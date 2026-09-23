#!/usr/bin/env bash
# Registers the resource providers and the private Application Gateway feature
# flag that terraform apply depends on.
#
# A private-only Application Gateway (a v2 gateway with no public frontend) is
# gated behind the EnableApplicationGatewayNetworkIsolation feature. Feature
# registration is a subscription-level, one-time operation that Terraform does
# not model, so run this once before the first apply.
set -Eeuo pipefail

SUBSCRIPTION_ID="${1:-${ARM_SUBSCRIPTION_ID:-}}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-15}"

[[ -n "$SUBSCRIPTION_ID" ]] && az account set --subscription "$SUBSCRIPTION_ID"

for provider in Microsoft.Network Microsoft.ContainerInstance Microsoft.Web \
  Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights Microsoft.Authorization; do
  echo "Registering $provider"
  az provider register --namespace "$provider" --wait
done

echo 'Registering EnableApplicationGatewayNetworkIsolation'
az feature register --namespace Microsoft.Network --name EnableApplicationGatewayNetworkIsolation >/dev/null

state=""
deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
while (( $(date +%s) < deadline )); do
  state=$(az feature show --namespace Microsoft.Network \
    --name EnableApplicationGatewayNetworkIsolation --query properties.state -o tsv)
  echo "EnableApplicationGatewayNetworkIsolation=$state"
  [[ "$state" == Registered ]] && break
  sleep 15
done

if [[ "$state" != Registered ]]; then
  echo "Feature did not reach Registered within ${TIMEOUT_MINUTES} minutes. Re-run before applying." >&2
  exit 1
fi

# Propagates the newly registered feature into the provider.
az provider register --namespace Microsoft.Network --wait
echo 'Prerequisites are in place.'

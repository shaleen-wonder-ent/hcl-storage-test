#!/usr/bin/env bash
set -euo pipefail
RG=${1:?Usage: $0 <resource-group> [subscription-id]}
SUB=${2:-}
[[ -n "$SUB" ]] && az account set --subscription "$SUB"

echo "==> Deleting resource group $RG (no-wait)"
az group delete --name "$RG" --yes --no-wait
echo "==> Submitted. Use 'az group show -n $RG' to track."

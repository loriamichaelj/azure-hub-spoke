#!/bin/bash
set -euo pipefail   # exit on error, undefined var, or pipe failure

# --- Config ---
LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-hubspoke-lab}"

echo "==> Creating resource group $RG in $LOCATION"
az group create -n "$RG" -l "$LOCATION" \
  --tags project=hubspoke-lab env=lab owner="$USER" >/dev/null

echo "==> Creating vnet-hub"
# ... and so on
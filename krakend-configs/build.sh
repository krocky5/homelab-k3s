#!/bin/bash
set -e

ENV=$1

if [ -z "$ENV" ]; then
  echo "Usage: $0 <environment>"
  exit 1
fi

CONFIG_DIR="krakend-configs/$ENV"

echo "Building KrakenD configuration for $ENV..."

# The endpoints.json from Vault is already {"endpoints": [...]}
# So we just merge the two objects
jq -s '.[0] * .[1]' \
  "$CONFIG_DIR/settings.json" \
  "$CONFIG_DIR/endpoints.json" \
  > "$CONFIG_DIR/krakend.json"

echo "✓ Configuration built: $CONFIG_DIR/krakend.json"

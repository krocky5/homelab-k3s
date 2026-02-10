#!/bin/bash
set -e

ENV=${1:-dev}

echo "Building KrakenD config for environment: $ENV"

# Check if FC_ENABLE is set
if [ -z "$FC_ENABLE" ]; then
  export FC_ENABLE=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/$ENV"
OUTPUT_FILE="$SCRIPT_DIR/$ENV/krakend.json"

# Validate required files exist
if [ ! -f "$CONFIG_DIR/settings.json" ]; then
  echo "Error: settings.json not found in $CONFIG_DIR"
  exit 1
fi

if [ ! -f "$CONFIG_DIR/endpoints.json" ]; then
  echo "Error: endpoints.json not found in $CONFIG_DIR"
  exit 1
fi

# Merge settings and endpoints
echo "Merging configuration files..."
jq -s '.[0] * .[1]' "$CONFIG_DIR/settings.json" "$CONFIG_DIR/endpoints.json" > "$OUTPUT_FILE"

echo "✓ Configuration built successfully: $OUTPUT_FILE"

# Validate the configuration if krakend is available
if command -v krakend &> /dev/null; then
  echo "Validating configuration..."
  krakend check -c "$OUTPUT_FILE" -d
  echo "✓ Configuration is valid"
else
  echo "⚠ krakend command not found, skipping validation"
fi

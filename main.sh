#!/usr/bin/env bash

# Environment Flags
set -o errexit  # Exit when a command fails
set -o pipefail # Catch mysqldump fails
set -o nounset  # Exit when using undeclared variables

# Configuration directory
CONFIG_DIR="./.playwright-mcp"
PORT_FILE="${CONFIG_DIR}/port.txt"
OUTPUT_DIR="${CONFIG_DIR}/output"

# Function to find an available port starting from a given port
find_available_port() {
  local start_port=$1
  local port=$start_port
  
  while lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; do
    port=$((port + 1))
  done
  
  echo "$port"
}

# Function to ensure config directory exists
ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
}

# Global array for parsed arguments
PARSED_ARGS=()

# Parse arguments and set defaults
parse_arguments() {
  local port_set=false
  local output_dir_set=false
  local cdp_endpoint_set=false
  
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port)
        REMOTE_DEBUGGING_PORT="$2"
        port_set=true
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="$2"
        output_dir_set=true
        PARSED_ARGS+=("--output-dir" "$2")
        shift 2
        ;;
      --cdp-endpoint)
        PARSED_ARGS+=("--cdp-endpoint" "$2")
        cdp_endpoint_set=true
        shift 2
        ;;
      *)
        PARSED_ARGS+=("$1")
        shift
        ;;
    esac
  done
  
  # Set default output-dir if not provided
  if [ "$output_dir_set" = false ]; then
    PARSED_ARGS+=("--output-dir" "$OUTPUT_DIR")
  fi
  
  # Handle port and cdp-endpoint logic
  if [ "$port_set" = true ]; then
    # Port explicit via --port; skip port.txt read/write
    export REMOTE_DEBUGGING_PORT
  else
    ensure_config_dir
    if [ ! -f "$PORT_FILE" ]; then
      REMOTE_DEBUGGING_PORT=$(find_available_port 9222)
      echo "$REMOTE_DEBUGGING_PORT" > "$PORT_FILE"
    else
      REMOTE_DEBUGGING_PORT=$(cat "$PORT_FILE")
    fi
    export REMOTE_DEBUGGING_PORT
  fi
  
  # Set default cdp-endpoint if not provided
  if [ "$cdp_endpoint_set" = false ]; then
    PARSED_ARGS+=("--cdp-endpoint" "http://localhost:${REMOTE_DEBUGGING_PORT}")
  fi
}

# Start simple-browser
start_simple_browser() {
  echo "Starting simple-browser on port $REMOTE_DEBUGGING_PORT..." >/dev/null
  npx --yes simple-browser@latest start --browser chrome --port "$REMOTE_DEBUGGING_PORT" >/dev/null 2>&1
}

# Parse arguments and start simple-browser (suppress stdout)
{
  parse_arguments "$@"
  start_simple_browser
} >/dev/null

# Start the MCP server with parsed arguments
npx \
  --yes \
  --no-progress \
  @playwright/mcp \
  -- \
  "${PARSED_ARGS[@]}"

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
# Whether the user opted into the proxy front-end (off by default).
USE_PROXY=false

# Parse arguments and set defaults
parse_arguments() {
  local port_set=false
  local output_dir_set=false
  local cdp_endpoint_set=false
  local snapshot_mode_set=false
  local image_responses_set=false

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
      --snapshot-mode)
        snapshot_mode_set=true
        PARSED_ARGS+=("$1" "$2")
        shift 2
        ;;
      --image-responses)
        image_responses_set=true
        PARSED_ARGS+=("$1" "$2")
        shift 2
        ;;
      --proxy)
        # Opt into the proxy front-end (get_page_text, find, filtered console/network).
        USE_PROXY=true
        shift
        ;;
      --no-proxy)
        USE_PROXY=false
        shift
        ;;
      *)
        PARSED_ARGS+=("$1")
        shift
        ;;
    esac
  done

  # Env override: PW_MCP_PROXY=1 enables proxy even without --proxy flag.
  if [ "${PW_MCP_PROXY:-}" = "1" ]; then
    USE_PROXY=true
  fi

  # Performance defaults — see README. Both override-able by caller.
  if [ "$snapshot_mode_set" = false ]; then
    PARSED_ARGS+=("--snapshot-mode" "none")
  fi
  if [ "$image_responses_set" = false ]; then
    PARSED_ARGS+=("--image-responses" "omit")
  fi
  
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

# Start the MCP server with parsed arguments.
# Use the locally-installed (patched) @playwright/mcp instead of `npx --yes`
# so the postinstall patch-package step takes effect.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_CLI="${SCRIPT_DIR}/node_modules/@playwright/mcp/cli.js"
PROXY="${SCRIPT_DIR}/src/proxy.mjs"
if [ ! -f "$MCP_CLI" ]; then
  echo "playwright-browser-mcp: missing $MCP_CLI — did you run 'npm install'?" >&2
  exit 1
fi
if [ "$USE_PROXY" = "true" ] && [ -f "$PROXY" ]; then
  export PW_MCP_CLI="$MCP_CLI"
  exec node "$PROXY" "${PARSED_ARGS[@]}"
fi
exec node "$MCP_CLI" "${PARSED_ARGS[@]}"

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
# Proxy front-end is on by default. Disable with --no-proxy or PW_MCP_NO_PROXY=1.
USE_PROXY=true

# Resolve real script path (npx installs us via a symlink in node_modules/.bin).
resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}
SCRIPT_DIR="$(resolve_script_dir)"
# Use Node's resolver so flattened npm layouts (where @playwright/mcp ends up
# in a parent node_modules/) work.
MCP_CLI="$(node -e "
const p = require.resolve('@playwright/mcp/package.json', { paths: [process.argv[1]] });
process.stdout.write(require('path').join(require('path').dirname(p), 'cli.js'));
" "$SCRIPT_DIR" 2>/dev/null || true)"
PROXY="${SCRIPT_DIR}/src/proxy.mjs"
PKG_JSON="${SCRIPT_DIR}/package.json"
PKG_VERSION="$(node -p "require('$PKG_JSON').version" 2>/dev/null || echo "unknown")"

# Intercept --help / -h: print our wrapper's help, then upstream's help, then exit.
for arg in "$@"; do
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    cat <<EOF
playwright-browser-mcp v${PKG_VERSION}

Lightweight wrapper around @playwright/mcp. Starts Chrome via simple-browser,
auto-manages the CDP port, and (by default) fronts the MCP server with a small
proxy that adds faster page-reading tools.

Usage:
  playwright-browser-mcp [wrapper flags] [-- @playwright/mcp flags...]

Wrapper flags (handled here, not forwarded):
  --port <N>            Chrome CDP debugging port. Auto-detected from 9222 and
                        persisted to .playwright-mcp/port.txt.
  --output-dir <path>   Directory for screenshots/artifacts. Default
                        .playwright-mcp/output.
  --cdp-endpoint <url>  Override CDP endpoint (skips port auto-detect).
  --snapshot-mode <m>   Default "none" (skip the accessibility-tree walk per
                        tool response — see README). Pass "full" to restore
                        upstream behavior.
  --image-responses <m> Default "omit" (drop screenshot PNG bytes from MCP
                        responses). Pass "allow" to inline them.
  --proxy               Force the proxy front-end on (default).
  --no-proxy            Disable the proxy and serve @playwright/mcp directly.
                        Drops get_page_text, find, filtered console/network.

Environment:
  PW_MCP_PROXY=1        Force proxy on (same as --proxy).
  PW_MCP_NO_PROXY=1     Force proxy off (same as --no-proxy).

Proxy tools (on by default):
  get_page_text         Return document.body.innerText (truncated). PREFER over
                        browser_snapshot for read-only tasks — 5-20x faster on
                        heavy DOMs, no accessibility-tree walk.
  find                  Locate elements by visible text (and optional ARIA
                        role). Returns up to 10 leaf-prefer matches with CSS
                        selector. PREFER over browser_snapshot when the
                        element's text/role is known.
  browser_console_messages
                        Augmented with pattern (regex) and onlyErrors filters.
                        Server-side filtering — cuts response tokens.
  browser_network_requests
                        Augmented with urlPattern (regex) filter. Server-side.

All other arguments are passed through to @playwright/mcp.

==============================================================================
Upstream @playwright/mcp help:
==============================================================================
EOF
    if [ -n "$MCP_CLI" ] && [ -f "$MCP_CLI" ]; then
      node "$MCP_CLI" --help
    else
      echo "(could not locate @playwright/mcp to show its --help — run 'npm install')" >&2
    fi
    exit 0
  fi
done

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

  # Env overrides. PW_MCP_PROXY=1 forces on; PW_MCP_NO_PROXY=1 forces off.
  if [ "${PW_MCP_PROXY:-}" = "1" ]; then
    USE_PROXY=true
  fi
  if [ "${PW_MCP_NO_PROXY:-}" = "1" ]; then
    USE_PROXY=false
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
if [ -z "$MCP_CLI" ] || [ ! -f "$MCP_CLI" ]; then
  echo "playwright-browser-mcp: cannot resolve @playwright/mcp from $SCRIPT_DIR — did you run 'npm install'?" >&2
  exit 1
fi
if [ "$USE_PROXY" = "true" ] && [ -f "$PROXY" ]; then
  export PW_MCP_CLI="$MCP_CLI"
  exec node "$PROXY" "${PARSED_ARGS[@]}"
fi
exec node "$MCP_CLI" "${PARSED_ARGS[@]}"

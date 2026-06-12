#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

CONFIG_DIR="./.playwright-mcp"
CONFIG_YML="${CONFIG_DIR}/config.yml"
LEGACY_PORT_FILE="${CONFIG_DIR}/port.txt"
OUTPUT_DIR="${CONFIG_DIR}/output"

print_help() {
  cat <<EOF
playwright-browser-mcp

Connects an MCP server to a shared running browser. Starts the browser via
simple-browser if nothing is listening on the CDP port; the MCP server never
launches its own browser.

Usage:
  playwright-browser-mcp [flags]

Flags:
  --mcp <name>       MCP server to run: playwright or chrome-devtools.
  --port <N>         Browser CDP debugging port.
  --browser <name>   Browser started by simple-browser: chrome or electron.
  -h, --help         Show this help and exit.

Config resolution (per value): flag > .playwright-mcp/config.yml > default
(port also falls back to legacy .playwright-mcp/port.txt before detecting the
first free port from 9222). Resolved values are written back to config.yml
after every run.

Defaults: mcp=playwright, browser=chrome, port=first free port from 9222.
EOF
}

# Read a top-level "key: value" from config.yml (strips trailing comments).
read_yml() {
  [ -f "$CONFIG_YML" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$CONFIG_YML" | head -n1 \
    | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# Parse wrapper flags.
MCP=""
PORT=""
BROWSER=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      print_help
      exit 0
      ;;
    --mcp)
      MCP="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --browser)
      BROWSER="$2"
      shift 2
      ;;
    *)
      echo "playwright-browser-mcp: unknown argument '$1' (see --help)" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$CONFIG_DIR"

# MCP server: flag > config.yml > playwright.
if [ -z "$MCP" ]; then
  MCP="$(read_yml mcp)"
fi
MCP="${MCP:-playwright}"
case "$MCP" in
  playwright|chrome-devtools) ;;
  *)
    echo "playwright-browser-mcp: unknown MCP server '$MCP' (expected playwright or chrome-devtools)" >&2
    exit 1
    ;;
esac

# Browser: flag > config.yml > chrome.
if [ -z "$BROWSER" ]; then
  BROWSER="$(read_yml browser)"
fi
BROWSER="${BROWSER:-chrome}"

# Port: flag > config.yml > legacy port.txt > first free port from 9222.
if [ -z "$PORT" ]; then
  PORT="$(read_yml port)"
fi
if [ -z "$PORT" ] && [ -f "$LEGACY_PORT_FILE" ]; then
  PORT="$(cat "$LEGACY_PORT_FILE")"
fi
if [ -z "$PORT" ]; then
  PORT=9222
  while lsof -Pi ":$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; do
    PORT=$((PORT + 1))
  done
fi

# Persist resolved config; drop the legacy txt files.
cat > "$CONFIG_YML" <<EOF
# playwright-browser-mcp configuration
# Resolution per value: CLI flag > this file > default. Resolved values are
# written back here after every run, so a flag run updates future runs too.

# MCP server to run.
# Values: playwright | chrome-devtools (default: playwright)
mcp: ${MCP}

# Browser CDP debugging port.
# Values: any TCP port (default: first free port from 9222, detected once)
port: ${PORT}

# Browser started by simple-browser when nothing is listening on the port.
# Values: chrome | electron (default: chrome)
browser: ${BROWSER}
EOF
rm -f "$LEGACY_PORT_FILE" "${CONFIG_DIR}/mcp.txt" "${CONFIG_DIR}/browser.txt"

# Start the browser via simple-browser only if nothing is listening on the port.
if ! lsof -Pi ":$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  npx --yes simple-browser@latest start --browser "$BROWSER" --port "$PORT" >/dev/null 2>&1
fi

# Run the chosen MCP server connected to the running browser
# (never let it launch its own).
case "$MCP" in
  playwright)
    # Token/perf defaults:
    #   --snapshot-mode none    upstream default "full" appends the whole
    #                           accessibility-tree YAML to EVERY tool response
    #                           (multi-KB..MB + CPU); agent calls
    #                           browser_snapshot explicitly when it needs refs.
    #   --image-responses omit  don't inline screenshot bytes in responses;
    #                           files still land in --output-dir.
    #   --output-mode file      write snapshots/console/network logs to
    #                           --output-dir and reference them in responses
    #                           instead of inlining (upstream default: stdout).
    exec npx --yes @playwright/mcp@latest \
      --cdp-endpoint "http://localhost:${PORT}" \
      --output-dir "$OUTPUT_DIR" \
      --snapshot-mode none \
      --image-responses omit \
      --output-mode file
    ;;
  chrome-devtools)
    exec npx --yes chrome-devtools-mcp@latest \
      --browserUrl "http://localhost:${PORT}"
    ;;
esac

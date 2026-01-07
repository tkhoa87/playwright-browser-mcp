#!/usr/bin/env bash

# Environment Flags
set -o errexit  # Exit when a command fails
set -o pipefail # Catch mysqldump fails
set -o nounset  # Exit when using undeclared variables

# Start the MCP server
npx \
  --yes \
  --no-progress \
  @playwright/mcp \
  -- \
  "$@"

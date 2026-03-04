# playwright-browser-mcp

A lightweight wrapper around [`@playwright/mcp`](https://github.com/nicholasgriffintn/playwright-mcp) that automatically starts a Chrome instance and connects it to a Playwright MCP server via the Chrome DevTools Protocol (CDP).

## What it does

1. Launches Chrome using [`simple-browser`](https://www.npmjs.com/package/simple-browser)
2. Auto-detects an available CDP port (starting from 9222)
3. Starts the `@playwright/mcp` server connected to that browser

This gives MCP clients (like Claude Code) full browser automation capabilities — clicking, typing, navigating, taking screenshots, and more — without manual browser setup.

## Prerequisites

- Node.js and npm
- `lsof` (standard on macOS/Linux)

## Quick start

### With npx (no install)

```sh
npx --yes playwright-browser-mcp@latest
```

## Installation

### Claude Code

```sh
claude mcp add playwright -- npx --yes playwright-browser-mcp@latest
```

Or add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["--yes", "playwright-browser-mcp@latest"]
    }
  }
}
```

### Cursor

Go to **Cursor Settings** > **MCP** > **Add new global MCP server** and paste:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["--yes", "playwright-browser-mcp@latest"]
    }
  }
}
```

### Codex CLI

```sh
codex mcp add playwright -- npx --yes playwright-browser-mcp@latest
```

### Gemini CLI

```sh
gemini mcp add playwright npx --yes playwright-browser-mcp@latest
```

Or add to `~/.gemini/settings.json` (user-level) or `.gemini/settings.json` (project-level):

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["--yes", "playwright-browser-mcp@latest"]
    }
  }
}
```

## CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | Auto-detected from 9222 | Chrome CDP debugging port |
| `--output-dir <path>` | `.playwright-mcp/output` | Directory for screenshots and artifacts |
| `--cdp-endpoint <url>` | `http://localhost:<port>` | CDP endpoint URL (overrides port) |

All other arguments are passed through to `@playwright/mcp`.

### Examples

```sh
# Use a specific port
./main.sh --port 9333

# Custom output directory
./main.sh --output-dir ./screenshots

# Connect to an existing Chrome instance
./main.sh --cdp-endpoint http://localhost:9222
```

## How it works

- On first run, the wrapper finds an available port starting from 9222 and saves it to `.playwright-mcp/port.txt` for reuse across runs.
- Chrome is started via `simple-browser` (fetched automatically via npx).
- The `@playwright/mcp` server is then launched with `--cdp-endpoint` pointing at the running Chrome instance.

### Port persistence

The chosen port is persisted to `.playwright-mcp/port.txt`. Delete this file to force re-detection:

```sh
rm .playwright-mcp/port.txt
```

## License

MIT

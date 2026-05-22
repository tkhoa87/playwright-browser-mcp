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
| `--snapshot-mode <mode>` | `none` | Set to `full` to restore upstream's "snapshot YAML on every tool response" behavior. `none` is the speed-default. |
| `--image-responses <mode>` | `omit` | Set to `allow` to inline screenshot PNG bytes in MCP responses. |
| `--no-proxy` | proxy on | Disable the proxy front-end and serve `@playwright/mcp` directly (no `get_page_text`, no `find`, no filtered console/network). Env equivalent: `PW_MCP_NO_PROXY=1`. |
| `--proxy` | — | Force the proxy on if it has been disabled by env. Env equivalent: `PW_MCP_PROXY=1`. |

All other arguments are passed through to `@playwright/mcp`.

## Extra MCP tools (proxy mode, on by default)

The wrapper fronts `@playwright/mcp` with a small proxy that adds four
convenience tools. Disable with `--no-proxy` / `PW_MCP_NO_PROXY=1`.

### `get_page_text`

Return `document.body.innerText`, truncated. Skips the accessibility tree —
**cheap**: ~1s and a few KB even on heavy DOMs, vs `browser_snapshot` which can
be 2–10s and multi-MB. Use when you only need text on the page, not refs.

Arguments:
- `maxChars` (number, optional) — character cap. Default 200000.

```json
{ "name": "get_page_text", "arguments": { "maxChars": 5000 } }
```

### `find`

Locate elements whose visible text contains `query` (case-insensitive).
Optional `role` ARIA filter. Leaf-prefer: elements that contain another match
are dropped, so you get the most specific node, not its ancestors. Returns up
to 10 hits with tag, role, aria-label, text, and a CSS selector.

Arguments:
- `query` (string, required) — substring to match.
- `role` (string, optional) — ARIA role to require.

```json
{ "name": "find", "arguments": { "query": "Sign in", "role": "button" } }
```

Avoids the snapshot round-trip you'd normally need just to discover a ref.

### `browser_console_messages` (augmented)

Same as upstream, with two server-side filters added:
- `pattern` (string) — regex; only matching lines are returned.
- `onlyErrors` (boolean) — drop non-error/warn lines.

```json
{ "name": "browser_console_messages", "arguments": { "onlyErrors": true } }
```

### `browser_network_requests` (augmented)

Same as upstream, with one server-side filter added:
- `urlPattern` (string) — regex matched against the request URL line.

```json
{ "name": "browser_network_requests", "arguments": { "urlPattern": "/api/" } }
```

## Performance notes

The wrapper also patches `playwright-core` so `--snapshot-mode none` truly
skips the per-response accessibility-tree walk (upstream computes it even when
omitted from the response). On heavy DOMs this drops non-snapshot tool latency
from a ~2 s floor to single-digit ms. The patch is applied automatically via
`patch-package` on `npm install`.

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

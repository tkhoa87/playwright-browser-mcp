# Playwright Browser MCP

A tiny wrapper that connects a browser-automation MCP server to a shared, already-running Chrome instance.

## What it does

1. Loads config (MCP server, CDP port, browser) from `.playwright-mcp/config.yml` (created on first run; port auto-detected from `9222`).
2. If the browser isn't listening on that port, starts one via [`simple-browser`](https://www.npmjs.com/package/simple-browser).
3. Runs the chosen MCP server connected to that browser — it never launches its own.

This gives MCP clients (like Claude Code) full browser automation — clicking, typing, navigating, screenshots — against a single shared Chrome instance.

## Supported MCP servers

| `--mcp` value | Server | Connection flag used |
|-------|--------|----------------------|
| `playwright` (default) | [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) | `--cdp-endpoint` |
| `chrome-devtools` | [`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) | `--browserUrl` |

## Usage

```sh
# Playwright MCP (default)
npx --yes playwright-browser-mcp@latest

# Chrome DevTools MCP
npx --yes playwright-browser-mcp@latest --mcp chrome-devtools

# All flags
npx --yes playwright-browser-mcp@latest --mcp chrome-devtools --port 9333 --browser electron
```

## Flags

| Flag | Description |
|------|-------------|
| `--mcp <name>` | MCP server: `playwright`, `chrome-devtools`, or `default`. |
| `--port <N>` | Browser CDP debugging port. |
| `--browser <name>` | Browser started by `simple-browser`: `chrome`, `electron`, or `default`. |
| `--launch <bool>` | Start the browser if the port is free: `true`, `false`, or `default`. |
| `-h`, `--help` | Show help and exit. |

Unknown arguments are rejected.

## Persisted config (`.playwright-mcp/config.yml`)

Each value resolves as **flag > `config.yml` > default** (port also falls back to legacy `port.txt` before detecting a free port). Resolved values are written back to `config.yml` after every run; legacy txt files are removed.

For `mcp`, `browser`, and `launch` the literal value `default` is a sentinel: it is persisted as-is (not pinned to a concrete value) and resolves to the current built-in default at runtime, so it keeps tracking the default if a future version changes it. When you don't pass a flag and the key isn't already pinned in `config.yml`, the value persists as `default` (not the concrete value) — a fresh run writes `default` for all three.

```yaml
# MCP server to run.
# Values: playwright | chrome-devtools | default (default: playwright)
mcp: default

# Browser CDP debugging port.
# Values: any TCP port (default: first free port from 9222, detected once)
port: 9222

# Browser started by simple-browser when nothing is listening on the port.
# Values: chrome | electron | default (default: chrome)
browser: default

# Start the browser via simple-browser when nothing is listening on the port.
# Values: true | false | default (default: true)
launch: default
```

Playwright MCP screenshots/artifacts go to `.playwright-mcp/output` (chrome-devtools-mcp has no output-dir flag).

## Token/perf defaults

The wrapper passes opinionated defaults to `@playwright/mcp` (rationale in `main.sh` comments): `--snapshot-mode none` (no accessibility-tree YAML on every response), `--image-responses omit` (no inline screenshot bytes), `--output-mode file` (big payloads go to `.playwright-mcp/output`, referenced not inlined). `chrome-devtools-mcp` runs with upstream defaults.

## Installation

### Claude Code

```sh
claude mcp add playwright -- npx --yes playwright-browser-mcp@latest
# or
claude mcp add chrome-devtools -- npx --yes playwright-browser-mcp@latest --mcp chrome-devtools
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

Go to **Cursor Settings** > **MCP** > **Add new global MCP server** and paste the same JSON as above.

### Codex CLI

```sh
codex mcp add playwright -- npx --yes playwright-browser-mcp@latest
```

### Gemini CLI

```sh
gemini mcp add playwright npx --yes playwright-browser-mcp@latest
```

## Prerequisites

- Node.js and npm
- `lsof` (standard on macOS/Linux)

## License

MIT

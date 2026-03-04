# Repository Guidelines

## Project Overview

This repo is a lightweight wrapper around `@playwright/mcp` that exposes Playwright browser capabilities via an MCP server. The wrapper (`main.sh`) automatically starts a Chrome instance via `simple-browser`, manages Chrome DevTools Protocol (CDP) port allocation, and launches the `@playwright/mcp` server connected to that browser.

## Project Structure & Module Organization

- `main.sh` — entrypoint; starts `simple-browser` for Chrome, then launches `@playwright/mcp` with CDP connection.
- `package.json` — defines the CLI name (`playwright-browser-mcp`) and `@playwright/mcp` dependency; `package-lock.json` pins versions.
- `.playwright-mcp/` — runtime config directory (auto-created); stores `port.txt` (persisted CDP port) and `output/` (default screenshot/artifact dir).
- `node_modules/` — vendor output (do not edit by hand).

## Build, Test, and Development Commands

- `npm install` — installs dependencies.
- `npm pack` — produces a tarball to verify package contents.
- `./main.sh [args]` — runs the MCP server wrapper directly.
- `npx --yes playwright-browser-mcp@latest -- [args]` — runs the installed CLI.

### CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | Auto-detected from 9222 | Chrome CDP debugging port; persisted to `.playwright-mcp/port.txt` |
| `--output-dir <path>` | `.playwright-mcp/output` | Directory for screenshots/artifacts |
| `--cdp-endpoint <url>` | `http://localhost:<port>` | CDP endpoint URL (overrides port-based default) |

All other arguments are passed through to `@playwright/mcp`.

### Prerequisites

- Node.js and npm must be installed.
- `lsof` must be available (used for port detection; standard on macOS/Linux).

## Coding Style & Naming Conventions

- Shell scripts use Bash with strict mode (`errexit`, `pipefail`, `nounset`).
- Prefer small, readable functions if the script grows; keep comments brief and purposeful.
- Indentation: 2 spaces in shell continuations to match `main.sh`.
- Naming: lowercase filenames with hyphens (e.g., `main.sh`); CLI name matches package name.

## Testing Guidelines

- No automated tests are currently defined.
- If you add tests, document the framework and provide a `npm test` script in `package.json`.

## Commit & Pull Request Guidelines

- Use concise, imperative subjects (e.g., “feat: auto-manage Chrome debugging port”); include scope if helpful.
- PRs should include a short description of the change, how to run it locally, and any risks.

## Gotchas

- **Port persistence**: Once a port is chosen, it's saved to `.playwright-mcp/port.txt` and reused across runs. Delete this file to force re-detection.
- **`simple-browser` is fetched via `npx --yes simple-browser@latest`**: It's not in `package.json`; it's downloaded on first run and cached by npm.
- **Stdout suppression**: `simple-browser` startup and port parsing output are suppressed (`>/dev/null`). If Chrome fails to start, check stderr or run `simple-browser` manually to debug.

## Security & Configuration Tips

- `@playwright/mcp` uses `latest` in `package.json`; consider pinning a specific version for reproducibility.
- `simple-browser` is fetched via `npx --yes simple-browser@latest` at runtime — pin a version in the `npx` call if needed.
- Pass configuration through CLI args (e.g., `./main.sh --help` to inspect options).

# Repository Guidelines

## Project Overview

This repo is a tiny wrapper (`main.sh`) that connects a browser-automation MCP server to a shared, already-running browser instance. It loads its config (MCP server, CDP port, browser) from `.playwright-mcp/config.yml`, starts the browser via `simple-browser` if nothing is listening on the port, and then runs the chosen MCP server (`@playwright/mcp` or `chrome-devtools-mcp`) connected to that browser — the MCP server never launches its own browser.

## Project Structure & Module Organization

- `main.sh` — the entire logic; ~150 lines of Bash.
- `package.json` — defines the CLI name (`playwright-browser-mcp`) and bin entry; no dependencies (everything runs via `npx`).
- `.playwright-mcp/` — runtime config directory (auto-created); stores `config.yml` (persisted MCP server, port, browser — with inline docs) and `output/` (screenshot/artifact dir for `@playwright/mcp`).

## Build, Test, and Development Commands

- `npm pack` — produces a tarball to verify package contents.
- `./main.sh [flags]` — runs the wrapper directly.
- `npx --yes playwright-browser-mcp@latest [flags]` — runs the installed CLI.

### CLI

| Flag | Description |
|------|-------------|
| `--mcp <name>` | MCP server: `playwright` or `chrome-devtools`. |
| `--port <N>` | Browser CDP debugging port. |
| `--browser <name>` | Browser started by `simple-browser`: `chrome` or `electron`. |
| `--launch <bool>` | Start the browser when the port is free: `true` or `false`. |
| `-h`, `--help` | Show wrapper help and exit. |

Unknown arguments are rejected with an error (nothing is passed through to the MCP server).

### Persisted config (`.playwright-mcp/config.yml`)

Each value resolves as **flag > `config.yml` > default**. Port only: legacy `.playwright-mcp/port.txt` is read between `config.yml` and free-port detection (first free port from 9222). After resolution, `config.yml` is rewritten (with comment docs per option) and legacy txt files (`port.txt`, `mcp.txt`, `browser.txt`) are removed.

| Key | Default | Values |
|-----|---------|--------|
| `mcp` | `playwright` | `playwright` \| `chrome-devtools` |
| `port` | first free port from 9222 | any TCP port |
| `browser` | `chrome` | `chrome` \| `electron` |
| `launch` | `true` | `true` \| `false` |

### Prerequisites

- Node.js and npm must be installed.
- `lsof` must be available (used to check whether Chrome is already listening; standard on macOS/Linux).
- `curl` must be available (used to talk to the CDP endpoint for the marker tab; standard on macOS/Linux). Missing `curl` only skips the marker — the MCP server still runs.

## Coding Style & Naming Conventions

- Shell scripts use Bash with strict mode (`errexit`, `pipefail`, `nounset`).
- Keep `main.sh` minimal; comments brief and purposeful.
- Indentation: 2 spaces.
- Naming: lowercase filenames with hyphens (e.g., `main.sh`); CLI name matches package name.

## Testing Guidelines

- No automated tests are currently defined.
- If you add tests, document the framework and provide a `npm test` script in `package.json`.

## Commit & Pull Request Guidelines

- Use concise, imperative subjects (e.g., “feat: add chrome-devtools MCP option”); include scope if helpful.
- PRs should include a short description of the change, how to run it locally, and any risks.

## Gotchas

- **Config persistence**: port, MCP server, browser, and launch resolve as flag > `config.yml` > default, and resolved values are always written back to `config.yml`. Passing a flag therefore changes future no-flag runs too. Delete the file to restore defaults; edit it to pin values.
- **`launch: false` attaches only**: when nothing is listening on the port and `launch` is `false`, no browser is started (a stderr note is logged) — the MCP server then has nothing to attach to unless you started a browser on that port yourself. Default `true` keeps the auto-start behavior.
- **YAML parsing is naive**: `read_yml` only handles top-level `key: value` lines (trailing `#` comments stripped). No nesting, no quoting — keep `config.yml` flat.
- **`config.yml` is rewritten every run**: manual edits to values survive (they're read first), but custom comments/formatting are replaced by the canonical template.
- **Everything is fetched via `npx --yes <pkg>@latest`** (`simple-browser`, `@playwright/mcp`, `chrome-devtools-mcp`): nothing is in `package.json` dependencies; packages are downloaded on first run and cached by npm.
- **Stdout suppression**: `simple-browser` startup output is suppressed (`>/dev/null 2>&1`). If Chrome fails to start, run `npx simple-browser@latest start --browser chrome --port 9222` manually to debug.
- **`--output-dir` only applies to `@playwright/mcp`**: `chrome-devtools-mcp` has no equivalent flag.
- **Token/perf defaults are baked into the playwright exec call** (see comments in `main.sh`): `--snapshot-mode none --image-responses omit --output-mode file`. chrome-devtools runs with upstream defaults. Revisit when upstream defaults change.
- **Adding a new MCP server**: add the name to the `--mcp` validation `case` and a branch to the exec `case` in `main.sh`, using the server's "connect to running browser" flag.
- **Marker tab**: before exec, `setup_marker` (in `main.sh`) writes `~/Library/Application Support/simple-browser/<browser>-<port>/playwright-mcp.html` — inside simple-browser's per-instance profile dir, so it persists across reboots (was `/tmp`). Contents: working folder/port/profile/mcp/browser — the embedded `config.yml` content carries the mcp/port/browser values; the config.yml `Open` button is a dropdown of editor deep links `vscode://`/`cursor://`/`windsurf://`/`antigravity://file/<path>` with inlined favicons, and each folder path has a `file://` `Open` that opens a browser directory listing. A leading `<!--playwright-browser-mcp working-folder: <PWD>-->` comment records the launching folder (read by `port_reserved`). Opened as one CDP tab. Best-effort over the CDP HTTP endpoint (`/json/version` readiness poll, `/json/list` dedupe on the full marker path, `PUT /json/new` with GET fallback); all failures log to stderr and never block the MCP server. Always-on, deduped (one marker tab per browser instance); `simple-browser` is not involved in writing it.
- **Port reservation (folder-aware)**: free-port detection (the 9222+ scan, used only when no port is pinned via flag/`config.yml`/`port.txt`) skips a port if it is listening **or** if a marker `${MARKER_BASE}/*-<port>/playwright-mcp.html` exists whose `working-folder` comment is a **different** folder than the current `$PWD` (`port_reserved` in `main.sh`). So a stopped instance keeps its port from other repos, but the same folder always reclaims its own port. Delete the marker dir to fully release a port.

## Security & Configuration Tips

- All packages use `@latest` in the `npx` calls — pin versions there if reproducibility is needed.

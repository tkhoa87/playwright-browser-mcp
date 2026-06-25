# Repository Guidelines

## Project Overview

This repo is a tiny wrapper (`main.sh`) that connects a browser-automation MCP server to a shared, already-running browser instance. It loads its config (MCP server, CDP port, browser) from `.playwright-mcp/config.yml`, starts the browser via `simple-browser` if nothing is listening on the port, and then runs the chosen MCP server (`@playwright/mcp` or `chrome-devtools-mcp`) connected to that browser — the MCP server never launches its own browser.

### Related repos

- **`simple-browser`** (same author): `/Users/tkhoa87/Gits/github.com/tkhoa87/simple-browser` — the thing this wrapper invokes to launch the shared browser. The CLI entry is the bash `run` script (bin `simple-browser`/`browser`); `src/main.ts` is only the **electron** backend. Two backends via `-b`/`--browser`:
  - `-b chrome` → spawns the **real Google Chrome/Chromium binary** (`find_chrome`), launched through PM2 with `--remote-debugging-port`, `--user-data-dir=~/Library/Application Support/simple-browser/chrome-<port>`, `--no-first-run --no-default-browser-check --start-maximized`. Profile dir `chrome-<port>` (matches this wrapper's hardcoded `chrome-${PORT}`).
  - `-b electron` (simple-browser's own default; but this wrapper passes `--browser chrome` by default) → the Electron app in `src/main.ts`, profile dir `electron-<port>`.
  - The wrapper invokes `simple-browser start --browser "$BROWSER" --port "$PORT"`, default `browser=chrome` → most users run real Chrome, not Electron.
  - `@playwright/mcp`'s "Browser context management is not supported" error: this is **Chrome's own CDP rejection** of a browser-context op (`Browser.setDownloadBehavior` / `Target.createBrowserContext`), surfaced by Playwright — not a string Playwright emits. Reproduced end-to-end (mcp 0.0.76 = current latest, playwright-core 1.61-alpha, wrapper's exact flags) against **real modern Chrome 149, both headless and headful → NO error** (navigate works). So with the chrome backend on modern Chrome it does not occur. It DOES occur on CDP targets that don't implement browser-context management: the **electron** backend (Electron CDP) and old Chrome builds (cf. playwright #15370/#36961, QtWebEngine). Confirmed live on the electron backend (Electron 42): `browser_navigate`/`browser_snapshot`/`browser_tabs list` on the existing tab all work, but `browser_tabs new` → `Protocol error (Target.createTarget): Not supported`, and `Target.createBrowserContext` is rejected the same way (= the "Browser context management is not supported" message). Electron disallows CDP target/context creation because it owns its windows; there is no flag fix — steer MCP automation to `-b chrome`. The MCP context decision is `config.browser.isolated ? browser.newContext() : browser.contexts()[0]`, and `isolated` comes only from `--isolated` (which the wrapper does not pass) — so the reuse path is taken and `createBrowserContext` is never called. To pin a specific user report: get their Chrome version (`chrome://version`) and confirm the backend via the marker/profile dir (`chrome-<port>` vs `electron-<port>`).

## Project Structure & Module Organization

- `main.sh` — the entire logic; ~150 lines of Bash.
- `package.json` — defines the CLI name (`playwright-browser-mcp`) and bin entry; no runtime dependencies (everything runs via `npx`). Also holds the `format`/`lint`/`test` scripts.
- `test/smoke.sh` — lightweight smoke test (no framework): `bash -n` syntax check, `--help`/`-h` exit 0 with usage, unknown flag rejected. Runs in a scratch dir so it never touches the repo `.gitignore`.
- `.playwright-mcp/` — runtime config directory (auto-created); stores `config.yml` (persisted MCP server, port, browser — with inline docs) and `output/` (screenshot/artifact dir for `@playwright/mcp`).

## Build, Test, and Development Commands

- `npm pack` — produces a tarball to verify package contents.
- `./main.sh [flags]` — runs the wrapper directly.
- `npx --yes playwright-browser-mcp@latest [flags]` — runs the installed CLI.
- `npm run format` — format `main.sh` + `test/smoke.sh` in place with `shfmt -i 2 -ci` (2-space indent, indent case bodies).
- `npm run format:check` — diff-only `shfmt`, non-zero exit on unformatted files (CI/gate use).
- `npm run lint` — `shellcheck` over `main.sh` + `test/smoke.sh`.
- `npm test` — run the `test/smoke.sh` smoke test.

### CLI

| Flag | Description |
|------|-------------|
| `--mcp <name>` | MCP server: `playwright`, `chrome-devtools`, or `default`. |
| `--port <N>` | Browser CDP debugging port. |
| `--browser <name>` | Browser started by `simple-browser`: `chrome`, `electron`, or `default`. |
| `--launch <bool>` | Start the browser when the port is free: `true`, `false`, or `default`. |
| `--marker <bool>` | Open the marker tab on connect: `true`, `false`, or `default`. |
| `-h`, `--help` | Show wrapper help and exit. |

Unknown arguments are rejected with an error (nothing is passed through to the MCP server).

### Persisted config (`.playwright-mcp/config.yml`)

Each value resolves as **flag > `config.yml` > default**. Port only: legacy `.playwright-mcp/port.txt` is read between `config.yml` and free-port detection (first free port from 9222). After resolution, `config.yml` is rewritten (with comment docs per option) and legacy txt files (`port.txt`, `mcp.txt`, `browser.txt`) are removed.

| Key | Default | Values |
|-----|---------|--------|
| `version` | `2` (current `CONFIG_VERSION`) | integer schema version, rewritten every run |
| `mcp` | `chrome-devtools` | `playwright` \| `chrome-devtools` \| `default` |
| `port` | first free port from 9222 | any TCP port |
| `browser` | `chrome` | `chrome` \| `electron` \| `default` |
| `launch` | `true` | `true` \| `false` \| `default` |
| `marker` | `false` | `true` \| `false` \| `default` |

The literal `default` (mcp/browser/launch/marker only) is a sentinel: persisted as-is (not pinned to a concrete value) and resolved to the current built-in default at runtime via `*_EFF` vars in `main.sh`, so it keeps tracking the default if a future version changes it. Unset/empty resolves to `default` too (`${VAR:-default}`), so a no-flag run persists `default` for mcp/browser/launch/marker rather than the concrete value. `port` has no sentinel (its default is the dynamic free-port scan).

### Prerequisites

- Node.js and npm must be installed.
- `shfmt` and `shellcheck` are dev-only prerequisites for `npm run format`/`lint` (e.g. `brew install shfmt shellcheck`); not needed to run the wrapper.
- `lsof` must be available (used to check whether Chrome is already listening; standard on macOS/Linux).
- `curl` must be available (used to talk to the CDP endpoint for the marker tab; standard on macOS/Linux). Missing `curl` only skips the marker — the MCP server still runs.

## Coding Style & Naming Conventions

- Shell scripts use Bash with strict mode (`errexit`, `pipefail`, `nounset`).
- Keep `main.sh` minimal; comments brief and purposeful.
- Indentation: 2 spaces.
- Naming: lowercase filenames with hyphens (e.g., `main.sh`); CLI name matches package name.

## Testing Guidelines

- `npm test` runs `test/smoke.sh` — a no-framework smoke test that checks `bash -n` syntax, `--help`/`-h` exit 0 with usage text, and unknown-flag rejection (exit 1). Each case runs in a `mktemp -d` scratch dir so the wrapper's `.gitignore` side effect never touches the repo.
- Smoke test only: it does not launch a browser or an MCP server. Add cases to `test/smoke.sh` for new flags/validation; if a heavier framework is ever needed, document it and update the `test` script.
- Before committing, run the full gate: `npm run format && npm run lint && npm test`.

## Commit & Pull Request Guidelines

- Use concise, imperative subjects (e.g., “feat: add chrome-devtools MCP option”); include scope if helpful.
- PRs should include a short description of the change, how to run it locally, and any risks.

## Gotchas

- **Config persistence**: port, MCP server, browser, launch, and marker resolve as flag > `config.yml` > default, and resolved values are always written back to `config.yml`. Passing a flag therefore changes future no-flag runs too. Delete the file to restore defaults; edit it to pin values.
- **Schema version / migration**: `config.yml` carries a `version:` key (current `CONFIG_VERSION=2` in `main.sh`). On read, if `version` is missing or `< CONFIG_VERSION`, the config is migrated — stored `mcp`/`browser`/`launch`/`marker` are discarded (treated as the `default` sentinel) and **only `port` is carried forward** (a stderr note is logged when an existing file is migrated). Explicit flags still win regardless. The rewritten file stamps the current `version`. Bump `CONFIG_VERSION` whenever the meaning of a stored value changes so old configs re-baseline to defaults.
- **`launch: false` attaches only**: when nothing is listening on the port and `launch` is `false`, no browser is started (a stderr note is logged) — the MCP server then has nothing to attach to unless you started a browser on that port yourself. Default `true` keeps the auto-start behavior.
- **YAML parsing is naive**: `read_yml` only handles top-level `key: value` lines (trailing `#` comments stripped). No nesting, no quoting — keep `config.yml` flat.
- **`config.yml` is rewritten every run**: manual edits to values survive (they're read first), but custom comments/formatting are replaced by the canonical template.
- **Everything is fetched via `npx --yes <pkg>@latest`** (`simple-browser`, `@playwright/mcp`, `chrome-devtools-mcp`): nothing is in `package.json` dependencies; packages are downloaded on first run and cached by npm.
- **Stdout suppression**: `simple-browser` startup output is suppressed (`>/dev/null 2>&1`). If Chrome fails to start, run `npx simple-browser@latest start --browser chrome --port 9222` manually to debug.
- **`--output-dir` only applies to `@playwright/mcp`**: `chrome-devtools-mcp` has no equivalent flag.
- **Token/perf defaults are baked into the playwright exec call** (see comments in `main.sh`): `--snapshot-mode none --image-responses omit --output-mode file`. chrome-devtools runs with upstream defaults. Revisit when upstream defaults change.
- **Adding a new MCP server**: add the name to the `--mcp` validation `case` and a branch to the exec `case` in `main.sh`, using the server's "connect to running browser" flag.
- **Marker tab**: before exec, `setup_marker` (in `main.sh`) writes `~/Library/Application Support/simple-browser/<browser>-<port>/playwright-mcp.html` — inside simple-browser's per-instance profile dir, so it persists across reboots (was `/tmp`). Contents: working folder/port/profile/mcp/browser — the embedded `config.yml` content carries the mcp/port/browser values; the config.yml `Open` button is a dropdown of editor deep links `vscode://`/`cursor://`/`windsurf://`/`antigravity://file/<path>` with inlined favicons, and each folder path has a `file://` `Open` that opens a browser directory listing. A leading `<!--playwright-browser-mcp working-folder: <PWD>-->` comment records the launching folder (read by `port_reserved`). Opened as one CDP tab. Readiness is polled with `curl` (`/json/version`); the dedupe/prune/open step then runs in an embedded **Node** script (Node is already a prereq) over the CDP HTTP endpoint. Dedupe matches by **URL-decoding** each `/json/list` tab url and comparing to the marker's `file://` path — the marker lives under `Application Support` (a path with a **space**), which Chrome reports percent-encoded (`Application%20Support`), so the earlier `curl`+`grep` on the raw path never matched and opened a fresh tab every run (the historical tab flood). The Node step keeps one marker tab and **closes any extras** (cleaning up a pre-existing flood), and opens one (`PUT /json/new`, GET fallback; non-2xx treated as failure) only when none exist. All failures log to stderr and never block the MCP server. Deduped (one marker tab per browser instance); `simple-browser` is not involved in writing it. **Marker file vs. tab are separate**: the HTML file is written every run (needed for `port_reserved`), but it is only **opened as a tab** when `marker` resolves to `true`. Default `marker=false` → file written, no tab opened, so the curl/CDP-readiness wait and the Node dedupe/open step are skipped entirely.
- **Port reservation (folder-aware)**: a port is "reserved" if a marker `${MARKER_BASE}/*-<port>/playwright-mcp.html` exists whose `working-folder` comment is a **different**, still-existing folder than the current `$PWD` (`port_reserved` in `main.sh`). Two places consult it: (1) free-port detection (the 9222+ scan) skips a port that is listening **or** reserved; (2) a port resolved from `config.yml`/`port.txt` (but **not** an explicit `--port` flag — that is always honored) is released if reserved, falling through to the scan. So a stopped instance keeps its port from other repos, the same folder always reclaims its own port, and a config-pinned port that another repo has taken is auto-rotated to a free one. Delete the marker dir to fully release a port.

## Security & Configuration Tips

- All packages use `@latest` in the `npx` calls — pin versions there if reproducibility is needed.

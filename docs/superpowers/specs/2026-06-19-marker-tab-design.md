# Marker Tab Design

Date: 2026-06-19
Status: Approved

## Problem

A single long-lived shared browser is reused across many repos (each repo runs
the wrapper, gets a free CDP port, and connects an MCP server to it). Nothing
tells a human *which folder owns a given browser window*. The wrapper also has
no "show me this instance" affordance.

Original asks:

1. Start browser minimized/maximized — **deferred** (both browsers force-maximize
   upstream in `simple-browser`; Chrome has no `--start-minimized`, electron
   hardcodes `window.maximize()`; not worth a hack).
2. Rename browser / mark which folder uses it — **subsumed** by the marker tab.
3. Open `chrome://version` (new tab if running, navigate if freshly created) —
   **generalized** into a custom marker tab.

## Solution

`main.sh` opens (and keeps exactly one) **marker tab** in the shared browser.
The tab loads a locally-generated HTML page showing the repo folder, port,
profile dir, MCP server, and browser. The marker page *is* the folder-identity
answer (Q2) and the "open a tab on launch / on running browser" answer (Q3).

### Ownership: wrapper only

`simple-browser` is **not modified**. The repo folder path is known only to the
wrapper (`simple-browser` runs from its own `npx` install dir, blind to `$PWD`),
so the wrapper must generate the marker. All browser interaction is done through
the CDP HTTP endpoint, which both `chrome` and `electron` expose — this avoids
launch-time URL passthrough, which differs between the two browsers.

`simple-browser`'s existing occupied-port path (opens a blank `/json/new` tab)
is left untouched; harmless.

## Flow

Inserted into `main.sh` between browser startup (line ~130) and the final
`exec` of the MCP server. Existing logic is unchanged; this is additive.

```
if ! lsof port listening:
    npx simple-browser start ...          # existing, unchanged
    poll  curl http://localhost:PORT/json/version  until 200 or ~10s timeout

write .playwright-mcp/marker.html         # overwrite every run (folder/port stay current)

if no tab in /json/list has the marker URL:
    open marker tab:
        PUT http://localhost:PORT/json/new?<url-encoded file:// marker path>
        (fall back to GET if PUT returns non-2xx — older Chrome)

exec <MCP server>                         # existing, unchanged
```

### Dedupe = the "fresh + no spam" rule

One `/json/list` check covers every case:

| State                          | Marker tab present? | Action       |
|--------------------------------|---------------------|--------------|
| Browser freshly launched       | no                  | open marker  |
| Already running, no marker tab | no                  | open marker  |
| Already running, marker exists | yes                 | skip         |

The MCP server can reconnect/restart many times against one browser; dedupe
prevents tab pileup. If the user later navigates the marker tab away, the next
run re-opens one (bounded, acceptable).

## marker.html

Static HTML, no JavaScript. Written to `.playwright-mcp/marker.html`
(the runtime config dir, already git-ignored). Overwritten every run so the
displayed values track the current resolution.

Content (all values the wrapper already holds):

```
Folder:  <absolute $PWD>
Port:    <PORT>
Profile: ~/Library/Application Support/simple-browser/chrome-<PORT>
MCP:     <MCP>           # playwright | chrome-devtools
Browser: <BROWSER>       # chrome | electron
```

The `Profile` line mirrors the path `simple-browser` uses for chrome
(`${HOME}/Library/Application Support/simple-browser/chrome-${PORT}`). For
electron the line is still shown for reference; it documents the chrome
convention.

## CDP details

- **Readiness poll** (fresh launch only path, but run unconditionally — cheap if
  already up): `curl -s --max-time 1 http://localhost:PORT/json/version` in a
  loop, up to ~10s, until it returns valid JSON. `simple-browser start` returns
  once PM2 launches Chrome, but Chrome forks and CDP may not be ready yet.
- **List**: `GET /json/list` → check whether any tab's `url` equals the marker
  `file://` URL (dedupe).
- **New tab**: `PUT /json/new?<encoded-url>`. Modern Chrome requires `PUT` on
  `/json/new`; older accepts `GET`. Try `PUT`; on non-2xx, retry `GET`.
- **URL encoding**: the `file://` path may contain spaces (e.g. macOS paths) —
  url-encode before appending as the query.

## Error handling

Marker work is **best-effort and non-blocking**:

- Any curl/CDP failure (timeout, no endpoint, bad response) is logged to
  **stderr** and the wrapper continues to `exec` the MCP server. stdout is
  reserved for the MCP stdio protocol and must never carry marker diagnostics.
- The readiness poll timing out does not abort the run; the wrapper attempts the
  list/new anyway and, if those fail, logs and proceeds.

No silent failures: every skipped or failed marker step emits a one-line stderr
note.

## Scope / non-goals

- No `simple-browser` changes.
- No config toggle — marker is always-on (cheap + deduped). YAGNI.
- No minimize/maximize control (deferred).
- macOS-style profile path is shown verbatim (matches `simple-browser`); not
  made cross-platform here.

## Prerequisites

- Adds `curl` to the documented prerequisites (already a `simple-browser`
  runtime dependency; standard on macOS/Linux) alongside `lsof`.

## Files touched

- `main.sh` — add readiness poll + marker generation + dedupe/open before
  `exec`. Help text + comments updated.
- `CLAUDE.md` — note the marker tab behavior, `curl` prerequisite, and
  `marker.html` artifact under `.playwright-mcp/`.

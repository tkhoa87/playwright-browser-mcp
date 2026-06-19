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

On startup a "marker" tab (.playwright-mcp/marker.html) is opened in the shared
browser showing the folder, port, profile, and MCP server, so you can tell which
repo owns the browser. Best-effort; one marker tab per browser (deduped).
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

# Marker tab: a folder-identity page so a human can tell which repo owns this
# shared browser. Best-effort and non-blocking — every failure logs to stderr
# (stdout is the MCP stdio channel) and the wrapper still execs the MCP server.
setup_marker() {
  local cdp="http://localhost:${PORT}"
  local marker_html="${CONFIG_DIR}/marker.html"
  local marker_abs="${PWD}/.playwright-mcp/marker.html"
  local profile_dir="${HOME}/Library/Application Support/simple-browser/chrome-${PORT}"

  if ! command -v curl >/dev/null 2>&1; then
    echo "playwright-browser-mcp: curl not found; skipping marker tab" >&2
    return 0
  fi

  # Wait for CDP to answer. Chrome forks on launch so the endpoint lags; this is
  # a cheap no-op when the browser was already running.
  local ready="" i
  for ((i = 0; i < 50; i++)); do
    if curl -fs --max-time 1 "${cdp}/json/version" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.2
  done
  if [ -z "$ready" ]; then
    echo "playwright-browser-mcp: CDP on port ${PORT} not ready; skipping marker tab" >&2
    return 0
  fi

  # (Over)write the launch/marker page so its values track the current
  # resolution. Interpolated values are HTML-escaped first.
  local config_abs="${PWD}/.playwright-mcp/config.yml"
  local folder_name="${PWD##*/}"
  local e_pwd e_name e_port e_profile e_mcp e_browser e_cfg
  e_pwd="$(html_escape "$PWD")"
  e_name="$(html_escape "$folder_name")"
  e_port="$(html_escape "$PORT")"
  e_profile="$(html_escape "$profile_dir")"
  e_mcp="$(html_escape "$MCP")"
  e_browser="$(html_escape "$BROWSER")"
  e_cfg="$(html_escape "$config_abs")"
  cat > "$marker_html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${e_name} · browser-mcp</title>
<style>
  :root{
    --bg:oklch(0.16 0.022 274);
    --panel:oklch(0.205 0.024 274);
    --panel-2:oklch(0.235 0.026 274);
    --line:oklch(0.32 0.03 274);
    --ink:oklch(0.97 0.005 274);
    --muted:oklch(0.745 0.018 274);
    --faint:oklch(0.67 0.02 274);
    --mint:oklch(0.82 0.15 165);
    --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    --sans:ui-sans-serif,-apple-system,"Segoe UI",Roboto,system-ui,sans-serif;
  }
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  body{
    background:var(--bg);color:var(--ink);font-family:var(--sans);line-height:1.5;
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
    display:grid;place-items:center;padding:clamp(1.25rem,4vw,3rem);
    position:relative;overflow-x:hidden;
  }
  .aura{position:fixed;inset:-25vmax;z-index:0;pointer-events:none;
    background:
      radial-gradient(38vmax 38vmax at 22% 16%, oklch(0.62 0.2 280/.55), transparent 60%),
      radial-gradient(34vmax 34vmax at 84% 10%, oklch(0.72 0.14 205/.5), transparent 62%),
      radial-gradient(40vmax 40vmax at 72% 92%, oklch(0.66 0.17 330/.4), transparent 60%);
    filter:blur(22px) saturate(120%);
    animation:drift 26s ease-in-out infinite alternate;}
  @keyframes drift{from{transform:translate3d(-2%,-1%,0) scale(1)}to{transform:translate3d(2%,2%,0) scale(1.08)}}
  main{position:relative;z-index:1;width:100%;max-width:600px}
  .head{display:flex;align-items:flex-start;gap:.85rem;margin-bottom:1.7rem}
  .mark{width:38px;height:38px;flex:0 0 auto;border-radius:50%;position:relative;
    background:conic-gradient(from 210deg, oklch(0.62 0.2 280), oklch(0.72 0.14 205), oklch(0.66 0.17 330), oklch(0.62 0.2 280));
    box-shadow:0 0 0 1px oklch(1 0 0/.12), 0 10px 32px -8px oklch(0.62 0.2 280/.5);}
  .mark::after{content:"";position:absolute;inset:7px;border-radius:50%;background:var(--bg);}
  .head h1{font-size:1.06rem;font-weight:650;letter-spacing:-.01em;margin:0;}
  .head .tag{margin:.12rem 0 0;font-size:.8rem;color:var(--muted);}
  .status{margin-left:auto;display:inline-flex;align-items:center;gap:.42rem;
    font-family:var(--mono);font-size:.72rem;color:var(--mint);
    border:1px solid color-mix(in oklch, var(--mint), transparent 72%);
    border-radius:999px;padding:.22rem .6rem;}
  .status i{width:7px;height:7px;border-radius:50%;background:var(--mint);
    animation:pulse 2.6s ease-out infinite;}
  @keyframes pulse{0%{box-shadow:0 0 0 0 oklch(0.82 0.15 165/.55)}70%,100%{box-shadow:0 0 0 7px oklch(0.82 0.15 165/0)}}
  .bind{padding:.25rem 0 .5rem;}
  .bind-label{font-size:.78rem;color:var(--muted);margin:0 0 .45rem;}
  .bind-name{font-size:clamp(1.5rem,4.5vw,2.05rem);font-weight:650;letter-spacing:-.02em;
    margin:0;text-wrap:balance;}
  .bind-path{display:flex;align-items:center;gap:.55rem;margin:.5rem 0 0;
    font-family:var(--mono);font-size:.77rem;color:var(--muted);}
  .bind-path span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
  .bind-meta{display:flex;gap:.45rem;margin-top:1rem;flex-wrap:wrap;}
  .pill{font-family:var(--mono);font-size:.74rem;color:var(--ink);background:var(--panel-2);
    border:1px solid var(--line);border-radius:999px;padding:.2rem .65rem;}
  .card{position:relative;background:var(--panel);border:1px solid var(--line);
    border-radius:14px;padding:1.1rem 1.25rem;margin-top:1rem;
    box-shadow:0 1px 0 oklch(1 0 0/.04) inset, 0 24px 48px -34px oklch(0 0 0/.85);}
  .card-h{display:flex;justify-content:space-between;align-items:baseline;gap:1rem;margin-bottom:.7rem;}
  .card h2{font-size:.82rem;font-weight:600;margin:0;color:var(--ink);}
  .card .src{font-family:var(--mono);font-size:.72rem;color:var(--faint);}
  .cfg{margin:0;display:flex;flex-direction:column;}
  .cfg>div{display:grid;grid-template-columns:5rem 1fr auto;align-items:baseline;gap:1rem;
    padding:.55rem 0;border-top:1px solid var(--line);}
  .cfg>div:first-child{border-top:0;padding-top:.1rem;}
  .cfg dt{font-family:var(--mono);font-size:.8rem;color:var(--muted);margin:0;}
  .cfg dd{margin:0;font-family:var(--mono);font-size:.92rem;color:var(--ink);}
  .cfg dd.opt{font-family:var(--sans);font-size:.76rem;color:var(--faint);text-align:right;}
  .profile{display:flex;align-items:center;gap:.6rem;margin-top:.85rem;padding-top:.85rem;
    border-top:1px solid var(--line);}
  .profile>span{font-family:var(--mono);font-size:.78rem;color:var(--muted);flex:0 0 auto;}
  .profile code{font-family:var(--mono);font-size:.76rem;color:var(--muted);
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1 1 0;min-width:0;}
  .how{font-size:.8rem;color:var(--muted);margin:.05rem 0 .85rem;max-width:62ch;}
  .ways{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.7rem;}
  .ways li{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;font-size:.82rem;}
  .ways b{font-weight:600;color:var(--ink);flex:0 0 7rem;}
  .ways code{font-family:var(--mono);font-size:.77rem;color:var(--muted);background:var(--panel-2);
    border:1px solid var(--line);border-radius:7px;padding:.22rem .55rem;
    flex:1 1 0;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
  .copy{font-family:var(--sans);font-size:.72rem;color:var(--muted);background:transparent;
    border:1px solid var(--line);border-radius:6px;padding:.16rem .5rem;cursor:pointer;flex:0 0 auto;
    transition:color .15s ease,border-color .15s ease,background .15s ease;}
  .copy:hover{color:var(--ink);border-color:var(--faint);background:var(--panel-2);}
  .copy:focus-visible{outline:2px solid var(--mint);outline-offset:2px;}
  .copy.ok{color:var(--mint);border-color:color-mix(in oklch, var(--mint), transparent 50%);}
  footer{margin-top:1.5rem;text-align:center;font-family:var(--mono);font-size:.72rem;color:var(--faint);}
  @media (max-width:520px){
    .cfg>div{grid-template-columns:4.5rem 1fr;gap:.25rem 1rem;}
    .cfg dd.opt{grid-column:2;text-align:left;}
    .ways b{flex-basis:100%;}
  }
  @media (prefers-reduced-motion:reduce){
    .aura{animation:none}.status i{animation:none}.copy{transition:none}
  }
</style>
</head>
<body>
<div class="aura" aria-hidden="true"></div>
<main>
  <header class="head">
    <span class="mark" aria-hidden="true"></span>
    <div>
      <h1>Playwright&nbsp;Browser&nbsp;MCP</h1>
      <p class="tag">One shared browser, wired to your MCP session.</p>
    </div>
    <span class="status"><i></i>connected</span>
  </header>

  <section class="bind">
    <p class="bind-label">This browser is bound to</p>
    <p class="bind-name">${e_name}</p>
    <p class="bind-path"><span id="folder">${e_pwd}</span><button class="copy" data-copy="folder">copy</button></p>
    <div class="bind-meta">
      <span class="pill">port ${e_port}</span>
      <span class="pill">${e_mcp}</span>
      <span class="pill">${e_browser}</span>
    </div>
  </section>

  <section class="card">
    <div class="card-h"><h2>Configuration</h2><span class="src">.playwright-mcp/config.yml</span></div>
    <dl class="cfg">
      <div><dt>mcp</dt><dd>${e_mcp}</dd><dd class="opt">playwright &middot; chrome-devtools</dd></div>
      <div><dt>port</dt><dd>${e_port}</dd><dd class="opt">CDP debug port</dd></div>
      <div><dt>browser</dt><dd>${e_browser}</dd><dd class="opt">chrome &middot; electron</dd></div>
    </dl>
    <div class="profile"><span>profile</span><code id="profile">${e_profile}</code><button class="copy" data-copy="profile">copy</button></div>
  </section>

  <section class="card">
    <div class="card-h"><h2>Change these</h2></div>
    <p class="how">Edits apply on the next launch &mdash; resolution order is flag &rarr; config.yml &rarr; default.</p>
    <ol class="ways">
      <li><b>Edit the file</b><code id="cfgpath">${e_cfg}</code><button class="copy" data-copy="cfgpath">copy</button></li>
      <li><b>Or pass a flag</b><code>--mcp&nbsp;&nbsp;--port&nbsp;&nbsp;--browser</code></li>
    </ol>
  </section>

  <footer>playwright-browser-mcp</footer>
</main>
<script>
for (const b of document.querySelectorAll(".copy")) {
  b.addEventListener("click", async () => {
    const el = document.getElementById(b.dataset.copy);
    if (!el || !navigator.clipboard) return;
    try {
      await navigator.clipboard.writeText(el.textContent.trim());
      const prev = b.textContent;
      b.textContent = "copied";
      b.classList.add("ok");
      setTimeout(() => { b.textContent = prev; b.classList.remove("ok"); }, 1200);
    } catch (e) {}
  });
}
</script>
</body>
</html>
EOF

  # Dedupe: the ".playwright-mcp/marker.html" suffix is space-free and unique
  # within one browser (one CDP endpoint == one repo == one port).
  local tabs
  tabs="$(curl -fs --max-time 2 "${cdp}/json/list" 2>/dev/null || true)"
  if printf '%s' "$tabs" | grep -qF "/.playwright-mcp/marker.html"; then
    return 0
  fi

  local file_url encoded
  file_url="file://${marker_abs}"
  encoded="$(urlencode "$file_url")"

  # Modern Chrome requires PUT on /json/new; older accepts GET.
  if curl -fs --max-time 2 -X PUT "${cdp}/json/new?${encoded}" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fs --max-time 2 "${cdp}/json/new?${encoded}" >/dev/null 2>&1; then
    return 0
  fi
  echo "playwright-browser-mcp: failed to open marker tab on port ${PORT}" >&2
}

# Escape &, <, >, " for safe interpolation into the marker HTML.
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# Percent-encode a string, leaving file-URL-safe characters intact.
urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~:/?-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

setup_marker || true

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

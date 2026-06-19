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
  --launch <bool>    Start the browser if the port is free: true or false.
  -h, --help         Show this help and exit.

Config resolution (per value): flag > .playwright-mcp/config.yml > default
(port also falls back to legacy .playwright-mcp/port.txt before detecting the
first free port from 9222). Resolved values are written back to config.yml
after every run.

Defaults: mcp=playwright, browser=chrome, port=first free port from 9222,
launch=true. With launch=false the browser is never started; connect it to the
port yourself or the MCP server has nothing to attach to.

On startup a "marker" tab is opened in the shared browser
(/tmp/playwright-browser-mcp/<browser>-<port>/index.html) showing the working
folder, port, profile, and MCP server, so you can tell which repo owns the
browser. Best-effort; one marker tab per browser instance (deduped).
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
LAUNCH=""
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
    --launch)
      LAUNCH="$2"
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

# Launch browser when the port is free: flag > config.yml > true.
if [ -z "$LAUNCH" ]; then
  LAUNCH="$(read_yml launch)"
fi
LAUNCH="${LAUNCH:-true}"
case "$LAUNCH" in
  true|false) ;;
  *)
    echo "playwright-browser-mcp: unknown launch value '$LAUNCH' (expected true or false)" >&2
    exit 1
    ;;
esac

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

# Start the browser via simple-browser when nothing is listening on the port.
# Set false to attach only to a browser you start yourself.
# Values: true | false (default: true)
launch: ${LAUNCH}
EOF
rm -f "$LEGACY_PORT_FILE" "${CONFIG_DIR}/mcp.txt" "${CONFIG_DIR}/browser.txt"

# Start the browser via simple-browser only if nothing is listening on the port
# and launch is enabled.
if ! lsof -Pi ":$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  if [ "$LAUNCH" = true ]; then
    npx --yes simple-browser@latest start --browser "$BROWSER" --port "$PORT" >/dev/null 2>&1
  else
    echo "playwright-browser-mcp: nothing listening on port ${PORT} and launch=false; not starting a browser" >&2
  fi
fi

# Marker tab: a folder-identity page so a human can tell which repo owns this
# shared browser. Best-effort and non-blocking — every failure logs to stderr
# (stdout is the MCP stdio channel) and the wrapper still execs the MCP server.
setup_marker() {
  local cdp="http://localhost:${PORT}"
  # Marker lives in a per browser+port dir under /tmp (instance-specific, not
  # tied to the launching repo).
  local marker_dir="/tmp/playwright-browser-mcp/${BROWSER}-${PORT}"
  local marker_html="${marker_dir}/index.html"
  local marker_abs="${marker_html}"
  local profile_dir="${HOME}/Library/Application Support/simple-browser/chrome-${PORT}"
  mkdir -p "$marker_dir"

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
  # resolution. Interpolated values are HTML-escaped first. The mcp/port/browser
  # values are shown once via the embedded config.yml content (no duplication).
  local config_abs="${PWD}/.playwright-mcp/config.yml"
  local folder_name="${PWD##*/}"
  local cfg_content open_cfg open_folder open_profile
  local e_pwd e_name e_profile e_cfg_content
  e_pwd="$(html_escape "$PWD")"
  e_name="$(html_escape "$folder_name")"
  e_profile="$(html_escape "$profile_dir")"
  cfg_content="$(cat "$CONFIG_YML" 2>/dev/null || true)"
  e_cfg_content="$(html_escape "$cfg_content")"
  # vscode://file/<abs path> hands the path to the editor registered for the
  # scheme (VS Code and forks). Used for the "Open" buttons on each path.
  open_cfg="vscode://file$(urlencode "$config_abs")"
  open_folder="vscode://file$(urlencode "$PWD")"
  open_profile="vscode://file$(urlencode "$profile_dir")"
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
  .head{display:flex;align-items:center;gap:.85rem;margin-bottom:1.7rem}
  .mark{width:40px;height:40px;flex:0 0 auto;border-radius:50%;position:relative;
    background:conic-gradient(from 210deg, oklch(0.62 0.2 280), oklch(0.72 0.14 205), oklch(0.66 0.17 330), oklch(0.62 0.2 280));
    box-shadow:0 0 0 1px oklch(1 0 0/.12), 0 10px 32px -8px oklch(0.62 0.2 280/.5);}
  .mark::after{content:"";position:absolute;inset:7px;border-radius:50%;background:var(--bg);}
  .head .title{display:flex;flex-direction:column;justify-content:center;}
  .head h1{font-size:1.06rem;font-weight:650;letter-spacing:-.01em;margin:0;}
  .head .tag{margin:.12rem 0 0;font-size:.8rem;color:var(--muted);}
  .status{margin-left:auto;display:inline-flex;align-items:center;gap:.42rem;
    font-family:var(--mono);font-size:.72rem;color:var(--mint);
    border:1px solid color-mix(in oklch, var(--mint), transparent 72%);
    border-radius:999px;padding:.22rem .6rem;}
  .status i{width:7px;height:7px;border-radius:50%;background:var(--mint);
    animation:pulse 2.6s ease-out infinite;}
  @keyframes pulse{0%{box-shadow:0 0 0 0 oklch(0.82 0.15 165/.55)}70%,100%{box-shadow:0 0 0 7px oklch(0.82 0.15 165/0)}}
  .card{position:relative;background:var(--panel);border:1px solid var(--line);
    border-radius:14px;padding:1.1rem 1.25rem;
    box-shadow:0 1px 0 oklch(1 0 0/.04) inset, 0 24px 48px -34px oklch(0 0 0/.85);}
  .bar{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;margin-bottom:.75rem;}
  .bar h2{font-size:.82rem;font-weight:600;margin:0;color:var(--ink);}
  .bar .src{font-family:var(--mono);font-size:.72rem;color:var(--faint);}
  .bar .actions{margin-left:auto;display:flex;gap:.45rem;}
  pre.yaml{margin:0;font-family:var(--mono);font-size:.78rem;line-height:1.65;color:var(--ink);
    background:var(--panel-2);border:1px solid var(--line);border-radius:9px;
    padding:.85rem .95rem;white-space:pre-wrap;overflow-wrap:anywhere;}
  pre.yaml .cmt{color:var(--faint);font-style:italic;}
  pre.yaml .key{color:oklch(0.8 0.09 232);}
  pre.yaml .val{color:oklch(0.85 0.1 150);}
  pre.yaml .num{color:oklch(0.82 0.12 56);}
  .field{margin-top:.95rem;padding-top:.9rem;border-top:1px solid var(--line);}
  .field-top{display:flex;align-items:center;gap:.6rem;margin-bottom:.32rem;}
  .field-label{font-size:.82rem;font-weight:600;color:var(--ink);margin:0;}
  .field-top .actions{margin-left:auto;display:flex;gap:.45rem;}
  .path{display:block;font-family:var(--mono);font-size:.77rem;color:var(--muted);
    overflow-wrap:anywhere;word-break:break-word;line-height:1.55;margin:0;}
  .btn,.copy{font-family:var(--sans);font-size:.72rem;cursor:pointer;flex:0 0 auto;
    border:1px solid var(--line);border-radius:6px;padding:.2rem .55rem;text-decoration:none;
    display:inline-flex;align-items:center;gap:.35rem;
    transition:color .15s ease,border-color .15s ease,background .15s ease;}
  .copy{color:var(--muted);background:transparent;}
  .btn{color:var(--ink);background:var(--panel-2);}
  .btn:hover,.copy:hover{color:var(--ink);border-color:var(--faint);background:var(--panel-2);}
  .btn:focus-visible,.copy:focus-visible{outline:2px solid var(--mint);outline-offset:2px;}
  .copy.ok{color:var(--mint);border-color:color-mix(in oklch, var(--mint), transparent 50%);}
  @media (prefers-reduced-motion:reduce){
    .aura{animation:none}.status i{animation:none}.btn,.copy{transition:none}
  }
</style>
</head>
<body>
<div class="aura" aria-hidden="true"></div>
<main>
  <header class="head">
    <span class="mark" aria-hidden="true"></span>
    <div class="title">
      <h1>Playwright&nbsp;Browser&nbsp;MCP</h1>
      <p class="tag">One shared browser, wired to your MCP session.</p>
    </div>
    <span class="status"><i></i>connected</span>
  </header>

  <section class="card">
    <div class="bar">
      <h2>Configuration</h2>
      <span class="src">.playwright-mcp/config.yml</span>
      <span class="actions">
        <a class="btn" href="${open_cfg}" title="Open config.yml in your editor">Open</a>
        <button class="copy" data-copy="yaml">Copy</button>
      </span>
    </div>
    <pre class="yaml" id="yaml">${e_cfg_content}</pre>
    <div class="field">
      <div class="field-top">
        <p class="field-label">Working Folder</p>
        <span class="actions">
          <a class="btn" href="${open_folder}" title="Open folder in your editor">Open</a>
          <button class="copy" data-copy="folder">Copy</button>
        </span>
      </div>
      <code class="path" id="folder">${e_pwd}</code>
    </div>
    <div class="field">
      <div class="field-top">
        <p class="field-label">Browser Profile</p>
        <span class="actions">
          <a class="btn" href="${open_profile}" title="Open browser profile folder in your editor">Open</a>
          <button class="copy" data-copy="profile">Copy</button>
        </span>
      </div>
      <code class="path" id="profile">${e_profile}</code>
    </div>
  </section>
</main>
<script>
for (const b of document.querySelectorAll(".copy")) {
  b.addEventListener("click", async () => {
    const el = document.getElementById(b.dataset.copy);
    if (!el || !navigator.clipboard) return;
    try {
      await navigator.clipboard.writeText(el.textContent.trim());
      const prev = b.textContent;
      b.textContent = "Copied";
      b.classList.add("ok");
      setTimeout(() => { b.textContent = prev; b.classList.remove("ok"); }, 1200);
    } catch (e) {}
  });
}
// Light syntax highlight for the flat config.yml (comments / keys / values).
const yamlEl = document.getElementById("yaml");
if (yamlEl) {
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  yamlEl.innerHTML = yamlEl.textContent.split("\n").map((line) => {
    if (/^\s*#/.test(line)) return '<span class="cmt">' + esc(line) + "</span>";
    const m = line.match(/^(\s*)([\w.-]+)(:\s*)(.*)$/);
    if (!m) return esc(line);
    const cls = /^-?\d+$/.test(m[4].trim()) ? "num" : "val";
    const val = m[4] ? '<span class="' + cls + '">' + esc(m[4]) + "</span>" : "";
    return esc(m[1]) + '<span class="key">' + esc(m[2]) + "</span>" + esc(m[3]) + val;
  }).join("\n");
}
</script>
</body>
</html>
EOF

  # Dedupe: the marker path is per browser+port (one CDP endpoint == one browser
  # instance) and space-free, so a literal match on the full path is unique.
  local tabs
  tabs="$(curl -fs --max-time 2 "${cdp}/json/list" 2>/dev/null || true)"
  if printf '%s' "$tabs" | grep -qF "$marker_abs"; then
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

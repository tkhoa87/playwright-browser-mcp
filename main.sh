#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

CONFIG_DIR="./.playwright-mcp"
CONFIG_YML="${CONFIG_DIR}/config.yml"
LEGACY_PORT_FILE="${CONFIG_DIR}/port.txt"
OUTPUT_DIR="${CONFIG_DIR}/output"
# Per-instance marker pages live inside simple-browser's profile area
# (~/Library/Application Support/simple-browser/<browser>-<port>/playwright-mcp.html),
# alongside the browser profile so they survive OS restarts (unlike /tmp).
MARKER_BASE="${HOME}/Library/Application Support/simple-browser"

# Own package version (for the marker page), read from the package.json next to
# this script. Best-effort: empty if node or the file is unavailable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_VERSION="$(node -p "require('${SCRIPT_DIR}/package.json').version" 2>/dev/null || true)"

# Code defaults. The literal value "default" (accepted for mcp/browser/launch via
# flag or config.yml) is a sentinel: it is persisted as-is so it always tracks
# whatever these constants are, and is resolved to the constant at runtime.
DEFAULT_MCP="playwright"
DEFAULT_BROWSER="chrome"
DEFAULT_LAUNCH="true"

print_help() {
  cat <<EOF
playwright-browser-mcp

Connects an MCP server to a shared running browser. Starts the browser via
simple-browser if nothing is listening on the CDP port; the MCP server never
launches its own browser.

Usage:
  playwright-browser-mcp [flags]

Flags:
  --mcp <name>       MCP server to run: playwright, chrome-devtools, or default.
  --port <N>         Browser CDP debugging port.
  --browser <name>   Browser started by simple-browser: chrome, electron, or default.
  --launch <bool>    Start the browser if the port is free: true, false, or default.
  -h, --help         Show this help and exit.

Config resolution (per value): flag > .playwright-mcp/config.yml > default
(port also falls back to legacy .playwright-mcp/port.txt before detecting the
first free port from 9222). Resolved values are written back to config.yml
after every run. For mcp/browser/launch the literal "default" is a sentinel:
it is persisted as-is and resolves to the current built-in default at runtime,
so it keeps tracking the default if a future version changes it.

Defaults: mcp=playwright, browser=chrome, port=first free port from 9222,
launch=true. With launch=false the browser is never started; connect it to the
port yourself or the MCP server has nothing to attach to.

On startup a "marker" tab is opened in the shared browser, served from
~/Library/Application Support/simple-browser/<browser>-<port>/playwright-mcp.html
(persists across reboots), showing the working folder, port, profile, and MCP
server, so you can tell which repo owns the browser. Best-effort; one marker tab
per browser instance (deduped). Free-port detection skips a port whose marker
belongs to a different working folder (the same folder reclaims its own port).
EOF
}

# Read a top-level "key: value" from config.yml (strips trailing comments).
read_yml() {
  [ -f "$CONFIG_YML" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$CONFIG_YML" | head -n1 \
    | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# True if a marker reserves this port for a DIFFERENT working folder that STILL
# EXISTS. A stopped instance keeps its port, but the same folder always reclaims
# its own port, and a deleted folder releases its port. The working folder is
# read from the marker's "working-folder:" HTML comment.
port_reserved() {
  local f folder
  shopt -s nullglob
  local files=("${MARKER_BASE}/"*"-$1/playwright-mcp.html")
  shopt -u nullglob
  for f in ${files[@]+"${files[@]}"}; do
    folder="$(sed -n 's/.*working-folder: \(.*\)-->.*/\1/p' "$f" | head -n1)"
    [ "$folder" != "$PWD" ] && [ -d "$folder" ] && return 0
  done
  return 1
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

# MCP server: flag > config.yml > "default". Unset resolves to the "default"
# sentinel (persisted as-is, resolved to $DEFAULT_MCP at runtime below).
if [ -z "$MCP" ]; then
  MCP="$(read_yml mcp)"
fi
MCP="${MCP:-default}"
case "$MCP" in
  playwright|chrome-devtools|default) ;;
  *)
    echo "playwright-browser-mcp: unknown MCP server '$MCP' (expected playwright, chrome-devtools, or default)" >&2
    exit 1
    ;;
esac
[ "$MCP" = default ] && MCP_EFF="$DEFAULT_MCP" || MCP_EFF="$MCP"

# Browser: flag > config.yml > "default". Unset resolves to the "default"
# sentinel (persisted as-is, resolved to $DEFAULT_BROWSER at runtime below).
if [ -z "$BROWSER" ]; then
  BROWSER="$(read_yml browser)"
fi
BROWSER="${BROWSER:-default}"
[ "$BROWSER" = default ] && BROWSER_EFF="$DEFAULT_BROWSER" || BROWSER_EFF="$BROWSER"

# Launch browser when the port is free: flag > config.yml > "default". Unset
# resolves to the "default" sentinel (persisted as-is, resolved to
# $DEFAULT_LAUNCH at runtime below).
if [ -z "$LAUNCH" ]; then
  LAUNCH="$(read_yml launch)"
fi
LAUNCH="${LAUNCH:-default}"
case "$LAUNCH" in
  true|false|default) ;;
  *)
    echo "playwright-browser-mcp: unknown launch value '$LAUNCH' (expected true, false, or default)" >&2
    exit 1
    ;;
esac
[ "$LAUNCH" = default ] && LAUNCH_EFF="$DEFAULT_LAUNCH" || LAUNCH_EFF="$LAUNCH"

# Port: flag > config.yml > legacy port.txt > first free port from 9222.
# An explicit --port flag is honored as-is; a port from config.yml/port.txt is
# subject to the reservation check below.
PORT_PINNED_BY_FLAG=""
[ -n "$PORT" ] && PORT_PINNED_BY_FLAG=1
if [ -z "$PORT" ]; then
  PORT="$(read_yml port)"
fi
if [ -z "$PORT" ] && [ -f "$LEGACY_PORT_FILE" ]; then
  PORT="$(cat "$LEGACY_PORT_FILE")"
fi
# A config/legacy port (not an explicit flag) that a marker reserves for a
# DIFFERENT, still-existing working folder is released here so the free-port
# scan picks a fresh one. The same folder keeps reclaiming its own port.
if [ -n "$PORT" ] && [ -z "$PORT_PINNED_BY_FLAG" ] && port_reserved "$PORT"; then
  echo "playwright-browser-mcp: port ${PORT} (from config.yml) is reserved by another folder's browser; finding a free port instead" >&2
  PORT=""
fi
if [ -z "$PORT" ]; then
  # Skip ports that are listening OR already reserved by a marker (a stopped
  # instance keeps its port across restarts).
  PORT=9222
  while lsof -Pi ":$PORT" -sTCP:LISTEN -t >/dev/null 2>&1 || port_reserved "$PORT"; do
    PORT=$((PORT + 1))
  done
fi

# Persist resolved config; drop the legacy txt files.
cat > "$CONFIG_YML" <<EOF
# playwright-browser-mcp config
# Resolution per value: CLI flag > this file > default.
# This file is rewritten every run.

# MCP server to run.
# playwright | chrome-devtools | default (${DEFAULT_MCP})
mcp: ${MCP}

# Browser CDP debugging port.
# any TCP port (default: first free from 9222)
port: ${PORT}

# Browser simple-browser launches when the port is free.
# chrome | electron | default (${DEFAULT_BROWSER})
browser: ${BROWSER}

# Launch the browser when nothing is listening on the port.
# true | false | default (${DEFAULT_LAUNCH})
launch: ${LAUNCH}
EOF
rm -f "$LEGACY_PORT_FILE" "${CONFIG_DIR}/mcp.txt" "${CONFIG_DIR}/browser.txt"

# Start the browser via simple-browser only if nothing is listening on the port
# and launch is enabled.
if ! lsof -Pi ":$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  if [ "$LAUNCH_EFF" = true ]; then
    npx --yes simple-browser@latest start --browser "$BROWSER_EFF" --port "$PORT" >/dev/null 2>&1
  else
    echo "playwright-browser-mcp: nothing listening on port ${PORT} and launch=false; not starting a browser" >&2
  fi
fi

# Marker tab: a folder-identity page so a human can tell which repo owns this
# shared browser. Best-effort and non-blocking — every failure logs to stderr
# (stdout is the MCP stdio channel) and the wrapper still execs the MCP server.
setup_marker() {
  local cdp="http://127.0.0.1:${PORT}"
  # Marker lives inside simple-browser's per browser+port profile dir
  # (persists across reboots).
  local marker_dir="${MARKER_BASE}/${BROWSER_EFF}-${PORT}"
  local marker_html="${marker_dir}/playwright-mcp.html"
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
  local enc_cfg
  local ic_vscode ic_cursor ic_windsurf ic_antigravity
  local e_folder_dir e_folder_name e_profile_dir e_profile_name
  local e_folder_full e_profile_full
  local cfg_content e_cfg_content
  # Split each path into "parent dir + /" and basename so the basename (the
  # glance-able folder name) can be highlighted; copy still grabs the full path.
  e_folder_dir="$(html_escape "${PWD%/*}/")"
  e_folder_name="$(html_escape "${PWD##*/}")"
  e_folder_full="$(html_escape "$PWD")"
  e_profile_dir="$(html_escape "${profile_dir%/*}/")"
  e_profile_name="$(html_escape "${profile_dir##*/}")"
  e_profile_full="$(html_escape "$profile_dir")"
  cfg_content="$(cat "$CONFIG_YML" 2>/dev/null || true)"
  e_cfg_content="$(html_escape "$cfg_content")"
  local e_version=""
  [ -n "${PKG_VERSION}" ] && e_version="v$(html_escape "$PKG_VERSION")"
  # config.yml opens via <editor>://file<path> (VS Code and forks share that
  # shape); the dropdown offers one item per editor, each with its favicon
  # (inlined as a data URI).
  enc_cfg="$(urlencode "$config_abs")"
  ic_vscode="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAUVBMVEVHcEwAdbwNktwjq/MbnukAesEAfMMAe8IIgsoCfsUAdbcip/IkrvMho/IAhdEAbrEAebsmsvQAjNQAgc8jqvIAiNIfn/EAfM0Aj9UAZ60AcMj8DbWHAAAACnRSTlMA3dOsgXhZshoyihrbnQAAAopJREFUWIWdl+uCgiAQhcHygpqgZkrv/6A7gBdmwFU601o/Oh9nCHFhLEXP7PFMMmAJpepP3/+MAL+qZd//iijUDuj7R7o/Vxag+1WPKtk/IkAiolSKJLAIkeongNtzwY13jAHu/SBc7QECQHNtr5QnB2jXMpdEPwDatu29uvILRQE98l8BCuKXNoGvFL9ZyRiwJ8if0VUFy6+2vqsECygP/aU3tKs4oFqsysBfH1r9teQhQCybcBu8VkHVJWsp4PAvS4H8EcEXsP3dsswDeG3Y2PV6XYfnJmKQYPABy+DaqGLDO/qbiJULlmlDnMS3gBYXY9ngy7QhpAz92wy/kR8ShIRMa0kRx+RY167WAAgBVFOCt8qCObBLhgCWGYfwF0gUwJ40Q2cJwIDCSzQOYDklDHLLQG6SEwArJqJFuRB05yb+Y08U04DLtsEZ1SmAVQMNMcnIPd5YvZtNHkAHgOEU0IQAIXVImLLbgALmS+uOArqJTuIJIJcWoMcAMOV3ANZvCXPYRnkNKKXcCWrqus4Mbd4691lcAEq3aFdCbW1Y+b8ALj0BgQcEv42meaEifiDAhhJGmLrtjiT+19H/KrulhYSuK3ZAY/+cXkxq5F831RjBtfEiQh3oo9XRc472BZcqBhAk/iY+UnXjWEQA5iZYCz/aMnBstb3NZQTAKjd8+HANMozzzJsQwMxE6tjjPQL4RgEsz+P/YNwGnKmIAj7mtdX/AEoAgDMfhAsAE9gPgA/WFYBV4FvLBPh66W8lAMLsBfghAYjPq0abACncdeME10Qkwc3zV7ll+H6x//bhq9wBfoKUU1MeJkg8t+UkQeqxDxal9X+T5g5L7C38enoW4B9+t4OqyPH/D4oCjm4xEIAeAAAAAElFTkSuQmCC"
  ic_cursor="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAS1BMVEVHcExCQTsUEgvt7OxCQTtBQDpBQDpAPzlBQDpBQDoQDgUBAADx8PD39vbZ2NcmJR++vb03NjDp6OjQz82pp6aOjYtiYF56eXdHcEzH0xfqAAAAGXRSTlMAf///4SyH/r1G//////////////////8AvnwSGwAAAkBJREFUWIWll9GigiAMhkvoQAxE0er93/QMrETdRGO3uS+2MfbvcsnsftVaSrVjUmp9vV9Iu2vVe980jdkx/Nn7Xukt4yZ7P31QNPzM9/K29P9T/pDzF+LVX+6v++aUfzxGr3P/k+4JMRP+fvGPhHcUN8X7G4AduJoyKdn8GfDj2ABL9zLVnw0AYLRoD+AQpo/3QXvO/RWsQHPhySF8zCOdAQNqcOJtbujpVBjFRQBN56yYzY3kIWIMVyKFAA+bu6NZQabCX4kUADyDE2uztn1u48Ak6L3gl2dwnd8g9EWu/350lvJPjG0q5BKAwQvWPSHCa4mQeRUNPFvy9Lm5VmVxYB1ngPEdf/o8jm5+eBYA6Fx7xAJmggYMtoMDplzHAvY6Zz6o5QF4XfjO+STa7QFimge194hAKwoA6rpk/i9XBMR7z6XCQPy5CIjXheic+M1ojwHidSEeEdO7gydgUoElPA6IDbzqHCyhOAOYOicHtOIkANs3A8DDnQaIDJBKWANIJawATCWsAGQX9SfAu4QVgCCqAJ8S/gowTd4nPwCmJvgdgA+pOADoeMCwmvUkIA4WGhDfscyfGyzkaIsAk5VwNdoaVRquEfBtAnK4FsY7Aoz/3mFqvBcEBgK+yaUFRkHiBPg0AflQo8QpiCwEpHeMFlkGRVZB5oVUQm5YJam6LzRDfMd2hSYrdU2SumG0JalbENuuKLar5T4uHNwXhYXDvBeO6pWnfulKhLNrX5P71y+e9atv/fI9MYrrv9qs///mKknzam32nQAAAABJRU5ErkJggg=="
  ic_windsurf="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAPFBMVEVHcEz+9+3//fLq5dv58+kKEA8AAAD59Or58+n58+nb1s1AQT6sqaGMi4WYlY9gX1vKxr22s6wpLCp7enV2e+rjAAAACnRSTlMA////////TMy91SgRkwAAAcNJREFUWIXtl9uWgyAMRUmE2ILWS///XweVS0C0TnmZNcu8lRy2GI6kCCFE+5RfxbMVazy+m77Eo3L+Smhr5kvZii/f38dT1M2X8gbcgH8GgFISUEosZQCbHKBpL8RpJjK6kHgR9ZAAQNMb88d0REoRjTkBDakCYCds7PQlaA9WJUAuXHUrYEjXhsMRIBXCywEUdUlieYMiIBNGgKLmGsAKoQwweBHAhQyg6IWXAHYYiwBFzA1FgN8zJlwAROQpKWBnJInvbQmKA6jXunfk6LMF0Glf1/AxwUyp0AJGBEDtCMFnaJSE8JwIyIXQb75AV4vgM5wntlnxc86F2HcQi8YMiTO3BTsPMiF4QCiw8xmqAwCkQjQeAJNLOJ/RASAK9VK8ibpQtmFbmwEb9scRwAut8fTYUwTYh27j86RHQ8cAL9wMxAAwUhgndQLwQlcL5r43T5ysgAs5wPvsI4ALU4C+CtBlQPDZJwATpgDvs4+AKKQpPaabAOCjewAcHOcQfJYcvoXeaPdybSjZAvwWpT4qNldc3GbGvFNtLY2GJgEXu/NZU4WM+9v2vsP+nT8YN+AG1AGqr33VF8/qq2/95bvy+v8DjMxF+LQW8G0AAAAASUVORK5CYII="
  ic_antigravity="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAABYlBMVEVHcEw5iPw2i/IziPztaDo3ifeJwGA6iPhkhug3ifjtVEg6ivgujO00h/8wivRztHQ0iftrgdLrhy41ifA0iPs+mMJNrp7rWEgwifjgryrcVmJ4wXDiUlmPeMCGxWK3w0FhprPZVmJato0pktxVjflCqKqjbqeLxWKQeL/opSZBp6z1Uj3Xuy01ifwwiPg1h/87if8wh/wvivRCiv4vi+8zktxNjPsvjek1ltEwj+Q5nMTwV0BDpK9Rg+hZifJ5e8tMq6C7ZHk+h/k2h/nOW2lXsJBAn7mGdrx1vG9dgd1Jh/SebZ3lU07meDlitoKuZo1kfszdWlOgvlBWk69wgttBhe/Ia14/iOTaZ01Cj87gpSxzfbOHdqeVcaxMh9O7uz90loxwiKFah77GelWfrVdToKGSe4uud2+kcIXlky6Sm22+qENyp37Mh0iHq2pfpo6tmVeuh2LSszGJhonJlkKWi3VeO12PAAAALXRSTlMARBro/o/8f/1lxVMt8q79vAf6/cv6i23YVBo4QcePmg6TzuC5S3QaM6re4bufpM1dAAADxklEQVRYhZ2X+T9iURTAXz2VVIQYxowxY4wxM7wShWwVSrIvlchStopR+P/n3O0t3tqcH933/d5zzj339sFxBjE40dOz3dbxwegbI/z09AEE221tsf9STJyC4IEIYh2t83+aTVEAht+t8l+aRPC4TVJoNYfBi4tms3b6+voIhjw2fG1JcAFRq9WwoJxv2wdB7GMrBcgE5e18Pr8fy7ZSxPgBRKVSe35+fmyUy2VsiMU+WU8A85UKCBpIcAKCbDZrOYURkkDlqfpcbSDDyUl+HxmspjB84HQ6nyCq1epbo3F3d0INVlNwyniIO2RYW0OGbkv8kNOZTnd1ddXr9cvLt5e3WzDEicHanRjGfB3zl5cvL7e39/fxeBwMFmvA/E79LwQIrmSGtX0rwzSUTqd3dtYBv7k5PLyCOEOGXWywUEP3MObXAUcCMBSvzs62qMFKDV0if4ji+rpYLIJhaxcbzPlxzK+uLi5ubBz2AS8z7MbXzGepX+L7+gqFAjLsIcM5TsL8Un9T8oVSqbS3t7dSTFGDqYDxCwtzc8DnmCGVOscGs4MckvjC3OzsbC6XWyqVNsFAFLs/zFog7Y/w+RwyLG1Khs9mLZDx8/PRaDSHFZugoAZjvlvOR6Mzvb29x8fHS0s4CWRInf80FIwp+RlqOMaGoxWkMG5Cv5Kfnp5KJpMJ0QCKlHETfsl5wKeQIJkARYYYQGHEj0j8DOGxAAyZDBja25HAqAlj8v0RHgqFiAAZlrHhyGXUAjUPIYiG5XZQGDWhT1F/iPKCMCk3tOs/rXbF/qGQz+9wu12dvDAZDCbCCSRACpuuwE3nj/C8h/3dFhCCwWA4HIlEkMGhK+iU56/4zI0F4Qwx6AogAbw/4t3KJRsxkBzsOrxXxqvOSm5wa9EQDjpAwHeqV11YgAyR7zqCUfEAfFrLAZZCJKJ9kHapgZoHZReLiHi01jmX2AC/doYu0aBdwyi7QSG9LvvENmiterUnQB50GsLaNTjEG6A/6zwzaBXJTlA9AlLYBGYYUa15WAJJfZ7jBphBvcsAK0BvzHB4BWRACtUKK4A34jnOzwzv9/GzBPQvOw67QA3vNvIyPmDMw2ERQTCsPMkA8NPoDdObISl8NAdFCh46gkZHyMImCEQh/7aX8gPmPLxbzCBl20l+RKwUwIpACrFfbsZr31JVeAVqoJfGy34E9F/bd+GhBgEPg53xGs+YXriYAU0NT/PXeUW0w8EM3Zyr9f3lOTg4fqq1+lm4icDHEd7kBmiFF58mz9n40IDL2r8yqiQCvN/+D+aPcPZ+RgT3AAAAAElFTkSuQmCC"
  cat > "$marker_html" <<EOF
<!doctype html>
<!--playwright-browser-mcp working-folder: ${PWD}-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Playwright Browser MCP</title>
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
  main{position:relative;z-index:1;width:100%;max-width:600px;display:flex;flex-direction:column;gap:1rem}
  .head{display:flex;align-items:center;gap:.85rem;margin-bottom:.55rem}
  .mark{width:40px;height:40px;flex:0 0 auto;border-radius:50%;position:relative;
    background:conic-gradient(from 210deg, oklch(0.62 0.2 280), oklch(0.72 0.14 205), oklch(0.66 0.17 330), oklch(0.62 0.2 280));
    box-shadow:0 0 0 1px oklch(1 0 0/.12), 0 10px 32px -8px oklch(0.62 0.2 280/.5);}
  .mark::after{content:"";position:absolute;inset:7px;border-radius:50%;background:var(--bg);}
  .head .title{display:flex;flex-direction:column;justify-content:center;}
  .head h1{font-size:1.06rem;font-weight:650;letter-spacing:-.01em;margin:0;}
  .head h1 .title-link{color:inherit;text-decoration:none;}
  .head h1 .title-link:hover{text-decoration:underline;}
  .head h1 .ver{margin-left:.4rem;font-size:.78rem;font-weight:500;color:var(--muted);opacity:.7;letter-spacing:0;}
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
  .field-top{display:flex;align-items:center;gap:.6rem;margin-bottom:.55rem;}
  .field-label{font-size:.82rem;font-weight:600;color:var(--ink);margin:0;}
  .field-top .actions{margin-left:auto;display:flex;gap:.45rem;}
  .path{display:flex;align-items:baseline;font-family:var(--mono);font-size:.92rem;
    line-height:1.5;margin:0;white-space:nowrap;overflow:hidden;}
  .path .dir{color:oklch(0.6 0.02 274);flex:0 0 auto;}
  .path .name{color:var(--ink);font-weight:700;font-size:1.05rem;flex:0 0 auto;}
  .btn,.copy{font-family:var(--sans);font-size:.72rem;cursor:pointer;flex:0 0 auto;
    border:1px solid var(--line);border-radius:6px;padding:.2rem .55rem;text-decoration:none;
    display:inline-flex;align-items:center;gap:.35rem;
    transition:color .15s ease,border-color .15s ease,background .15s ease;}
  .copy{color:var(--muted);background:transparent;}
  .btn{color:var(--ink);background:var(--panel-2);}
  .btn:hover,.copy:hover{color:var(--ink);border-color:var(--faint);background:var(--panel-2);}
  .btn:focus-visible,.copy:focus-visible{outline:2px solid var(--mint);outline-offset:2px;}
  .copy.ok{color:var(--mint);border-color:color-mix(in oklch, var(--mint), transparent 50%);}
  .menu{position:relative;}
  .menu>summary{list-style:none;}
  .menu>summary::-webkit-details-marker{display:none;}
  .menu>summary::after{content:"";width:.4em;height:.4em;margin-left:.15rem;
    border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;
    transform:translateY(-1px) rotate(45deg);opacity:.8;}
  .menu[open]>summary::after{transform:translateY(1px) rotate(-135deg);}
  .menu-list{position:absolute;right:0;top:calc(100% + .35rem);z-index:20;min-width:9rem;
    display:flex;flex-direction:column;padding:.3rem;gap:.1rem;
    background:var(--panel-2);border:1px solid var(--line);border-radius:9px;
    box-shadow:0 16px 40px -16px oklch(0 0 0/.7);}
  .menu-list a{display:flex;align-items:center;gap:.5rem;font-size:.78rem;line-height:1;
    color:var(--ink);text-decoration:none;border-radius:6px;padding:.36rem .5rem;
    transition:background .12s ease;}
  .menu-list a:hover{background:color-mix(in oklch, var(--line), transparent 35%);}
  .menu-list a:focus-visible{outline:2px solid var(--mint);outline-offset:-2px;}
  .ic{width:16px;height:16px;flex:0 0 auto;border-radius:4px;display:block;object-fit:contain;}
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
      <h1><a class="title-link" href="https://www.npmjs.com/package/playwright-browser-mcp" target="_blank" rel="noopener">Playwright&nbsp;Browser&nbsp;MCP</a><span class="ver">${e_version}</span></h1>
      <p class="tag">One shared browser, wired to your MCP session.</p>
    </div>
    <span class="status"><i></i>connected</span>
  </header>

  <section class="card">
    <div class="field-top">
      <p class="field-label">Working Folder</p>
      <span class="actions">
        <button class="copy" data-copy="folder">Copy</button>
      </span>
    </div>
    <code class="path" id="folder" data-full="${e_folder_full}"><span class="dir" data-dir="${e_folder_dir}">${e_folder_dir}</span><span class="name">${e_folder_name}</span></code>
  </section>

  <section class="card">
    <div class="field-top">
      <p class="field-label">Browser Profile</p>
      <span class="actions">
        <button class="copy" data-copy="profile">Copy</button>
      </span>
    </div>
    <code class="path" id="profile" data-full="${e_profile_full}"><span class="dir" data-dir="${e_profile_dir}">${e_profile_dir}</span><span class="name">${e_profile_name}</span></code>
  </section>

  <section class="card">
    <div class="bar">
      <h2>Configuration</h2>
      <span class="src">.playwright-mcp/config.yml</span>
      <span class="actions">
        <details class="menu">
          <summary class="btn" title="Edit config.yml in an editor">Edit</summary>
          <div class="menu-list">
            <a href="vscode://file${enc_cfg}"><img class="ic" alt="" src="${ic_vscode}">VS Code</a>
            <a href="cursor://file${enc_cfg}"><img class="ic" alt="" src="${ic_cursor}">Cursor</a>
            <a href="windsurf://file${enc_cfg}"><img class="ic" alt="" src="${ic_windsurf}">Windsurf</a>
            <a href="antigravity://file${enc_cfg}"><img class="ic" alt="" src="${ic_antigravity}">Antigravity</a>
          </div>
        </details>
        <button class="copy" data-copy="yaml">Copy</button>
      </span>
    </div>
    <pre class="yaml" id="yaml">${e_cfg_content}</pre>
  </section>
</main>
<script>
// Editor dropdown: close after picking an item, and on any outside click.
for (const m of document.querySelectorAll(".menu")) {
  m.addEventListener("click", (e) => {
    if (e.target.closest(".menu-list a")) m.removeAttribute("open");
  });
}
document.addEventListener("click", (e) => {
  for (const m of document.querySelectorAll(".menu[open]")) {
    if (!m.contains(e.target)) m.removeAttribute("open");
  }
});
for (const b of document.querySelectorAll(".copy")) {
  b.addEventListener("click", async () => {
    const el = document.getElementById(b.dataset.copy);
    if (!el || !navigator.clipboard) return;
    try {
      await navigator.clipboard.writeText((el.dataset.full || el.textContent).trim());
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
// Middle-truncate the dimmed parent-dir part with an ellipsis so the (bold)
// basename always stays visible on one line. The full path is preserved in the
// code element's data-full for copying. Binary-search the widest head…tail that
// fits, recompute on resize.
function fitDirs() {
  for (const code of document.querySelectorAll(".path")) {
    const dir = code.querySelector(".dir");
    if (!dir) continue;
    const full = dir.dataset.dir;
    dir.textContent = full;
    if (code.scrollWidth <= code.clientWidth) continue;
    let lo = 1, hi = full.length, best = "…";
    while (lo <= hi) {
      const k = (lo + hi) >> 1;
      const head = Math.ceil(k / 2), tail = Math.floor(k / 2);
      dir.textContent = full.slice(0, head) + "…" + full.slice(full.length - tail);
      if (code.scrollWidth <= code.clientWidth) { best = dir.textContent; lo = k + 1; }
      else { hi = k - 1; }
    }
    dir.textContent = best;
  }
}
fitDirs();
window.addEventListener("resize", fitDirs);
</script>
</body>
</html>
EOF

  # Dedupe + prune. The marker now lives under "Application Support" — its path
  # contains a space, which Chrome reports percent-encoded (Application%20Support)
  # in /json/list. A literal grep on the raw path therefore never matches, so
  # every run opened a fresh marker tab (the tab flood). Match by DECODING each
  # tab URL (robust to encoding differences), keep one marker tab, close extras
  # (this also cleans up any pre-existing flood), and open one only if none exist.
  # OPEN-BEFORE-CLOSE: the fresh marker is opened first, then the old marker tabs
  # are closed (excluding the new id). This avoids a zero-page window — closing
  # the only page first risks the browser quitting on last-window-close (and even
  # without a quit it makes the marker visibly blink closed→reopened every run).
  local file_url encoded
  file_url="file://${marker_abs}"
  encoded="$(urlencode "$file_url")"

  if MARKER_PORT="$PORT" MARKER_FILE="$file_url" MARKER_URL="$encoded" \
    node - <<'NODE' 2>/dev/null
const http = require("http");
const port = process.env.MARKER_PORT;
const target = process.env.MARKER_FILE; // decoded file:// URL to match against
const encoded = process.env.MARKER_URL; // percent-encoded URL to open with
const req = (path, method) =>
  new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port, path, method }, (res) => {
      let d = "";
      res.on("data", (c) => (d += c));
      res.on("end", () => resolve({ status: res.statusCode, body: d }));
    });
    r.on("error", reject);
    r.end();
  });
const ok = (r) => r.status >= 200 && r.status < 400; // treat 4xx/5xx as failure
const sameUrl = (u) => {
  try {
    return decodeURIComponent(u) === target;
  } catch {
    return u === target || u === encoded;
  }
};
(async () => {
  let tabs = [];
  try {
    const list = await req("/json/list", "GET");
    if (ok(list)) tabs = JSON.parse(list.body);
  } catch {
    tabs = [];
  }
  const markers = tabs.filter((t) => sameUrl(t.url || ""));
  const freshLaunch = markers.length === 0;
  // Open a fresh marker FIRST, recording its id so we never close it below.
  // Modern Chrome needs PUT on /json/new; older accepts GET. The marker HTML is
  // rewritten each run so it tracks the current config.yml, but CDP HTTP has no
  // navigate/reload verb — recreating the tab is how we force the freshly
  // written file to reload. Opening before closing keeps at least one page alive
  // at all times (no last-window-close quit, no visible blink).
  let openedId = null;
  const tryOpen = async (method) => {
    try {
      const r = await req("/json/new?" + encoded, method);
      if (ok(r)) {
        try {
          openedId = JSON.parse(r.body).id;
        } catch {}
        return true;
      }
    } catch {}
    return false;
  };
  const opened = (await tryOpen("PUT")) || (await tryOpen("GET"));
  if (!opened) process.exit(1);
  // Now close every OLD marker tab (excluding the one just opened). This forces
  // the stale earlier-loaded copies away and prunes any pre-existing flood.
  for (const t of markers) {
    if (t.id === openedId) continue;
    try {
      await req("/json/close/" + t.id, "GET");
    } catch {}
  }
  // Only on a fresh launch do we reuse the blank "New Tab" the browser opens:
  // close the leftover blank page now that the marker is open, so the user is
  // left with just the marker, not New Tab + it. On a re-run against an already
  // running browser there is no such blank page to reclaim, and closing one
  // would nuke the user's own New Tab — so skip the cleanup in that case.
  if (!freshLaunch) process.exit(0);
  const isBlank = (u) =>
    u === "" ||
    u === "about:blank" ||
    u.startsWith("chrome://newtab") ||
    u.startsWith("chrome://new-tab-page") ||
    u.startsWith("edge://newtab");
  try {
    const after = JSON.parse((await req("/json/list", "GET")).body);
    for (const t of after) {
      if (t.id === openedId) continue;
      if (t.type === "page" && isBlank(t.url || "")) {
        try {
          await req("/json/close/" + t.id, "GET");
        } catch {}
      }
    }
  } catch {}
  process.exit(0);
})();
NODE
  then
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
case "$MCP_EFF" in
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
    #   --caps <all groups>     enable every opt-in capability group on top of
    #                           core: config, devtools, network, pdf, storage,
    #                           testing, vision. Notably devtools brings the video
    #                           tools (browser_start_video / _stop_video /
    #                           _video_chapter / _video_show_actions), which are
    #                           CDP-screencast based so they work over
    #                           --cdp-endpoint. Artifacts land in --output-dir.
    exec npx --yes @playwright/mcp@latest \
      --cdp-endpoint "http://127.0.0.1:${PORT}" \
      --output-dir "$OUTPUT_DIR" \
      --snapshot-mode none \
      --image-responses omit \
      --output-mode file \
      --caps config,devtools,network,pdf,storage,testing,vision
    ;;
  chrome-devtools)
    exec npx --yes chrome-devtools-mcp@latest \
      --browserUrl "http://127.0.0.1:${PORT}"
    ;;
esac

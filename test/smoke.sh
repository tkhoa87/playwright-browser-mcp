#!/usr/bin/env bash
# Lightweight smoke test for main.sh — no external test framework.
# Verifies the wrapper parses without launching a browser or an MCP server:
#   1. `bash -n` syntax check
#   2. `--help` / `-h` exit 0 and print usage
#   3. unknown flags are rejected (exit 1, nothing passed through)
set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/main.sh"

pass=0
fail=0

ok() {
  printf 'ok   - %s\n' "$1"
  pass=$((pass + 1))
}

ko() {
  printf 'FAIL - %s\n' "$1" >&2
  fail=$((fail + 1))
}

# 1. Syntax check.
if bash -n "$MAIN"; then
  ok "bash -n main.sh (syntax)"
else
  ko "bash -n main.sh (syntax)"
fi

# 2. Help exits 0 and mentions the CLI name. Run in a scratch dir so the
#    .gitignore side effect never touches the repo.
for flag in --help -h; do
  tmp="$(mktemp -d)"
  out=""
  if out="$(cd "$tmp" && bash "$MAIN" "$flag" 2>&1)"; then
    case "$out" in
      *playwright-browser-mcp*) ok "$flag exits 0 and prints usage" ;;
      *) ko "$flag exit 0 but missing usage text" ;;
    esac
  else
    ko "$flag did not exit 0"
  fi
  rm -rf "$tmp"
done

# 3. Unknown flag is rejected with a non-zero exit.
tmp="$(mktemp -d)"
if (cd "$tmp" && bash "$MAIN" --definitely-not-a-flag) >/dev/null 2>&1; then
  ko "unknown flag should exit non-zero"
else
  ok "unknown flag rejected (non-zero exit)"
fi
rm -rf "$tmp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

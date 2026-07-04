#!/usr/bin/env bash
set -u

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  for candidate in \
    "${HOME}/.local/bin/claude" \
    "${HOME}/.claude/local/claude" \
    "${HOME}/.npm-global/bin/claude" \
    /opt/homebrew/bin/claude \
    /usr/local/bin/claude; do
    [[ -x "$candidate" ]] && { CLAUDE_BIN="$candidate"; break; }
  done
fi
[[ -n "$CLAUDE_BIN" ]] || { echo "FAIL: claude is not installed" >&2; exit 1; }
REAL_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN")"
[[ -f "$REAL_BIN" ]] || { echo "FAIL: Claude binary not found: ${REAL_BIN}" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
strings -a -n 4 "$REAL_BIN" > "$TMP"
CFG_DIR="${HOME}/.config/claude-vds-proxy"
MANIFEST_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$MANIFEST_TMP"' EXIT

VERSION="$($CLAUDE_BIN --version 2>/dev/null | head -n 1)"
HASH="$(shasum -a 256 "$REAL_BIN" | awk '{print $1}')"

echo "Claude binary audit"
echo "Version: ${VERSION}"
echo "Binary: ${REAL_BIN}"
echo "SHA-256: ${HASH}"
echo

required_markers=(HTTPS_PROXY HTTP_PROXY NO_PROXY ProxyAgent)
fail=0
for marker in "${required_markers[@]}"; do
  if grep -Fq "$marker" "$TMP"; then
    echo "PASS proxy marker: ${marker}"
  else
    echo "FAIL proxy marker missing: ${marker}"
    fail=1
  fi
done

echo
echo "First-party and Claude-owned host strings:"
grep -Eio \
  '([a-z0-9-]+\.)*(anthropic\.com|claude\.ai|claude\.com|claudeusercontent\.com|clau\.de)' \
  "$TMP" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u > "$MANIFEST_TMP"
cat "$MANIFEST_TMP"

echo
echo "Auxiliary, telemetry, and feature endpoints found literally in this binary:"
for endpoint in \
  http-intake.logs.us5.datadoghq.com \
  cdn.growthbook.io \
  storage.googleapis.com \
  raw.githubusercontent.com \
  objects.githubusercontent.com \
  api.github.com; do
  if grep -Fq "$endpoint" "$TMP"; then
    echo "$endpoint"
    printf '%s\n' "$endpoint" >> "$MANIFEST_TMP"
  fi
done

echo
echo "Optional provider/MCP destinations are not a finite allowlist."
echo "MCP, WebFetch, Bedrock, Vertex, Foundry and shell commands can use user-selected hosts."
if [[ "$fail" -eq 0 ]]; then
  mkdir -p "$CFG_DIR/audits"
  sort -u "$MANIFEST_TMP" -o "$MANIFEST_TMP"
  if [[ -f "$CFG_DIR/domains-current.txt" ]]; then
    cp "$CFG_DIR/domains-current.txt" "$CFG_DIR/domains-previous.txt"
    echo
    echo "Domain changes since previous audit:"
    diff -u "$CFG_DIR/domains-previous.txt" "$MANIFEST_TMP" || true
  fi
  cp "$MANIFEST_TMP" "$CFG_DIR/domains-current.txt"
  cp "$MANIFEST_TMP" "$CFG_DIR/audits/${VERSION%% *}-${HASH}.txt"
  printf '%s\n' "$VERSION" > "$CFG_DIR/version-current.txt"
  printf '%s\n' "$HASH" > "$CFG_DIR/sha256-current.txt"
else
  mkdir -p "$CFG_DIR"
  printf 'Binary audit failed for %s (%s)\n' "$VERSION" "$HASH" > "$CFG_DIR/AUDIT_FAILED"
fi
exit "$fail"

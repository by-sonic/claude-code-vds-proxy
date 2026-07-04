#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${HOME}/.config/claude-vds-proxy/config"
MODE="check"

usage() {
  cat <<'EOF'
Usage: maintain.sh [--check | --update | --install-if-missing]

  --check               Audit current binary and verify routes (default)
  --update              Back up and update Claude, then audit and verify
  --install-if-missing  Install official native latest only when absent
EOF
}

case "${1:---check}" in
  --check) MODE="check" ;;
  --update) MODE="update" ;;
  --install-if-missing) MODE="install-if-missing" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ -f "$CFG" ]] || { echo "Missing proxy config: ${CFG}" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CFG"
PROXY="http://127.0.0.1:${LOCAL_PORT}"

find_claude() {
  local found=""
  found="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    for candidate in \
      "${HOME}/.local/bin/claude" \
      "${HOME}/.claude/local/claude" \
      "${HOME}/.npm-global/bin/claude" \
      /opt/homebrew/bin/claude \
      /usr/local/bin/claude; do
      [[ -x "$candidate" ]] && { found="$candidate"; break; }
    done
  fi
  printf '%s' "$found"
}

proxy_env() {
  env \
    -u ANTHROPIC_BASE_URL \
    -u NODE_EXTRA_CA_CERTS \
    -u NODE_USE_SYSTEM_CA \
    -u SSL_CERT_FILE \
    -u NODE_TLS_REJECT_UNAUTHORIZED \
    HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" \
    NO_PROXY="localhost,127.0.0.1,::1" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
    DISABLE_FEEDBACK_COMMAND=1 DISABLE_GROWTHBOOK=1 \
    DISABLE_AUTOUPDATER=1 \
    "$@"
}

assert_proxy() {
  local actual
  actual="$(curl -fsS --proxy "$PROXY" --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [[ "$actual" == "$EXPECTED_EXIT_IP" ]] \
    || { echo "Proxy exit '${actual:-unreachable}' != '${EXPECTED_EXIT_IP}'" >&2; exit 1; }
}

install_native_latest() {
  local installer
  installer="$(mktemp)"
  trap 'rm -f "$installer"' RETURN
  curl -fsSL --proxy "$PROXY" --max-time 60 https://claude.ai/install.sh -o "$installer"
  proxy_env /bin/bash "$installer" latest
  rm -f "$installer"
  trap - RETURN
}

detect_method() {
  local binary="$1" real
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$binary")"
  case "$real" in
    *'/node_modules/@anthropic-ai/claude-code/'*) echo npm ;;
    /opt/homebrew/*|/usr/local/Caskroom/*) echo homebrew ;;
    *'/.local/share/claude/'*|*'/.claude/local/'*) echo native ;;
    *) echo unknown ;;
  esac
}

find_npm() {
  local npm_bin
  npm_bin="$(command -v npm 2>/dev/null || true)"
  if [[ -z "$npm_bin" ]]; then
    for candidate in "${HOME}"/.nvm/versions/node/*/bin/npm "${HOME}/.npm-global/bin/npm"; do
      [[ -x "$candidate" ]] && npm_bin="$candidate"
    done
  fi
  printf '%s' "$npm_bin"
}

backup_binary() {
  local binary="$1" real version hash dir
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$binary")"
  version="$($binary --version 2>/dev/null | head -n 1 | tr ' /' '__')"
  hash="$(shasum -a 256 "$real" | awk '{print $1}')"
  dir="${HOME}/.config/claude-vds-proxy/backups/$(date +%Y%m%d%H%M%S)-${version}"
  mkdir -p "$dir"
  cp -p "$real" "$dir/claude.bin"
  printf '%s\n' "$real" > "$dir/original-path.txt"
  printf '%s\n' "$hash" > "$dir/sha256.txt"
  echo "Backup: ${dir}"
  find "${HOME}/.config/claude-vds-proxy/backups" -mindepth 1 -maxdepth 1 -type d \
    -print | sort -r | awk 'NR>2' | while read -r old; do rm -rf "$old"; done
}

update_claude() {
  local binary="$1" method npm_bin brew_bin
  method="$(detect_method "$binary")"
  echo "Install method: ${method}"
  backup_binary "$binary"
  case "$method" in
    npm)
      npm_bin="$(find_npm)"
      [[ -n "$npm_bin" ]] || { echo "npm installation detected, but npm was not found" >&2; exit 1; }
      proxy_env "$npm_bin" install -g @anthropic-ai/claude-code@latest
      ;;
    homebrew)
      brew_bin="$(command -v brew 2>/dev/null || true)"
      [[ -n "$brew_bin" ]] || brew_bin="/opt/homebrew/bin/brew"
      if "$brew_bin" list --cask claude-code@latest >/dev/null 2>&1; then
        proxy_env "$brew_bin" upgrade --cask claude-code@latest
      else
        proxy_env "$brew_bin" upgrade --cask claude-code
      fi
      ;;
    native)
      proxy_env "$binary" update
      ;;
    unknown)
      echo "Unknown installation type; reinstalling official native latest."
      install_native_latest
      ;;
  esac
}

assert_proxy
CLAUDE_BIN="$(find_claude)"

if [[ -z "$CLAUDE_BIN" ]]; then
  if [[ "$MODE" == "check" ]]; then
    echo "Claude Code is not installed. Run with --install-if-missing." >&2
    exit 1
  fi
  echo "Claude Code not found; installing official native latest through VDS..."
  install_native_latest
  hash -r
  CLAUDE_BIN="$(find_claude)"
  [[ -n "$CLAUDE_BIN" ]] || { echo "Installer finished, but claude is still not found" >&2; exit 1; }
elif [[ "$MODE" == "update" ]]; then
  before="$($CLAUDE_BIN --version 2>/dev/null | head -n 1)"
  update_claude "$CLAUDE_BIN"
  hash -r
  CLAUDE_BIN="$(find_claude)"
  after="$($CLAUDE_BIN --version 2>/dev/null | head -n 1)"
  echo "Version: ${before} -> ${after}"
fi

"$ROOT/audit-installed-claude.sh"
"$ROOT/verify.sh"

rm -f "${HOME}/.config/claude-vds-proxy/AUDIT_FAILED"
echo "Maintenance completed successfully."

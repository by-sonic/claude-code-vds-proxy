#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge-audits]

Removes the macOS tunnel, launchd jobs, proxy environment, generated commands,
and marked profile/hosts blocks. Audit history is kept unless --purge-audits
is supplied. Squid on the VDS is not removed automatically.
EOF
}

PURGE=0
case "${1:-}" in
  "") ;;
  --purge-audits) PURGE=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo "Run uninstall.sh on macOS" >&2; exit 2; }

USER_UID="$(id -u)"
AGENTS="${HOME}/Library/LaunchAgents"
BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/claude-vds-proxy"
CFG_DIR="${HOME}/.config/claude-vds-proxy"

for label in com.claude-vds-proxy.tunnel com.claude-vds-proxy.env com.claude-vds-proxy.maintenance; do
  launchctl bootout "gui/${USER_UID}/${label}" 2>/dev/null || true
  rm -f "${AGENTS}/${label}.plist"
done

for key in HTTPS_PROXY HTTP_PROXY NO_PROXY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
  DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DISABLE_FEEDBACK_COMMAND \
  CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY DISABLE_GROWTHBOOK DISABLE_AUTOUPDATER DO_NOT_TRACK; do
  launchctl unsetenv "$key" 2>/dev/null || true
done

rm -f \
  "${BIN_DIR}/claude-vds-proxy-tunnel" \
  "${BIN_DIR}/claude-vds-proxy-env" \
  "${BIN_DIR}/claude-vds-proxy-maintain" \
  "${BIN_DIR}/claude-vds-proxy-verify" \
  "${BIN_DIR}/claude-vds-proxy-audit-installed-claude"
rm -rf "$SHARE_DIR"

profile_tmp="$(mktemp)"
awk '
  $0 == "# >>> claude-vds-proxy >>>" { skip=1; next }
  $0 == "# <<< claude-vds-proxy <<<" { skip=0; next }
  !skip { print }
' "${HOME}/.zprofile" > "$profile_tmp"
mv "$profile_tmp" "${HOME}/.zprofile"

hosts_tmp="$(mktemp)"
awk '
  $0 == "# >>> claude-vds-proxy-failsafe >>>" { skip=1; next }
  $0 == "# <<< claude-vds-proxy-failsafe <<<" { skip=0; next }
  !skip { print }
' /etc/hosts > "$hosts_tmp"
sudo cp /etc/hosts "/etc/hosts.backup-claude-vds-proxy-uninstall-$(date +%Y%m%d%H%M%S)"
sudo install -m 0644 "$hosts_tmp" /etc/hosts
rm -f "$hosts_tmp"
sudo dscacheutil -flushcache || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

if [[ "$PURGE" -eq 1 ]]; then
  rm -rf "$CFG_DIR"
else
  rm -f "${CFG_DIR}/config" "${CFG_DIR}/AUDIT_FAILED"
fi

echo "Mac configuration removed. Restart Cursor and terminal windows."
echo "Optional VDS cleanup: sudo apt-get remove --purge squid && sudo rm -rf /etc/squid"

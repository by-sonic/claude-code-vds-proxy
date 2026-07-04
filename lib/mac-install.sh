#!/usr/bin/env bash
set -euo pipefail

VDS_HOST="${1:?VDS host is required}"
SSH_USER="${2:?SSH user is required}"
SSH_PORT="${3:?SSH port is required}"
IDENTITY="${4:?Identity path is required}"
LOCAL_PORT="${5:?Local proxy port is required}"
REMOTE_PORT="${6:?Remote proxy port is required}"
EXIT_IP="${7:?Expected exit IP is required}"
MAINTENANCE="${8:-off}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "mac-install.sh must run through sudo" >&2
  exit 2
fi

MAC_USER="${SUDO_USER:?Run sudo from the target Mac account}"
MAC_UID="$(id -u "$MAC_USER")"
MAC_HOME="$(dscl . -read "/Users/${MAC_USER}" NFSHomeDirectory | awk '{print $2}')"

if [[ "$IDENTITY" == \~/* ]]; then IDENTITY="${MAC_HOME}/${IDENTITY:2}"; fi
if [[ "$IDENTITY" != /* ]]; then IDENTITY="${MAC_HOME}/${IDENTITY}"; fi
[[ -f "$IDENTITY" ]] || { echo "SSH identity not found: ${IDENTITY}" >&2; exit 1; }
[[ "$VDS_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid VDS host" >&2; exit 2; }
[[ "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid SSH user" >&2; exit 2; }
if [[ "$IDENTITY" == *$'\n'* || "$IDENTITY" == *$'\r'* || "$IDENTITY" == *"'"* \
  || "$IDENTITY" == *"<"* || "$IDENTITY" == *">"* || "$IDENTITY" == *"&"* ]]; then
  echo "Unsupported character in identity path" >&2
  exit 2
fi

PROXY="http://127.0.0.1:${LOCAL_PORT}"
BIN_DIR="${MAC_HOME}/.local/bin"
CFG_DIR="${MAC_HOME}/.config/claude-vds-proxy"
AGENTS="${MAC_HOME}/Library/LaunchAgents"
SHARE_DIR="${MAC_HOME}/.local/share/claude-vds-proxy"
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_JSON="${MAC_HOME}/.claude/settings.json"
ZPROFILE="${MAC_HOME}/.zprofile"

install -d -m 0755 -o "$MAC_USER" -g staff \
  "$BIN_DIR" "$CFG_DIR" "$AGENTS" "$SHARE_DIR" "${MAC_HOME}/.claude"

install -m 0755 -o "$MAC_USER" -g staff \
  "$KIT_ROOT/maintain.sh" \
  "$KIT_ROOT/verify.sh" \
  "$KIT_ROOT/audit-installed-claude.sh" \
  "$SHARE_DIR/"

for command in maintain verify audit-installed-claude; do
  cat > "${BIN_DIR}/claude-vds-proxy-${command}" <<EOF
#!/bin/sh
exec '${SHARE_DIR}/${command}.sh' "\$@"
EOF
  chmod 0755 "${BIN_DIR}/claude-vds-proxy-${command}"
  chown "$MAC_USER":staff "${BIN_DIR}/claude-vds-proxy-${command}"
done

{
  printf 'VDS_HOST=%q\n' "$VDS_HOST"
  printf 'SSH_USER=%q\n' "$SSH_USER"
  printf 'SSH_PORT=%q\n' "$SSH_PORT"
  printf 'IDENTITY=%q\n' "$IDENTITY"
  printf 'LOCAL_PORT=%q\n' "$LOCAL_PORT"
  printf 'REMOTE_PORT=%q\n' "$REMOTE_PORT"
  printf 'EXPECTED_EXIT_IP=%q\n' "$EXIT_IP"
} > "${CFG_DIR}/config"

cat > "${BIN_DIR}/claude-vds-proxy-tunnel" <<EOF
#!/bin/sh
exec /usr/bin/ssh \\
  -i '${IDENTITY}' \\
  -p '${SSH_PORT}' \\
  -o IdentitiesOnly=yes \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=yes \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=20 \\
  -o ServerAliveCountMax=3 \\
  -o TCPKeepAlive=yes \\
  -N -L 127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} \\
  '${SSH_USER}@${VDS_HOST}'
EOF

cat > "${BIN_DIR}/claude-vds-proxy-env" <<EOF
#!/bin/sh
set -eu
set_env() { /bin/launchctl setenv "\$1" "\$2"; }
set_env HTTPS_PROXY '${PROXY}'
set_env HTTP_PROXY '${PROXY}'
set_env NO_PROXY 'localhost,127.0.0.1,::1'
set_env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC '1'
set_env DISABLE_TELEMETRY '1'
set_env DISABLE_ERROR_REPORTING '1'
set_env DISABLE_FEEDBACK_COMMAND '1'
set_env CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY '1'
set_env DISABLE_GROWTHBOOK '1'
set_env DISABLE_AUTOUPDATER '1'
set_env DO_NOT_TRACK '1'
for key in ANTHROPIC_BASE_URL NODE_EXTRA_CA_CERTS NODE_USE_SYSTEM_CA SSL_CERT_FILE NODE_TLS_REJECT_UNAUTHORIZED; do
  /bin/launchctl unsetenv "\$key" 2>/dev/null || true
done
EOF

cat > "${AGENTS}/com.claude-vds-proxy.tunnel.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-vds-proxy.tunnel</string>
  <key>ProgramArguments</key><array><string>${BIN_DIR}/claude-vds-proxy-tunnel</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/tmp/claude-vds-proxy-tunnel.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-vds-proxy-tunnel.err</string>
</dict></plist>
EOF

cat > "${AGENTS}/com.claude-vds-proxy.env.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-vds-proxy.env</string>
  <key>ProgramArguments</key><array><string>${BIN_DIR}/claude-vds-proxy-env</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

launchctl bootout "gui/${MAC_UID}/com.claude-vds-proxy.maintenance" 2>/dev/null || true
rm -f "${AGENTS}/com.claude-vds-proxy.maintenance.plist"
if [[ "$MAINTENANCE" == "daily" || "$MAINTENANCE" == "weekly" ]]; then
  if [[ "$MAINTENANCE" == "daily" ]]; then interval=86400; else interval=604800; fi
  cat > "${AGENTS}/com.claude-vds-proxy.maintenance.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-vds-proxy.maintenance</string>
  <key>ProgramArguments</key><array>
    <string>${SHARE_DIR}/maintain.sh</string><string>--update</string>
  </array>
  <key>RunAtLoad</key><false/>
  <key>StartInterval</key><integer>${interval}</integer>
  <key>StandardOutPath</key><string>/tmp/claude-vds-proxy-maintenance.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-vds-proxy-maintenance.err</string>
</dict></plist>
EOF
  chown "$MAC_USER":staff "${AGENTS}/com.claude-vds-proxy.maintenance.plist"
fi

chmod 0755 "${BIN_DIR}/claude-vds-proxy-tunnel" "${BIN_DIR}/claude-vds-proxy-env"
chown -R "$MAC_USER":staff "$CFG_DIR"
chown "$MAC_USER":staff \
  "${BIN_DIR}/claude-vds-proxy-tunnel" "${BIN_DIR}/claude-vds-proxy-env" \
  "${AGENTS}/com.claude-vds-proxy.tunnel.plist" "${AGENTS}/com.claude-vds-proxy.env.plist"

JSON_TOOL=""
for candidate in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [[ -x "$candidate" ]] && { JSON_TOOL="$candidate"; break; }
done
[[ -n "$JSON_TOOL" ]] || { echo "Python 3 is required for safe JSON editing" >&2; exit 1; }

sudo -u "$MAC_USER" /usr/bin/env \
  CLAUDE_JSON="$CLAUDE_JSON" PROXY="$PROXY" \
  "$JSON_TOOL" <<'PY'
import json, os
from pathlib import Path

remove = {
    "ANTHROPIC_BASE_URL", "NODE_EXTRA_CA_CERTS", "NODE_USE_SYSTEM_CA",
    "SSL_CERT_FILE", "NODE_TLS_REJECT_UNAUTHORIZED",
}
add = {
    "HTTPS_PROXY": os.environ["PROXY"],
    "HTTP_PROXY": os.environ["PROXY"],
    "NO_PROXY": "localhost,127.0.0.1,::1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
    "DISABLE_GROWTHBOOK": "1",
    "DISABLE_AUTOUPDATER": "1",
    "DO_NOT_TRACK": "1",
}

def load(path):
    p = Path(path)
    if not p.exists() or not p.read_text().strip():
        return {}
    return json.loads(p.read_text())

def save(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=2) + "\n")

def merge(env):
    env = dict(env or {})
    for key in remove:
        env.pop(key, None)
    env.update(add)
    return env

claude = load(os.environ["CLAUDE_JSON"])
claude["env"] = merge(claude.get("env"))
save(os.environ["CLAUDE_JSON"], claude)
PY

touch "$ZPROFILE"
profile_tmp="$(mktemp)"
awk '
  $0 == "# >>> claude-vds-proxy >>>" { skip=1; next }
  $0 == "# <<< claude-vds-proxy <<<" { skip=0; next }
  $0 == "# >>> anthropic-fwd env >>>" { skip=1; next }
  $0 == "# <<< anthropic-fwd env <<<" { skip=0; next }
  $0 == "# >>> claude-connect-proxy env >>>" { skip=1; next }
  $0 == "# <<< claude-connect-proxy env <<<" { skip=0; next }
  !skip { print }
' "$ZPROFILE" > "$profile_tmp"
cat >> "$profile_tmp" <<EOF

# >>> claude-vds-proxy >>>
export PATH="\$HOME/.local/bin:\$PATH"
export HTTPS_PROXY='${PROXY}'
export HTTP_PROXY='${PROXY}'
export NO_PROXY='localhost,127.0.0.1,::1'
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1'
export DISABLE_TELEMETRY='1'
export DISABLE_ERROR_REPORTING='1'
export DISABLE_FEEDBACK_COMMAND='1'
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY='1'
export DISABLE_GROWTHBOOK='1'
export DISABLE_AUTOUPDATER='1'
export DO_NOT_TRACK='1'
unset ANTHROPIC_BASE_URL NODE_EXTRA_CA_CERTS NODE_USE_SYSTEM_CA SSL_CERT_FILE NODE_TLS_REJECT_UNAUTHORIZED
# <<< claude-vds-proxy <<<
EOF
install -m 0644 -o "$MAC_USER" -g staff "$profile_tmp" "$ZPROFILE"
rm -f "$profile_tmp"

# Block direct resolution of first-party hosts. CONNECT sends hostnames to VDS DNS.
hosts_tmp="$(mktemp)"
awk '
  $0 == "# >>> claude-vds-proxy-failsafe >>>" { skip=1; next }
  $0 == "# <<< claude-vds-proxy-failsafe <<<" { skip=0; next }
  $0 == "# >>> anthropic-anti-leak >>>" { skip=1; next }
  $0 == "# <<< anthropic-anti-leak <<<" { skip=0; next }
  $0 == "# >>> claude-connect-proxy-failsafe >>>" { skip=1; next }
  $0 == "# <<< claude-connect-proxy-failsafe <<<" { skip=0; next }
  !skip { print }
' /etc/hosts > "$hosts_tmp"
cat >> "$hosts_tmp" <<'EOF'

# >>> claude-vds-proxy-failsafe >>>
127.0.0.2 api.anthropic.com claude.ai claude.com platform.claude.com
127.0.0.2 downloads.claude.ai mcp-proxy.anthropic.com bridge.claudeusercontent.com
127.0.0.2 http-intake.logs.us5.datadoghq.com cdn.growthbook.io
fd00::2 api.anthropic.com claude.ai claude.com platform.claude.com
fd00::2 downloads.claude.ai mcp-proxy.anthropic.com bridge.claudeusercontent.com
fd00::2 http-intake.logs.us5.datadoghq.com cdn.growthbook.io
# <<< claude-vds-proxy-failsafe <<<
EOF
cp /etc/hosts "/etc/hosts.backup-claude-vds-proxy-$(date +%Y%m%d%H%M%S)"
install -m 0644 "$hosts_tmp" /etc/hosts
rm -f "$hosts_tmp"
dscacheutil -flushcache || true
killall -HUP mDNSResponder 2>/dev/null || true

# Remove the legacy local TLS interception setup if present.
for label in com.user.anthropic-socat com.user.anthropic-socat6 com.user.anthropic-pf-updater; do
  launchctl bootout "system/${label}" 2>/dev/null || true
done
for label in com.user.claude-http-proxy com.user.claude-proxy-env; do
  launchctl bootout "gui/${MAC_UID}/${label}" 2>/dev/null || true
done
rm -f \
  "${AGENTS}/com.user.claude-http-proxy.plist" \
  "${AGENTS}/com.user.claude-proxy-env.plist"

for label in com.claude-vds-proxy.tunnel com.claude-vds-proxy.env; do
  launchctl bootout "gui/${MAC_UID}/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/${MAC_UID}" "${AGENTS}/${label}.plist"
done
if [[ -f "${AGENTS}/com.claude-vds-proxy.maintenance.plist" ]]; then
  launchctl bootstrap "gui/${MAC_UID}" "${AGENTS}/com.claude-vds-proxy.maintenance.plist"
fi
launchctl asuser "$MAC_UID" /usr/bin/sudo -u "$MAC_USER" "${BIN_DIR}/claude-vds-proxy-env"

for _ in {1..30}; do
  actual="$(sudo -u "$MAC_USER" curl -fsS --proxy "$PROXY" --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ "$actual" == "$EXIT_IP" ]] && break
  sleep 1
done
[[ "${actual:-}" == "$EXIT_IP" ]] || { echo "Local tunnel exit check failed" >&2; exit 1; }

echo "PASS: Mac CONNECT proxy exit is ${actual}"

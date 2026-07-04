#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VDS_HOST=""
SSH_USER="root"
SSH_PORT="22"
IDENTITY="${HOME}/.ssh/id_ed25519"
LOCAL_PORT="18080"
REMOTE_PORT="3128"
EXPECTED_EXIT_IP=""
MAINTENANCE="off"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --vds HOST --identity ~/.ssh/KEY [options]

Options:
  --vds HOST            VDS IP address or hostname (required)
  --ssh-user USER       SSH user with root or passwordless sudo (default: root)
  --ssh-port PORT       SSH port (default: 22)
  --identity PATH       Existing private SSH key
  --local-port PORT     Mac localhost proxy port (default: 18080)
  --remote-port PORT    VDS localhost Squid port (default: 3128)
  --expect-exit-ip IP   Refuse setup if VDS egress differs
  --maintenance MODE    off, daily, or weekly auto-update+audit (default: off)
  -h, --help            Show help

The script never accepts or stores passwords. Confirm SSH key login first.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vds) VDS_HOST="${2:?}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:?}"; shift 2 ;;
    --expect-exit-ip) EXPECTED_EXIT_IP="${2:?}"; shift 2 ;;
    --maintenance) MAINTENANCE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "Run install.sh on macOS" >&2; exit 2; }
[[ -n "$VDS_HOST" ]] || { echo "--vds is required" >&2; usage >&2; exit 2; }
[[ "$MAINTENANCE" == "off" || "$MAINTENANCE" == "daily" || "$MAINTENANCE" == "weekly" ]] \
  || { echo "Invalid maintenance mode: ${MAINTENANCE}" >&2; exit 2; }
if [[ "$IDENTITY" == \~/* ]]; then IDENTITY="${HOME}/${IDENTITY:2}"; fi
[[ -f "$IDENTITY" ]] || { echo "SSH identity not found: ${IDENTITY}" >&2; exit 1; }
[[ "$VDS_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid VDS host" >&2; exit 2; }
[[ "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid SSH user" >&2; exit 2; }
[[ -z "$EXPECTED_EXIT_IP" || "$EXPECTED_EXIT_IP" =~ ^[A-Fa-f0-9:.]+$ ]] || { echo "Invalid expected exit IP" >&2; exit 2; }
if [[ "$IDENTITY" == *$'\n'* || "$IDENTITY" == *$'\r'* || "$IDENTITY" == *"'"* \
  || "$IDENTITY" == *"<"* || "$IDENTITY" == *">"* || "$IDENTITY" == *"&"* ]]; then
  echo "Unsupported character in identity path" >&2
  exit 2
fi

for port in "$SSH_PORT" "$LOCAL_PORT" "$REMOTE_PORT"; do
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "Invalid port: ${port}" >&2
    exit 2
  fi
done
(( REMOTE_PORT >= 1024 )) || { echo "Remote proxy port must be 1024 or higher" >&2; exit 2; }

SSH_OPTS=(
  -i "$IDENTITY"
  -p "$SSH_PORT"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes
)

echo "[1/5] Checking SSH key login..."
/usr/bin/ssh "${SSH_OPTS[@]}" "${SSH_USER}@${VDS_HOST}" true

echo "[2/5] Uploading the private VDS proxy installer..."
REMOTE_SCRIPT="/tmp/claude-vds-proxy-setup-$$.sh"
/usr/bin/scp -P "$SSH_PORT" -i "$IDENTITY" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  "$ROOT/lib/vds-setup.sh" "${SSH_USER}@${VDS_HOST}:${REMOTE_SCRIPT}"

echo "[3/5] Installing Squid on VDS localhost only..."
if [[ "$SSH_USER" == "root" ]]; then
  remote_cmd="chmod 700 '${REMOTE_SCRIPT}' && '${REMOTE_SCRIPT}' '${REMOTE_PORT}' '${EXPECTED_EXIT_IP}'"
else
  remote_cmd="chmod 700 '${REMOTE_SCRIPT}' && sudo -n '${REMOTE_SCRIPT}' '${REMOTE_PORT}' '${EXPECTED_EXIT_IP}'"
fi
# shellcheck disable=SC2029 # The command contains only values validated above.
remote_output="$(/usr/bin/ssh "${SSH_OPTS[@]}" "${SSH_USER}@${VDS_HOST}" "$remote_cmd")"
printf '%s\n' "$remote_output"
EXIT_IP="$(awk -F= '/^CLAUDE_PROXY_EXIT_IP=/{print $2}' <<<"$remote_output" | tail -n 1)"
[[ -n "$EXIT_IP" ]] || { echo "Could not detect VDS exit IP" >&2; exit 1; }

echo "[4/5] Installing the Mac SSH tunnel and fail-closed settings..."
/usr/bin/sudo /bin/bash "$ROOT/lib/mac-install.sh" \
  "$VDS_HOST" "$SSH_USER" "$SSH_PORT" "$IDENTITY" \
  "$LOCAL_PORT" "$REMOTE_PORT" "$EXIT_IP" "$MAINTENANCE"

echo "[5/5] Installing Claude when absent, then auditing and verifying..."
"${HOME}/.local/share/claude-vds-proxy/maintain.sh" --install-if-missing

echo
echo "Installed. Restart Cursor and all terminal windows before using Claude Code."
echo "VDS exit IP: ${EXIT_IP}"
echo "Maintenance: ${MAINTENANCE}"

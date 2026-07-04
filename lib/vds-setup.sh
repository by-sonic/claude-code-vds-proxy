#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-3128}"
EXPECTED_IP="${2:-}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "vds-setup.sh must run as root" >&2
  exit 2
fi

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "Invalid Squid port: ${PORT}" >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y squid ca-certificates curl

CONF="/etc/squid/squid.conf"
[[ -f "$CONF" ]] && cp "$CONF" "${CONF}.backup-$(date +%Y%m%d%H%M%S)"

cat > "$CONF" <<EOF
# Managed by claude-vds-proxy-kit. Private: SSH forwarding only.
http_port 127.0.0.1:${PORT}

acl local_ssh src 127.0.0.1/32 ::1
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow local_ssh
http_access deny all

cache deny all
access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log
visible_hostname claude-private-connect-proxy
forwarded_for delete
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
EOF

squid -k parse
systemctl enable squid
systemctl restart squid

for _ in {1..30}; do
  EXIT_IP="$(curl -fsS --proxy "http://127.0.0.1:${PORT}" --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$EXIT_IP" ]]; then
    if [[ -n "$EXPECTED_IP" && "$EXIT_IP" != "$EXPECTED_IP" ]]; then
      echo "Proxy works, but exit IP ${EXIT_IP} differs from expected ${EXPECTED_IP}" >&2
      exit 1
    fi
    echo "CLAUDE_PROXY_EXIT_IP=${EXIT_IP}"
    ss -ltnp | grep "127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 1
done

echo "Squid did not pass its exit-IP check" >&2
journalctl -u squid --no-pager -n 80 >&2
exit 1

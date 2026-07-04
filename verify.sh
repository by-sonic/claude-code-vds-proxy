#!/usr/bin/env bash
set -u

CFG="${HOME}/.config/claude-vds-proxy/config"
[[ -f "$CFG" ]] || { echo "FAIL: missing ${CFG}" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CFG"

PROXY="http://127.0.0.1:${LOCAL_PORT}"
SSH=(/usr/bin/ssh -i "$IDENTITY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes "${SSH_USER}@${VDS_HOST}")
PASS=0; FAIL=0; WARN=0
ok() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf 'WARN: %s\n' "$*"; }

if nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
  ok "local proxy listens"
else
  fail "local proxy is down"
fi
actual="$(curl -fsS --proxy "$PROXY" --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ "$actual" == "$EXPECTED_EXIT_IP" ]]; then
  ok "exit IP is ${actual}"
else
  fail "exit '${actual}' != '${EXPECTED_EXIT_IP}'"
fi

tls="$(curl -sS -v --proxy "$PROXY" --max-time 15 -o /dev/null https://api.anthropic.com/ 2>&1 || true)"
if grep -q 'SSL certificate verify ok' <<<"$tls"; then
  ok "public Anthropic TLS verifies"
else
  fail "Anthropic TLS did not verify"
fi
if grep -qi 'self.signed' <<<"$tls"; then
  fail "self-signed interception detected"
else
  ok "no TLS interception"
fi

api_code="$(curl -sS --proxy "$PROXY" --max-time 15 -o /dev/null -w '%{http_code}' \
  https://api.anthropic.com/v1/messages \
  -H 'x-api-key: deliberately-invalid-route-test' \
  -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' \
  --data '{"model":"claude-3-5-haiku-latest","max_tokens":1,"messages":[{"role":"user","content":"route test"}]}' \
  2>/dev/null || true)"
if [[ "$api_code" == "401" ]]; then
  ok "fake-key request reached Anthropic"
else
  warn "fake-key returned HTTP ${api_code:-none}"
fi

if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 https://api.anthropic.com/ >/dev/null 2>&1; then
  fail "direct Anthropic request succeeded"
else
  ok "direct Anthropic request fails closed"
fi

before="$("${SSH[@]}" 'wc -l < /var/log/squid/access.log' 2>/dev/null || true)"
domains=()
manifest="${HOME}/.config/claude-vds-proxy/domains-current.txt"
if [[ -f "$manifest" ]]; then
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    case "$domain" in
      *staging*|preview.*|*.ant.dev|*.fedstart.com) continue ;;
    esac
    domains+=("$domain")
    [[ "${#domains[@]}" -ge 80 ]] && break
  done < "$manifest"
else
  domains=(api.anthropic.com claude.ai platform.claude.com downloads.claude.ai)
fi
for domain in "${domains[@]}"; do
  curl -sS --proxy "$PROXY" --connect-timeout 4 --max-time 8 -o /dev/null "https://${domain}/" 2>/dev/null || true
done
if [[ "$before" =~ ^[0-9]+$ ]]; then
  logs="$("${SSH[@]}" "sed -n '$((before+1)),\$p' /var/log/squid/access.log" 2>/dev/null || true)"
  for domain in "${domains[@]}"; do
    if grep -Fq "CONNECT ${domain}:443" <<<"$logs"; then
      ok "VDS logged ${domain}"
    else
      fail "VDS did not log ${domain}"
    fi
  done
else
  fail "cannot read VDS Squid log"
fi

for key in HTTPS_PROXY HTTP_PROXY; do
  value="$(launchctl getenv "$key" 2>/dev/null || true)"
  if [[ "$value" == "$PROXY" ]]; then
    ok "launchctl ${key}"
  else
    fail "launchctl ${key}='${value}'"
  fi
done
for key in ANTHROPIC_BASE_URL NODE_TLS_REJECT_UNAUTHORIZED; do
  value="$(launchctl getenv "$key" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    ok "legacy ${key} unset"
  else
    fail "legacy ${key} still set"
  fi
done

echo "Summary: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]

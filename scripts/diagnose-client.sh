#!/usr/bin/env bash
# Server-side diagnostics when Happ clients have no internet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env_file "${PROJECT_DIR}/.env"

SERVER_IP="${SERVER_IP:-}"
PANEL_PORT="${PANEL_PORT:-38471}"
SUB_PORT="${SUB_PORT:-2096}"
SUB_PATH="${SUB_PATH:-/sub/family}"
HY2_PORT="${HY2_PORT:-4443}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"

FAIL=0
WARN=0

log() { printf '[diagnose] %s\n' "$*"; }
warn() { printf '[diagnose] WARN: %s\n' "$*"; WARN=1; }
fail() { printf '[diagnose] FAIL: %s\n' "$*" >&2; FAIL=1; }

normalize_sub_path() {
  local path="${1:-/sub/family}"
  [[ "${path}" == /* ]] || path="/${path}"
  [[ "${path}" == */ ]] || path="${path}/"
  printf '%s' "${path}"
}

check_xray_logs() {
  log "=== Xray / container logs (last errors) ==="
  if ! docker ps --format '{{.Names}}' | grep -q happroxy_3xui; then
    fail "Container happroxy_3xui is not running."
    return
  fi

  local errors
  errors="$(docker logs happroxy_3xui --tail 200 2>&1 | grep -E 'ERROR|Failed to start|exit status' | tail -n 10 || true)"
  if [[ -n "${errors}" ]]; then
    fail "Xray errors in logs:"
    printf '%s\n' "${errors}"
    log "Fix: sudo bash scripts/repair-panel.sh"
  else
    log "No recent Xray ERROR lines in docker logs."
  fi

  if docker logs happroxy_3xui --tail 50 2>&1 | grep -q "Xray.*started"; then
    log "Xray started message found in recent logs."
  else
    warn "Xray 'started' not seen in last 50 log lines — proxy may be down."
  fi
}

check_ports() {
  log "=== Listening ports ==="
  local p
  for p in "${PANEL_PORT}" "${SUB_PORT}" "${HY2_PORT}" "${SS_PORT}" "${VMESS_PORT}"; do
    if ss -tln 2>/dev/null | grep -q ":${p} "; then
      log "TCP :${p} — listening"
    else
      fail "TCP :${p} — NOT listening"
    fi
  done
  if ss -uln 2>/dev/null | grep -q ":${HY2_PORT} "; then
    log "UDP :${HY2_PORT} — listening"
  else
    warn "UDP :${HY2_PORT} — not listening (Hysteria2 may fail; use Shadowsocks)"
  fi
}

check_subscription() {
  log "=== Subscription content ==="
  local sub_path body
  sub_path="$(normalize_sub_path "${SUB_PATH}")"

  # Try sub port first, then panel port path
  body="$(curl -fsS --max-time 10 "http://127.0.0.1:${SUB_PORT}${sub_path}" 2>/dev/null | head -c 4096 || true)"
  if [[ -z "${body}" ]]; then
    body="$(curl -fsS --max-time 10 "http://127.0.0.1:${PANEL_PORT}${sub_path}" 2>/dev/null | head -c 4096 || true)"
  fi

  if [[ -z "${body}" ]]; then
    fail "Could not fetch subscription (add a client and subId in panel)."
    log "Open in panel: Клиенты → Sub-ссылки"
    return
  fi

  if [[ -n "${SERVER_IP}" ]] && grep -q "${SERVER_IP}" <<<"${body}"; then
    log "Subscription contains public IP ${SERVER_IP} — OK"
  elif grep -qE '127\.0\.0\.1|localhost' <<<"${body}"; then
    fail "Subscription contains 127.0.0.1 — fix URI обратного прокси / inbound address strategy"
  else
    warn "Could not verify public IP in subscription body."
  fi

  grep -q 'hy2://\|hysteria2://\|hy2://' <<<"${body}" && log "Found Hysteria2 link" || warn "No hy2:// link in subscription"
  grep -q 'ss://' <<<"${body}" && log "Found Shadowsocks link" || warn "No ss:// link in subscription"
  grep -q 'vmess://' <<<"${body}" && log "Found VMess link" || warn "No vmess:// link in subscription"
}

check_server_outbound() {
  log "=== Server outbound internet ==="
  if curl -4 -fsS --max-time 8 https://1.1.1.1 >/dev/null 2>&1 || curl -4 -fsS --max-time 8 https://api.ipify.org >/dev/null 2>&1; then
    log "Server has outbound internet — OK"
  else
    fail "Server cannot reach the internet — fix VM network first"
  fi
}

check_inbounds_db() {
  log "=== Inbounds in database ==="
  local db
  db="$(find "${DATA_DB_DIR}" -maxdepth 1 -name '*.db' 2>/dev/null | head -n1 || true)"
  [[ -n "${db}" && -f "${db}" ]] || { warn "DB not found"; return; }

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${db}" "SELECT id, remark, protocol, port, enable FROM inbounds;" 2>/dev/null | while read -r line; do
      log "  inbound: ${line}"
    done || true
    local bad
    bad="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE port=8443;" 2>/dev/null || echo 0)"
    if [[ "${bad}" -gt 0 ]]; then
      warn "Inbound on 8443 still present — may break Xray. Run: sudo bash scripts/repair-panel.sh"
    fi
  fi
}

print_client_hints() {
  log "=== Client (Happ) checklist ==="
  cat <<EOF
1. Disconnect Happ — интернет на ПК должен вернуться.
2. В Happ выберите Shadowsocks (8388), не Hysteria2 — проверьте интернет.
3. Временно очистите «Правила маршрутизации» в панели (GlobalProxy ломает всё, если прокси не работает).
4. Обновите подписку в Happ после любых правок на сервере.
5. На Windows: режим TUN — попробуйте Proxy mode в настройках Happ.
6. Self-signed HY2: в Happ может потребоваться разрешить insecure / skip verify для сертификата.
EOF
}

main() {
  log "Diagnosing Happ client connectivity..."
  [[ -n "${SERVER_IP}" ]] || warn "SERVER_IP not set in .env"

  check_xray_logs
  check_ports
  check_server_outbound
  check_inbounds_db
  check_subscription
  print_client_hints

  if [[ "${FAIL}" -gt 0 ]]; then
    log "Result: FAILED (${FAIL} critical issue(s), ${WARN} warning(s))"
    exit 1
  fi
  if [[ "${WARN}" -gt 0 ]]; then
    log "Result: OK with warnings — try Shadowsocks on client"
    exit 0
  fi
  log "Result: server looks OK — problem likely on client routing or protocol choice"
}

main "$@"

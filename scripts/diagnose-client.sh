#!/usr/bin/env bash
# Server-side diagnostics when Happ clients have no internet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/public-url.sh"
load_env_file "${PROJECT_DIR}/.env"

SERVER_IP="${SERVER_IP:-}"
PANEL_PORT="${PANEL_PORT:-38471}"
SUB_PORT="${SUB_PORT:-2096}"
SUB_PATH="${SUB_PATH:-/sub/family}"
VLESS_PORT="${VLESS_PORT:-4433}"
HY2_PORT="${HY2_PORT:-4443}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"
ENABLE_LEGACY_INBOUNDS="${ENABLE_LEGACY_INBOUNDS:-true}"

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
  for p in "${PANEL_PORT}" "${SUB_PORT}" "${VLESS_PORT}"; do
    if ss -tln 2>/dev/null | grep -q ":${p} "; then
      log "TCP :${p} — listening"
    else
      fail "TCP :${p} — NOT listening"
    fi
  done
  if [[ "${ENABLE_LEGACY_INBOUNDS}" == "true" ]]; then
    for p in "${HY2_PORT}" "${SS_PORT}" "${VMESS_PORT}"; do
      if ss -tln 2>/dev/null | grep -q ":${p} "; then
        log "TCP :${p} — listening"
      else
        fail "TCP :${p} — NOT listening"
      fi
    done
    if ss -uln 2>/dev/null | grep -q ":${HY2_PORT} "; then
      log "UDP :${HY2_PORT} — listening"
    else
      warn "UDP :${HY2_PORT} — not listening (Hysteria2 may fail; use VLESS or Shadowsocks)"
    fi
  fi
}

check_subscription() {
  log "=== Subscription content ==="
  local db sub_id raw decoded body_file="/tmp/happroxy_sub.txt"
  sub_id=""

  if db="$(find_db_file 2>/dev/null)"; then
    sub_id="$(get_first_sub_id "${db}" 2>/dev/null || true)"
    if command -v sqlite3 >/dev/null 2>&1; then
      log "  subEnable=$(get_setting_value "${db}" "subEnable") subPath=$(get_setting_value "${db}" "subPath")"
      log "  subURI=$(get_setting_value "${db}" "subURI")"
    fi
  fi

  if [[ -z "${sub_id}" ]]; then
    fail "No enabled client subId in database — add a client in panel (Клиенты)."
    return
  fi

  log "Using client subId: ${sub_id}"
  if ! raw="$(fetch_subscription_raw "${sub_id}" "${db:-}")"; then
    fail "Could not fetch subscription for subId ${sub_id} (last: ${SUB_FETCH_URL:-?} HTTP ${SUB_FETCH_CODE:-?})"
    log "Try: bash scripts/show-urls.sh"
    log "Fix:  sudo bash scripts/repair-panel.sh"
    return
  fi

  printf '%s' "${raw}" > "${body_file}"
  if ! decoded="$(decode_subscription_file "${body_file}" 2>/dev/null)"; then
    fail "Subscription response not decodable (${#raw} bytes from $(cat /tmp/happroxy_sub_url.txt 2>/dev/null || echo '?'))"
    log "Preview: $(head -c 120 "${body_file}" | tr '\n' ' ')"
    return
  fi

  if [[ -z "${decoded}" ]]; then
    fail "Subscription decoded to empty body"
    return
  fi

  log "Decoded subscription preview:"
  printf '%s\n' "${decoded}" | head -n 5 | sed 's/^/[diagnose]   /'

  if [[ -n "${SERVER_IP}" ]] && grep -q "${SERVER_IP}" <<<"${decoded}"; then
    log "Subscription contains public IP ${SERVER_IP} — OK"
  elif [[ -n "${PANEL_DOMAIN:-}" ]] && grep -q "${PANEL_DOMAIN}" <<<"${decoded}"; then
    log "Subscription contains domain ${PANEL_DOMAIN} — OK"
  elif grep -qE '127\.0\.0\.1|localhost' <<<"${decoded}"; then
    fail "Subscription contains 127.0.0.1 — run: sudo bash scripts/repair-panel.sh, then refresh Happ"
  else
    warn "Public IP ${SERVER_IP:-?} not found in subscription links"
  fi

  grep -qE 'vless://' <<<"${decoded}" && log "Found VLESS link" || warn "No vless:// link — run: sudo bash scripts/setup-vless-reality.sh"
  if [[ -n "${db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local vless_links
    vless_links="$(sqlite3 "${db}" "
      SELECT COUNT(*)
      FROM client_inbounds ci
      JOIN inbounds i ON i.id = ci.inbound_id
      JOIN clients c ON c.id = ci.client_id
      WHERE i.port=${VLESS_PORT} AND c.sub_id='${sub_id}';
    " 2>/dev/null || echo 0)"
    if [[ "${vless_links}" -eq 0 ]] && ! grep -qE 'vless://' <<<"${decoded}"; then
      warn "Client ${sub_id} not linked to vless-reality in client_inbounds — re-run setup-vless-reality.sh"
    elif [[ "${vless_links}" -gt 0 ]]; then
      log "client_inbounds: ${sub_id} → vless-reality (${vless_links})"
    fi
  fi
  if [[ "${ENABLE_LEGACY_INBOUNDS}" == "true" ]]; then
    grep -qE 'hy2://|hysteria2://' <<<"${decoded}" && log "Found Hysteria2 link" || warn "No hy2:// link in subscription"
    grep -q 'ss://' <<<"${decoded}" && log "Found Shadowsocks link" || warn "No ss:// link in subscription"
    grep -q 'vmess://' <<<"${decoded}" && log "Found VMess link" || warn "No vmess:// link in subscription"
  fi
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
  local db bad localhost_listen
  db="$(find_db_file 2>/dev/null || true)"
  [[ -n "${db}" && -f "${db}" ]] || { warn "DB not found"; return; }

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${db}" "SELECT id, remark, protocol, port, COALESCE(listen,''), enable FROM inbounds;" 2>/dev/null | while read -r line; do
      log "  inbound: ${line}"
    done || true

    localhost_listen="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE listen IN ('127.0.0.1','localhost') AND enable=1;" 2>/dev/null || echo 0)"
    if [[ "${localhost_listen}" -gt 0 ]]; then
      fail "Inbound listens on 127.0.0.1 only — external clients cannot connect. Clear «Слушать» in panel."
    fi

    bad="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE port=8443 AND enable=1;" 2>/dev/null || echo 0)"
    if [[ "${bad}" -gt 0 ]]; then
      warn "Inbound on 8443 enabled — if TLS cert missing, Xray fails. Run: sudo bash scripts/repair-panel.sh"
    fi
  fi
}

check_external_ports() {
  log "=== External reachability (from server to public IP) ==="
  [[ -n "${SERVER_IP}" ]] || { warn "SERVER_IP not set — skip external port probe"; return; }

  local port
  if timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${VLESS_PORT}" 2>/dev/null; then
    log "TCP ${SERVER_IP}:${VLESS_PORT} — OK"
  else
    fail "TCP ${SERVER_IP}:${VLESS_PORT} — NOT reachable (UFW / listen / routing)"
  fi
  if [[ "${ENABLE_LEGACY_INBOUNDS}" == "true" ]]; then
    local db hy2_enabled
    db="$(find_db_file 2>/dev/null || true)"
    hy2_enabled="1"
    if [[ -n "${db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
      hy2_enabled="$(sqlite3 "${db}" "SELECT enable FROM inbounds WHERE port=${HY2_PORT} LIMIT 1;" 2>/dev/null || echo 1)"
    fi
    for port in "${SS_PORT}" "${VMESS_PORT}"; do
      if timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${port}" 2>/dev/null; then
        log "TCP ${SERVER_IP}:${port} — OK"
      else
        fail "TCP ${SERVER_IP}:${port} — NOT reachable (UFW / listen / routing)"
      fi
    done
    if [[ "${hy2_enabled}" == "1" ]]; then
      if timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${HY2_PORT}" 2>/dev/null; then
        log "TCP ${SERVER_IP}:${HY2_PORT} — OK"
      else
        warn "TCP ${SERVER_IP}:${HY2_PORT} — NOT reachable (HY2 inbound disabled or UFW)"
      fi
    else
      log "HY2 port ${HY2_PORT} — skipped (inbound disabled in DB)"
    fi
  fi
}

check_live_connections() {
  log "=== Recent proxy activity (connect Happ, then re-run) ==="
  local hits
  hits="$(docker logs happroxy_3xui --tail 120 2>&1 | grep -Ei 'accepted|inbound|rejected|invalid' | tail -n 8 || true)"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" | sed 's/^/[diagnose]   /'
  else
    warn "No recent accept/reject lines — client may not reach the server at all"
  fi
}

print_client_hints() {
  log "=== Client (Happ) checklist ==="
  cat <<EOF
1. Disconnect Happ — интернет на ПК должен вернуться.
2. В Happ сначала VLESS (${VLESS_PORT}, Reality), затем Shadowsocks (${SS_PORT}) если legacy включён.
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
  check_external_ports
  check_server_outbound
  check_inbounds_db
  check_subscription
  check_live_connections
  print_client_hints

  if [[ "${FAIL}" -gt 0 ]]; then
    log "Result: FAILED (${FAIL} critical issue(s), ${WARN} warning(s))"
    exit 1
  fi
  if [[ "${WARN}" -gt 0 ]]; then
    log "Result: OK with warnings — try VLESS or Shadowsocks on client"
    exit 0
  fi
  log "Result: server looks OK — problem likely on client routing or protocol choice"
}

main "$@"

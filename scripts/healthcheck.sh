#!/usr/bin/env bash
# Verify 3X-UI panel and proxy ports are reachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/db.sh"
  load_env_file "${PROJECT_DIR}/.env"
fi

SERVER_IP="${SERVER_IP:-127.0.0.1}"
PANEL_PORT="${PANEL_PORT:-38471}"
HY2_PORT="${HY2_PORT:-4443}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"
TROJAN_PORT="${TROJAN_PORT:-8443}"
SUB_PORT="${SUB_PORT:-2096}"
ENABLE_TROJAN="${ENABLE_TROJAN:-false}"

FAIL=0

log() { printf '[healthcheck] %s\n' "$*"; }
warn() { printf '[healthcheck] WARN: %s\n' "$*"; }
fail() { printf '[healthcheck] FAIL: %s\n' "$*" >&2; FAIL=1; }

check_container() {
  cd "${PROJECT_DIR}"
  if docker compose ps --status running 2>/dev/null | grep -q happroxy_3xui; then
    log "Container happroxy_3xui is running."
  elif docker ps --format '{{.Names}}' | grep -q happroxy_3xui; then
    log "Container happroxy_3xui is running."
  else
    fail "Container happroxy_3xui is not running."
  fi
}

check_tcp_port() {
  local host="$1"
  local port="$2"
  local label="$3"

  if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    log "${label}: TCP ${host}:${port} — OK"
  else
    fail "${label}: TCP ${host}:${port} — not reachable"
  fi
}

check_udp_port() {
  local port="$1"
  local label="$2"

  if ss -ulpn 2>/dev/null | grep -q ":${port} "; then
    log "${label}: UDP :${port} — listening"
  else
    warn "${label}: UDP :${port} — not detected (may be normal until first client connects)"
  fi
}

check_panel_http() {
  local web_path="/" db code url
  if db="$(find_db_file 2>/dev/null || true)"; then
    web_path="$(get_panel_web_path "${db}")"
  fi

  url="http://127.0.0.1:${PANEL_PORT}${web_path}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}" 2>/dev/null || echo "000")"

  if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
    log "Panel HTTP ${url} — ${code}"
  elif [[ "${code}" == "404" && "${web_path}" == "/" ]]; then
    warn "Panel HTTP ${url} — 404 (custom webBasePath? TCP check still validates service)"
  else
    fail "Panel HTTP ${url} — ${code}"
  fi
}

check_subscription_sample() {
  local sub_path="${SUB_PATH:-/sub/family}"
  [[ "${sub_path}" == */ ]] || sub_path="${sub_path}/"
  local url="http://127.0.0.1:${SUB_PORT}${sub_path}test"

  log "Subscription probe: ${url} (expect 404/200 without valid subId)"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}" 2>/dev/null || echo "000")"
  if [[ "${code}" != "000" ]]; then
    log "Subscription service on :${SUB_PORT} — HTTP ${code}"
  else
    warn "Subscription port ${SUB_PORT} not responding"
  fi
}

main() {
  log "Starting health check..."

  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker not found."
    exit 1
  fi

  check_container
  check_panel_http
  check_tcp_port "${SERVER_IP}" "${PANEL_PORT}" "Panel"
  check_tcp_port "127.0.0.1" "${HY2_PORT}" "Hysteria2"
  check_udp_port "${HY2_PORT}" "Hysteria2"
  check_tcp_port "127.0.0.1" "${SS_PORT}" "Shadowsocks"
  check_tcp_port "127.0.0.1" "${VMESS_PORT}" "VMess"

  if [[ "${ENABLE_TROJAN}" == "true" ]]; then
    check_tcp_port "127.0.0.1" "${TROJAN_PORT}" "Trojan"
  fi

  check_subscription_sample

  if [[ "${FAIL}" -eq 0 ]]; then
    log "All critical checks passed."
    exit 0
  fi

  log "Some checks failed. Review inbounds in 3X-UI panel."
  exit 1
}

main "$@"

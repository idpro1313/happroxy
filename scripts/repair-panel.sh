#!/usr/bin/env bash
# Fix broken 3X-UI settings (subListen bind loop, Trojan TLS) without using the web panel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[repair-panel] %s\n' "$*"; }
warn() { printf '[repair-panel] WARN: %s\n' "$*"; }
die() { printf '[repair-panel] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/repair-panel.sh"
  fi
}

ensure_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    return
  fi
  log "Installing sqlite3..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3
}

find_db_file() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"

  local candidates=(
    "${DATA_DB_DIR}/x-ui.db"
    "${DATA_DB_DIR}/3x-ui.db"
    "${DATA_DB_DIR}/db.sqlite"
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      printf '%s' "${f}"
      return 0
    fi
  done

  # Fallback: any .db in data dir
  local found
  found="$(find "${DATA_DB_DIR}" -maxdepth 1 -type f -name '*.db' 2>/dev/null | head -n1 || true)"
  if [[ -n "${found}" ]]; then
    printf '%s' "${found}"
    return 0
  fi

  return 1
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

set_setting() {
  local db="$1" key="$2" value="$3"
  local esc
  esc="$(sql_escape "${value}")"
  sqlite3 "${db}" "UPDATE settings SET value='${esc}' WHERE key='${key}';"
  if [[ "$(sqlite3 "${db}" "SELECT changes();")" -eq 0 ]]; then
    sqlite3 "${db}" "INSERT INTO settings (key, value) VALUES ('${key}', '${esc}');"
  fi
}

get_setting() {
  local db="$1" key="$2"
  sqlite3 "${db}" "SELECT value FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null || true
}

normalize_sub_path() {
  local path="${1:-/sub/family}"
  [[ "${path}" == /* ]] || path="/${path}"
  [[ "${path}" == */ ]] || path="${path}/"
  printf '%s' "${path}"
}

ensure_certs() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  local key="${DATA_CERT_DIR}/selfsigned.key"
  local crt="${DATA_CERT_DIR}/selfsigned.crt"

  if [[ -f "${key}" && -f "${crt}" ]]; then
    log "TLS certificates OK: ${DATA_CERT_DIR}"
    return
  fi

  local ip="${SERVER_IP:-}"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ -n "${ip}" ]] || ip="127.0.0.1"

  log "Generating self-signed certificate for ${ip}..."
  mkdir -p "${DATA_CERT_DIR}"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${crt}" \
    -subj "/CN=${ip}" \
    -addext "subjectAltName=IP:${ip}" 2>/dev/null
  chmod 600 "${key}"
}

backup_db() {
  local db="$1"
  local backup_dir
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  backup_dir="${DATA_BACKUP_DIR}"
  mkdir -p "${backup_dir}"
  local dest="${backup_dir}/x-ui_pre_repair_$(date +%Y%m%d_%H%M%S).db"
  cp -a "${db}" "${dest}"
  log "Database backup: ${dest}"
}

fix_subscription_settings() {
  local db="$1"
  local sub_path sub_uri

  sub_path="$(normalize_sub_path "${SUB_PATH:-/sub/family}")"
  sub_uri="http://${SERVER_IP}:${SUB_PORT:-2096}${sub_path}"

  log "Fixing subscription settings in database..."

  set_setting "${db}" "subListen" ""
  set_setting "${db}" "subPort" "${SUB_PORT:-2096}"
  set_setting "${db}" "subPath" "${sub_path}"
  set_setting "${db}" "subURI" "${sub_uri}"
  set_setting "${db}" "subEnable" "true"

  if [[ -n "${SUB_PROFILE_TITLE:-}" ]]; then
    set_setting "${db}" "subTitle" "${SUB_PROFILE_TITLE}"
  fi
  if [[ -n "${SUB_UPDATE_INTERVAL:-}" ]]; then
    set_setting "${db}" "subUpdates" "${SUB_UPDATE_INTERVAL}"
  fi

  log "  subListen  = (empty)"
  log "  subPort    = ${SUB_PORT:-2096}"
  log "  subPath    = ${sub_path}"
  log "  subURI     = ${sub_uri}"
}

remove_broken_inbounds() {
  local db="$1"
  local before after

  if ! sqlite3 "${db}" ".tables" 2>/dev/null | grep -q inbounds; then
    warn "Table inbounds not found — skipping inbound cleanup."
    return
  fi

  before="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE port=8443;" 2>/dev/null || echo 0)"

  # Trojan on 8443 without cert breaks Xray (common misconfiguration).
  sqlite3 "${db}" "DELETE FROM inbounds WHERE port=8443;" 2>/dev/null || true

  after="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE port=8443;" 2>/dev/null || echo 0)"
  if [[ "${before}" -gt "${after}" ]]; then
    log "Removed inbound(s) on port 8443 (broken Trojan TLS)."
  else
    log "No inbound on port 8443 to remove."
  fi
}

open_sub_port_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  local port="${SUB_PORT:-2096}"
  ufw allow "${port}/tcp" comment '3X-UI subscription' >/dev/null 2>&1 || ufw allow "${port}/tcp"
  log "UFW: allowed TCP ${port} (subscription)"
}

wait_for_http() {
  local url="$1"
  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${SERVER_IP}" ]] || die "Set SERVER_IP in .env"
  fi

  PANEL_PORT="${PANEL_PORT:-38471}"
  SUB_PORT="${SUB_PORT:-2096}"

  ensure_sqlite3

  local db
  db="$(find_db_file)" || die "3X-UI database not found under ${DATA_DIR:-/opt/happdata}/db/"

  log "Using database: ${db}"
  log "Stopping container to avoid crash loop during repair..."
  docker compose stop 2>/dev/null || docker stop happroxy_3xui 2>/dev/null || true

  backup_db "${db}"
  fix_subscription_settings "${db}"
  remove_broken_inbounds "${db}"
  ensure_certs
  open_sub_port_firewall

  log "Starting container..."
  docker compose up -d

  local panel_url="http://${SERVER_IP}:${PANEL_PORT}/"
  local sub_base="http://${SERVER_IP}:${SUB_PORT}$(normalize_sub_path "${SUB_PATH:-/sub/family}")"

  log "Waiting for panel at ${panel_url} ..."
  if wait_for_http "http://127.0.0.1:${PANEL_PORT}/"; then
    log "Panel is up."
  else
    warn "Panel not responding yet — check: docker logs happroxy_3xui --tail 30"
  fi

  cat <<EOF

================================================================================
Repair complete.

Panel (HTTP):     ${panel_url}
Subscription base: ${sub_base}<subId>

If the panel still loops, run:
  docker logs happroxy_3xui --tail 30

Then:
  bash scripts/healthcheck.sh
================================================================================

EOF
}

main "$@"

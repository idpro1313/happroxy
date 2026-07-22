#!/usr/bin/env bash
# Bootstrap VLESS Reality inbound in 3X-UI (Phase 2.1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[setup-vless] %s\n' "$*"; }
warn() { printf '[setup-vless] WARN: %s\n' "$*" >&2; }
die() { printf '[setup-vless] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/setup-vless-reality.sh"
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

backup_db() {
  local db="$1"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  mkdir -p "${DATA_BACKUP_DIR}"
  local dest="${DATA_BACKUP_DIR}/x-ui_pre_vless_$(date +%Y%m%d_%H%M%S).db"
  cp -a "${db}" "${dest}"
  log "Database backup: ${dest}"
}

ensure_reality_keys() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/reality-keys.sh"

  if [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]]; then
    log "Using REALITY_* keys from .env"
    return 0
  fi

  log "Generating Reality x25519 key pair..."
  generate_reality_keypair || die "Failed to generate Reality keys"
  set_env_kv "${PROJECT_DIR}/.env" "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY}"
  set_env_kv "${PROJECT_DIR}/.env" "REALITY_PUBLIC_KEY" "${REALITY_PUBLIC_KEY}"
  log "Saved REALITY_PRIVATE_KEY and REALITY_PUBLIC_KEY to .env"
}

ensure_short_id() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/reality-keys.sh"

  if [[ -n "${REALITY_SHORT_ID:-}" ]]; then
    return 0
  fi
  REALITY_SHORT_ID="$(generate_reality_short_id 8)"
  set_env_kv "${PROJECT_DIR}/.env" "REALITY_SHORT_ID" "${REALITY_SHORT_ID}"
  log "Generated REALITY_SHORT_ID=${REALITY_SHORT_ID}"
}

open_vless_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  ufw allow "${VLESS_PORT}/tcp" comment 'VLESS Reality' >/dev/null 2>&1 \
    || ufw allow "${VLESS_PORT}/tcp"
  log "UFW: allowed TCP ${VLESS_PORT} (VLESS Reality)"
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  VLESS_PORT="${VLESS_PORT:-4433}"
  REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"
  REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
  ENABLE_LEGACY_INBOUNDS="${ENABLE_LEGACY_INBOUNDS:-true}"

  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${SERVER_IP}" ]] || die "Set SERVER_IP in .env"
  fi

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/prompt.sh"

  ensure_sqlite3
  ensure_reality_keys
  ensure_short_id

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  local db template py_result
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/db.sh"
  db="$(find_db_file)" || die "3X-UI database not found — run install.sh first"

  log "Using database: ${db}"
  log "Stopping container..."
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/compose.sh"
  compose_stop "${PROJECT_DIR}" 2>/dev/null || docker stop happroxy_3xui 2>/dev/null || true

  backup_db "${db}"

  template="${PROJECT_DIR}/config/inbound-vless-reality.json.template"
  [[ -f "${template}" ]] || die "Missing ${template}"

  py_result="$(python3 "${SCRIPT_DIR}/lib/vless-inbound.py" \
    "${db}" "${template}" \
    "${VLESS_PORT}" "${REALITY_DEST}" "${REALITY_SNI}" \
    "${REALITY_PRIVATE_KEY}" "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}")"

  log "Inbound ${py_result}"

  set_env_kv "${PROJECT_DIR}/.env" "VLESS_PORT" "${VLESS_PORT}"
  set_env_kv "${PROJECT_DIR}/.env" "REALITY_DEST" "${REALITY_DEST}"
  set_env_kv "${PROJECT_DIR}/.env" "REALITY_SNI" "${REALITY_SNI}"
  set_env_kv "${PROJECT_DIR}/.env" "ENABLE_LEGACY_INBOUNDS" "${ENABLE_LEGACY_INBOUNDS}"

  open_vless_firewall

  log "Starting container with VLESS port ${VLESS_PORT}..."
  compose_up "${PROJECT_DIR}" --force-recreate

  sleep 3
  if docker logs happroxy_3xui --tail 30 2>&1 | grep -qE 'ERROR|Failed to start'; then
    warn "Xray errors after start — check: docker logs happroxy_3xui --tail 50"
    warn "Fallback: sudo bash scripts/repair-panel.sh"
  else
    log "Container started."
  fi

  local addr="${PANEL_DOMAIN:-${SERVER_IP}}"
  cat <<EOF

================================================================================
VLESS Reality inbound configured.

Port:        ${VLESS_PORT}/tcp
Reality SNI: ${REALITY_SNI}
Dest:        ${REALITY_DEST}
Address:     ${addr} (set in panel: Стратегия адреса → domain or IP)

Legacy inbounds (SS/VMess/HY2): ${ENABLE_LEGACY_INBOUNDS}

Next steps:
  1. bash scripts/healthcheck.sh
  2. bash scripts/diagnose-client.sh   — expect vless:// in subscription
  3. Refresh subscription in Happ → connect via VLESS (not SS)
  4. When all devices OK:
       bash scripts/generate-crypto-subscription.sh
       sudo bash scripts/migrate-phase2.sh --dry-run
       sudo bash scripts/migrate-phase2.sh --apply

If VLESS fails, SS/VMess remain available while ENABLE_LEGACY_INBOUNDS=true.
================================================================================

EOF
}

main "$@"

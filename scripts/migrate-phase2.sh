#!/usr/bin/env bash
# Disable legacy inbounds (SS/VMess/HY2) after VLESS Reality is verified in Happ.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[migrate-phase2] %s\n' "$*"; }
warn() { printf '[migrate-phase2] WARN: %s\n' "$*" >&2; }
die() { printf '[migrate-phase2] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/migrate-phase2.sh --dry-run|--apply"
  fi
}

ensure_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    return
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3
}

list_legacy_inbounds() {
  local db="$1"
  sqlite3 -separator '|' "${db}" \
    "SELECT id, remark, protocol, port, enable FROM inbounds WHERE port IN (${SS_PORT}, ${VMESS_PORT}, ${HY2_PORT}) ORDER BY port;" \
    2>/dev/null || true
}

disable_legacy_inbounds() {
  local db="$1"
  sqlite3 "${db}" \
    "UPDATE inbounds SET enable=0 WHERE port IN (${SS_PORT}, ${VMESS_PORT}, ${HY2_PORT});" 2>/dev/null
  sqlite3 "${db}" \
    "SELECT changes();" 2>/dev/null || echo 0
}

remove_legacy_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  local port
  for port in "${HY2_PORT}" "${SS_PORT}" "${VMESS_PORT}"; do
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
  done
  log "UFW: removed legacy rules for ${SS_PORT}, ${VMESS_PORT}, ${HY2_PORT} (if present)"
}

main() {
  local mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mode=dry-run; shift ;;
      --apply) mode=apply; shift ;;
      -h|--help)
        cat <<EOF
Usage:
  sudo bash scripts/migrate-phase2.sh --dry-run
  sudo bash scripts/migrate-phase2.sh --apply

Disables SS/VMess/HY2 inbounds after VLESS Reality works on all family devices.
Sets ENABLE_LEGACY_INBOUNDS=false in .env and restarts container.

After --apply:
  bash scripts/generate-crypto-subscription.sh
  Re-import encrypted subscription in Happ on each device.
EOF
        exit 0
        ;;
      *) die "Unknown option: $1 (use --dry-run or --apply)" ;;
    esac
  done

  [[ -n "${mode}" ]] || die "Specify --dry-run or --apply"

  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  SS_PORT="${SS_PORT:-8388}"
  VMESS_PORT="${VMESS_PORT:-16888}"
  HY2_PORT="${HY2_PORT:-4443}"
  VLESS_PORT="${VLESS_PORT:-4433}"

  ensure_sqlite3

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/db.sh"
  local db
  db="$(find_db_file)" || die "3X-UI database not found"

  local vless_count
  vless_count="$(sqlite3 "${db}" "SELECT COUNT(*) FROM inbounds WHERE port=${VLESS_PORT} AND enable=1 AND protocol='vless';" 2>/dev/null || echo 0)"
  if [[ "${vless_count}" -eq 0 ]]; then
    die "No enabled VLESS inbound on port ${VLESS_PORT}. Run: sudo bash scripts/setup-vless-reality.sh"
  fi

  log "Enabled VLESS inbound on port ${VLESS_PORT}: OK"
  log "Legacy inbounds to disable (port | remark | protocol | enable):"
  list_legacy_inbounds "${db}" | while read -r line; do
    [[ -n "${line}" ]] && log "  ${line}"
  done

  if [[ "${mode}" == "dry-run" ]]; then
    cat <<EOF

Dry-run only — no changes made.

When ready:
  sudo bash scripts/migrate-phase2.sh --apply
EOF
    exit 0
  fi

  require_root

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  local backup="${DATA_BACKUP_DIR}/x-ui_pre_migrate_$(date +%Y%m%d_%H%M%S).db"
  cp -a "${db}" "${backup}"
  log "Database backup: ${backup}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/compose.sh"
  compose_stop "${PROJECT_DIR}" 2>/dev/null || docker stop happroxy_3xui 2>/dev/null || true

  local changed
  changed="$(disable_legacy_inbounds "${db}")"
  log "Disabled ${changed} legacy inbound row(s)"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/prompt.sh"
  set_env_kv "${PROJECT_DIR}/.env" "ENABLE_LEGACY_INBOUNDS" "false"

  remove_legacy_ufw

  log "Restarting container..."
  compose_up "${PROJECT_DIR}" --force-recreate

  cat <<EOF

================================================================================
Phase 2 migration applied.

Legacy inbounds (SS ${SS_PORT}, VMess ${VMESS_PORT}, HY2 ${HY2_PORT}): disabled
VLESS Reality (${VLESS_PORT}): active
ENABLE_LEGACY_INBOUNDS=false in .env

Next:
  1. bash scripts/healthcheck.sh
  2. bash scripts/generate-crypto-subscription.sh
  3. Re-import happ://crypt5/... in Happ on each device
  4. bash scripts/generate-routing-deeplink.sh — update routing if needed

Rollback: restore ${backup} and set ENABLE_LEGACY_INBOUNDS=true
================================================================================

EOF
}

main "$@"

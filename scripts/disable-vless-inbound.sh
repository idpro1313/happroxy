#!/usr/bin/env bash
# Disable VLESS Reality inbound and remove it from client subscriptions (fix Happ "EOF" after panel edits).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[disable-vless] %s\n' "$*"; }
die() { printf '[disable-vless] ERROR: %s\n' "$*" >&2; exit 1; }

RE_ENABLE=false

usage() {
  cat <<EOF
Usage: sudo bash scripts/disable-vless-inbound.sh [--re-enable]

Disables vless-reality inbound and unlinks clients so subscription contains
only SS/VMess (fixes Happ "Ошибка запуска ядра: EOF" from broken vless:// lines).

  --re-enable   Run setup-vless-reality.sh instead (turn VLESS back on)

After disable:
  1. Refresh or re-import subscription in Happ (delete + add URL again)
  2. Clear "Правила маршрутизации" in Happ temporarily
  3. Connect ss-fallback or vmess-tcp
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/disable-vless-inbound.sh"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --re-enable) RE_ENABLE=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

disable_vless() {
  local db="$1"
  local vless_id unlinked enabled

  vless_id="$(sqlite3 "${db}" "
    SELECT id FROM inbounds
    WHERE protocol='vless' OR remark='vless-reality'
    ORDER BY id DESC LIMIT 1;
  " 2>/dev/null || true)"

  if [[ -z "${vless_id}" ]]; then
    log "No VLESS inbound in database — nothing to disable."
    return 0
  fi

  sqlite3 "${db}" "UPDATE inbounds SET enable=0 WHERE id=${vless_id};"
  enabled="$(sqlite3 "${db}" "SELECT enable FROM inbounds WHERE id=${vless_id};")"
  log "Inbound id=${vless_id} enable=${enabled}"

  if sqlite3 "${db}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='client_inbounds';" | grep -q 1; then
    unlinked="$(sqlite3 "${db}" "SELECT COUNT(*) FROM client_inbounds WHERE inbound_id=${vless_id};")"
    sqlite3 "${db}" "DELETE FROM client_inbounds WHERE inbound_id=${vless_id};"
    log "Removed ${unlinked} client_inbounds link(s) to VLESS"
  fi
}

main() {
  parse_args "$@"
  require_root
  cd "${PROJECT_DIR}"

  if [[ "${RE_ENABLE}" == "true" ]]; then
    log "Re-enabling VLESS Reality..."
    exec bash "${SCRIPT_DIR}/setup-vless-reality.sh"
  fi

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/db.sh"
  ensure_sqlite3() {
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 required"
  }
  ensure_sqlite3

  local db
  db="$(find_db_file)" || die "Database not found"

  log "Using database: ${db}"
  disable_vless "${db}"

  if command -v python3 >/dev/null 2>&1; then
    python3 "${SCRIPT_DIR}/lib/fix-client-json.py" "${db}" "${PROJECT_DIR}/.env" | sed 's/^/[disable-vless] /'
  fi

  log "Restarting container..."
  docker restart happroxy_3xui >/dev/null
  sleep 3

  log "Verifying subscription (should NOT contain vless://)..."
  bash "${SCRIPT_DIR}/diagnose-client.sh" 2>/dev/null | grep -E 'vless://|Found VLESS|ss://|vmess://' || true

  cat <<EOF

================================================================================
VLESS disabled. Use Shadowsocks / VMess in Happ.

Happ fix for "Ошибка запуска ядра: EOF":
  1. Удалите подписку «Семейный VPN» полностью
  2. Очистите «Правила маршрутизации» у подписки
  3. Добавьте подписку заново: bash scripts/show-urls.sh
  4. Подключите ss-fallback-idprohome (не vless)

Re-enable VLESS later:
  sudo bash scripts/disable-vless-inbound.sh --re-enable
  bash scripts/fix-vless-client.sh --migrate-port 8444
================================================================================

EOF
}

main "$@"

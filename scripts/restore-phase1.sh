#!/usr/bin/env bash
# Restore Phase 1: Shadowsocks + VMess, VLESS off — как до setup-vless-reality.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[restore-phase1] %s\n' "$*"; }
die() { printf '[restore-phase1] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || return 0
  die "Run as root: sudo bash scripts/restore-phase1.sh"
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/prompt.sh"
  load_env_file "${PROJECT_DIR}/.env"

  SS_PORT="${SS_PORT:-8388}"
  VMESS_PORT="${VMESS_PORT:-16888}"

  command -v python3 >/dev/null 2>&1 || die "python3 required"

  log "Phase 1: SS :${SS_PORT} + VMess :${VMESS_PORT}, VLESS disabled"
  log "Running repair-panel (subscription, tgId, Trojan cleanup)..."
  bash "${SCRIPT_DIR}/repair-panel.sh"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/db.sh"
  local db
  db="$(find_db_file)" || die "Database not found"

  log "Restoring client_inbounds (SS + VMess, no VLESS)..."
  python3 "${SCRIPT_DIR}/lib/restore-phase1-inbounds.py" "${db}" "${SS_PORT}" "${VMESS_PORT}" \
    | sed 's/^/[restore-phase1] /'

  set_env_kv "${PROJECT_DIR}/.env" "ENABLE_LEGACY_INBOUNDS" "true"

  log "Recreating container..."
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/compose.sh"
  compose_up "${PROJECT_DIR}" --force-recreate
  sleep 3

  log "Health check..."
  bash "${SCRIPT_DIR}/healthcheck.sh" || true

  log "Subscription preview:"
  bash "${SCRIPT_DIR}/diagnose-client.sh" 2>/dev/null | grep -E 'ss://|vmess://|vless://|Found|No vless|Result' || true

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/public-url.sh"
  local sub_base sub_id
  sub_base="$(build_sub_public_base)"
  sub_id="$(get_first_sub_id "${db}" 2>/dev/null || sqlite3 "${db}" \
    "SELECT sub_id FROM clients WHERE enable=1 AND sub_id!='' LIMIT 1;" 2>/dev/null || true)"

  cat <<EOF

================================================================================
Фаза 1 восстановлена (как до VLESS Reality)

Сервер:
  • Shadowsocks  :${SS_PORT}  — основной для Happ
  • VMess        :${VMESS_PORT}
  • VLESS        — выключен

Happ на каждом устройстве:
  1. Удалите подписку «Семейный VPN»
  2. Очистите «Правила маршрутизации» (добавите позже через generate-routing-deeplink.sh)
  3. Добавьте подписку: ${sub_base}${sub_id}
  4. Подключите ss-fallback-* (Shadowsocks) — он у вас уже работал
  5. После проверки интернета: bash scripts/generate-routing-deeplink.sh → routing в Happ

VLESS / Phase 2 позже (когда понадобится):
  sudo bash scripts/setup-vless-reality.sh

Проверка: bash scripts/diagnose-client.sh
================================================================================

EOF
}

main "$@"

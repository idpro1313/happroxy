#!/usr/bin/env bash
# Minimal subscription for Happ: SS only, VLESS/VMess unlinked (fixes "Ошибка запуска ядра: EOF").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/public-url.sh"

log() { printf '[fix-happ-eof] %s\n' "$*"; }
die() { printf '[fix-happ-eof] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || return 0
  die "Run as root: sudo bash scripts/fix-happ-eof.sh"
}

get_sub_id() {
  local db="$1"
  get_first_sub_id "${db}" 2>/dev/null && return 0
  sqlite3 "${db}" "
    SELECT sub_id FROM clients
    WHERE enable=1 AND sub_id IS NOT NULL AND sub_id != ''
    ORDER BY id LIMIT 1;
  " 2>/dev/null || true
}

main() {
  require_root
  cd "${PROJECT_DIR}"
  load_env_file "${PROJECT_DIR}/.env"
  SS_PORT="${SS_PORT:-8388}"

  command -v python3 >/dev/null 2>&1 || die "python3 required"
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 required"

  local db sub_id raw decoded ss_line sub_base
  db="$(find_db_file)" || die "Database not found"

  log "Step 1: Disable VLESS inbound (if still enabled)..."
  sqlite3 "${db}" "
    UPDATE inbounds SET enable=0 WHERE protocol='vless' OR remark='vless-reality';
    DELETE FROM client_inbounds WHERE inbound_id IN (
      SELECT id FROM inbounds WHERE protocol='vless' OR remark='vless-reality'
    );
  " 2>/dev/null || true

  log "Step 2: Subscription → Shadowsocks only (unlink VMess)..."
  python3 "${SCRIPT_DIR}/lib/subscription-ss-only.py" "${db}" "${SS_PORT}" | sed 's/^/[fix-happ-eof] /'

  python3 "${SCRIPT_DIR}/lib/fix-client-json.py" "${db}" "${PROJECT_DIR}/.env" | sed 's/^/[fix-happ-eof] /'

  log "Step 3: Restart container..."
  docker restart happroxy_3xui >/dev/null
  sleep 4

  sub_id="$(get_sub_id "${db}")"
  [[ -n "${sub_id}" ]] || die "No subId in database"

  log "Step 4: Verify subscription for subId ${sub_id}..."
  if ! raw="$(fetch_subscription_raw "${sub_id}" "${db}")"; then
    die "Could not fetch subscription"
  fi
  decoded="$(decode_subscription_file <(printf '%s' "${raw}") 2>/dev/null || printf '%s' "${raw}")"

  ss_line="$(grep -E '^ss://' <<<"${decoded}" | head -n1 || true)"
  if grep -qE '^vless://|^vmess://' <<<"${decoded}"; then
    log "WARN: Subscription still contains vless/vmess:"
    printf '%s\n' "${decoded}" | sed 's/^/[fix-happ-eof]   /'
  else
    log "OK: subscription is Shadowsocks-only ($(grep -c '^ss://' <<<"${decoded}" || echo 0) link(s))"
  fi

  sub_base="$(build_sub_public_base)"

  cat <<EOF

================================================================================
Happ: «Ошибка запуска ядра: EOF»

Сервер: подписка только ss:// (VMess/VLESS отключены в выдаче).

--- На ПК (обязательно по порядку) ---

1. Полностью УДАЛИТЕ подписку «Семейный VPN» в Happ
2. Очистите «Правила маршрутизации» (если поле есть — должно быть пусто)
3. НЕ используйте happ://crypt5/... — только plain URL:
   ${sub_base}${sub_id}
4. Подключите ss-fallback-idprohome

--- Если EOF снова — импорт БЕЗ подписки ---

Happ → «+» → «Добавить вручную» / import → вставьте ОДНУ строку:

${ss_line:-ERROR: no ss:// in subscription}

--- Если и manual ss:// даёт EOF ---

Проблема в Happ или SS2022 на вашей версии:
  • Обновите Happ: https://www.happ.su/
  • Переустановите Happ
  • Попробуйте v2rayN (Windows) с той же ss:// строкой
  • Windows: добавьте Happ в исключения антивируса

Вернуть VMess/VLESS позже: link clients in panel → setup-vless-reality.sh

Проверка: bash scripts/diagnose-client.sh
================================================================================

EOF
}

main "$@"

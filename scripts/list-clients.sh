#!/usr/bin/env bash
# List all 3X-UI clients with subscription URLs and inbound links.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/public-url.sh"
load_env_file "${PROJECT_DIR}/.env"

log() { printf '[list-clients] %s\n' "$*"; }

main() {
  local db sub_base web_path
  db="$(find_db_file 2>/dev/null || true)"
  [[ -n "${db}" && -f "${db}" ]] || {
    log "Database not found"
    exit 1
  }

  web_path="$(get_panel_web_path "${db}")"
  export PANEL_WEB_PATH="${web_path}"
  sub_base="$(build_sub_public_base)"

  log "Subscription base: ${sub_base}<subId>"
  log "Panel: $(build_panel_public_url)"
  echo ""

  if ! command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 required"
    exit 1
  fi

  sqlite3 -header -column "${db}" "
    SELECT
      c.email AS email,
      c.sub_id AS sub_id,
      c.uuid AS uuid,
      c.enable AS enable,
      c.limit_ip AS limit_ip,
      (SELECT GROUP_CONCAT(i.remark, ', ')
         FROM client_inbounds ci
         JOIN inbounds i ON i.id = ci.inbound_id AND i.enable = 1
         WHERE ci.client_id = c.id) AS inbounds
    FROM clients c
    WHERE c.sub_id IS NOT NULL AND c.sub_id != ''
    ORDER BY c.id;
  " 2>/dev/null || {
    log "No clients table or empty — legacy inbounds only"
    exit 0
  }

  echo ""
  log "Per-client subscription URLs (each device/profile needs its OWN subId):"
  sqlite3 "${db}" "
    SELECT email, sub_id FROM clients
    WHERE sub_id IS NOT NULL AND sub_id != '' AND enable = 1
    ORDER BY id;
  " 2>/dev/null | while IFS='|' read -r email sub_id; do
    [[ -n "${sub_id}" ]] || continue
    printf '  %-20s %s%s\n' "${email}" "${sub_base}" "${sub_id}"
  done

  echo ""
  log "On phone: delete old subscription → add URL above for that client → SS server → refresh"
}

main "$@"

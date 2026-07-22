#!/usr/bin/env bash
# Print correct panel and subscription URLs (respects webBasePath and PANEL_DOMAIN).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
source "${SCRIPT_DIR}/lib/db.sh"
source "${SCRIPT_DIR}/lib/public-url.sh"
load_env_file "${PROJECT_DIR}/.env"

log() { printf '[show-urls] %s\n' "$*"; }

main() {
  local db web_path panel_url sub_base
  db="$(find_db_file 2>/dev/null || true)"

  if [[ -n "${db}" && -f "${db}" ]]; then
    web_path="$(get_panel_web_path "${db}")"
    export PANEL_WEB_PATH="${web_path}"
    log "webBasePath (from DB): ${web_path}"
  else
    web_path="${PANEL_WEB_PATH:-/}"
    log "webBasePath: ${web_path} (default, DB not found)"
  fi

  panel_url="$(build_panel_public_url)"
  sub_base="$(build_sub_public_base)"

  cat <<EOF

Panel:        ${panel_url}
Subscription: ${sub_base}<subId>

Encrypted:    bash scripts/generate-crypto-subscription.sh
              → happ://crypt5/... for family (hides plain URL)

Notes:
  - 404 on https://${PANEL_DOMAIN:-<domain>}/ alone is normal if webBasePath is not "/"
  - Subscription path /sub/... is separate (Traefik → port ${SUB_PORT:-2096})
  - Reset panel to root path: sudo bash scripts/repair-panel.sh --reset-web-path
  - Phase 2 VLESS: sudo bash scripts/setup-vless-reality.sh

EOF
}

main "$@"

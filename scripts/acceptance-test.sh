#!/usr/bin/env bash
# End-to-end acceptance test for happroxy deployment (run on Ubuntu VM).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"
fi

SERVER_IP="${SERVER_IP:?Set SERVER_IP in .env}"
PANEL_PORT="${PANEL_PORT:-38471}"
SUB_PATH="${SUB_PATH:-/sub/family}"

log() { printf '[acceptance] %s\n' "$*"; }
die() { printf '[acceptance] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  log "=== happroxy acceptance test ==="

  bash "${SCRIPT_DIR}/healthcheck.sh"

  log "Checking subscription contains public IP or domain..."
  local sub_url="https://${PANEL_DOMAIN:-${SERVER_IP}}${SUB_PATH:-/sub/family}/"
  log "Manual step: open a client subscription URL in browser, e.g.:"
  log "  ${sub_url}<client_subId>"
  log "Verify response includes hy2://, ss://, or vmess:// with address ${PANEL_DOMAIN:-${SERVER_IP}}"

  log ""
  log "Happ client manual checks:"
  log "  1. Import subscription URL in Happ (+ → Subscription URL)"
  log "  2. Pull to refresh server list"
  log "  3. Connect via Shadowsocks (port ${SS_PORT:-8388}) first"
  log "  4. Then VMess (${VMESS_PORT:-16888}) or Hysteria2 (${HY2_PORT:-4443})"
  log "  5. After routing rules configured, refresh subscription and verify split-tunnel"

  log ""
  log "Backup/restore smoke test..."
  bash "${SCRIPT_DIR}/backup.sh"
  log "Acceptance script finished. Complete manual Happ tests on your devices."
}

main "$@"

#!/usr/bin/env bash
# End-to-end acceptance test for happroxy deployment (run on Ubuntu VM).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
fi

SERVER_IP="${SERVER_IP:?Set SERVER_IP in .env}"
PANEL_PORT="${PANEL_PORT:-38471}"
SUB_PATH="${SUB_PATH:-/sub/family}"

log() { printf '[acceptance] %s\n' "$*"; }
die() { printf '[acceptance] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  log "=== happroxy acceptance test ==="

  bash "${SCRIPT_DIR}/healthcheck.sh"

  log "Checking subscription contains public IP (requires at least one client)..."
  local sub_url="https://${SERVER_IP}:${PANEL_PORT}${SUB_PATH}/"
  log "Manual step: open a client subscription URL in browser, e.g.:"
  log "  ${sub_url}<client_subId>"
  log "Verify response includes hy2://, ss://, or vmess:// with address ${SERVER_IP}"

  log ""
  log "Happ client manual checks:"
  log "  1. Import subscription URL in Happ (+ → Subscription URL)"
  log "  2. Pull to refresh server list"
  log "  3. Connect via Hysteria2 (port ${HY2_PORT:-4443})"
  log "  4. If UDP blocked, switch to Shadowsocks (port ${SS_PORT:-8388})"
  log "  5. After routing rules configured, refresh subscription and verify split-tunnel"

  log ""
  log "Backup/restore smoke test..."
  bash "${SCRIPT_DIR}/backup.sh"
  log "Acceptance script finished. Complete manual Happ tests on your devices."
}

main "$@"

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
VLESS_PORT="${VLESS_PORT:-4433}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"
HY2_PORT="${HY2_PORT:-4443}"
SUB_PATH="${SUB_PATH:-/sub/family}"
ENABLE_LEGACY_INBOUNDS="${ENABLE_LEGACY_INBOUNDS:-true}"

log() { printf '[acceptance] %s\n' "$*"; }
die() { printf '[acceptance] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  log "=== happroxy acceptance test ==="

  bash "${SCRIPT_DIR}/healthcheck.sh"

  log "Checking subscription contains public IP or domain..."
  local sub_url="https://${PANEL_DOMAIN:-${SERVER_IP}}${SUB_PATH:-/sub/family}/"
  log "Manual step: open a client subscription URL in browser, e.g.:"
  log "  ${sub_url}<client_subId>"
  log "Verify response includes vless:// with address ${PANEL_DOMAIN:-${SERVER_IP}}"
  if [[ "${ENABLE_LEGACY_INBOUNDS}" == "true" ]]; then
    log "Legacy: may also include ss://, vmess://, hy2://"
  fi

  log ""
  log "Happ client manual checks:"
  log "  1. Import subscription URL in Happ (+ → Subscription URL)"
  log "  2. Pull to refresh server list"
  log "  3. Connect via VLESS Reality (port ${VLESS_PORT}) first"
  if [[ "${ENABLE_LEGACY_INBOUNDS}" == "true" ]]; then
    log "  4. Fallback: Shadowsocks (${SS_PORT}), VMess (${VMESS_PORT}), Hysteria2 (${HY2_PORT})"
    log "  5. After routing rules configured, refresh subscription and verify split-tunnel"
  else
    log "  4. After routing rules configured, refresh subscription and verify split-tunnel"
    log "  5. Encrypted sub: bash scripts/generate-crypto-subscription.sh"
  fi

  log ""
  log "Backup/restore smoke test..."
  bash "${SCRIPT_DIR}/backup.sh"
  log "Acceptance script finished. Complete manual Happ tests on your devices."
}

main "$@"

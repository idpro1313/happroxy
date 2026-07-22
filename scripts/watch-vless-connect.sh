#!/usr/bin/env bash
# Watch established TCP sessions on VLESS port while a client connects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[watch-vless] %s\n' "$*"; }

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env_file "${PROJECT_DIR}/.env"

VLESS_PORT="${VLESS_PORT:-4433}"
DURATION="${1:-120}"
USE_TCPDUMP="${USE_TCPDUMP:-false}"

log "Watching TCP :${VLESS_PORT} for ${DURATION}s"
log "Connect Happ → vless-reality now."
log "Press Ctrl+C to stop early."
echo ""

if [[ "${USE_TCPDUMP}" == "true" ]] && command -v tcpdump >/dev/null 2>&1; then
  log "Mode: tcpdump (first 20 packets)"
  timeout "${DURATION}" tcpdump -i any "port ${VLESS_PORT}" -n -c 20 2>/dev/null || true
  exit 0
fi

deadline=$((SECONDS + DURATION))
seen=0

while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  lines="$(ss -tn state established "( sport = :${VLESS_PORT} )" 2>/dev/null | tail -n +2 || true)"
  if [[ -n "${lines}" ]]; then
    if [[ "${seen}" -eq 0 ]]; then
      log "Connection detected:"
    fi
    seen=1
    printf '%s\n' "${lines}" | sed 's/^/[watch-vless]   /'
  fi
  sleep 1
done

if [[ "${seen}" -eq 0 ]]; then
  log "No established connections on :${VLESS_PORT} in ${DURATION}s."
  log "Likely causes: ISP blocks outbound :${VLESS_PORT}, or Happ never dials VLESS."
  log "Try: sudo bash scripts/migrate-vless-port.sh 8444"
  log "PC test: bash scripts/print-client-port-test.sh"
  exit 1
fi

log "Done — at least one connection was seen."

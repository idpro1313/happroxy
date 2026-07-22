#!/usr/bin/env bash
# Verify happroxy is visible to Traefik (network web + Docker labels).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
source "${SCRIPT_DIR}/lib/compose.sh"
load_env_file "${PROJECT_DIR}/.env"

log() { printf '[verify-traefik] %s\n' "$*"; }
warn() { printf '[verify-traefik] WARN: %s\n' "$*" >&2; }
fail() { printf '[verify-traefik] FAIL: %s\n' "$*" >&2; FAIL=1; }

FAIL=0

main() {
  log "PANEL_DOMAIN=${PANEL_DOMAIN:-<not set>}"
  [[ -n "${PANEL_DOMAIN:-}" ]] || fail "Set PANEL_DOMAIN in .env"

  if using_traefik_overlay "${PROJECT_DIR}"; then
    log "Compose: docker-compose.yml + docker-compose.traefik.yml"
  else
    fail "docker-compose.traefik.yml missing or PANEL_DOMAIN empty"
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx happroxy_3xui; then
    fail "Container happroxy_3xui is not running"
  else
    log "Container happroxy_3xui is running"
  fi

  if docker inspect happroxy_3xui --format '{{json .NetworkSettings.Networks}}' | grep -q '"web"'; then
    log "Network web: attached"
  else
    fail "Container NOT on network web — run: docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d"
  fi

  if docker inspect happroxy_3xui --format '{{index .Config.Labels "traefik.enable"}}' | grep -qx true; then
    log "Label traefik.enable=true"
  else
    fail "traefik.enable missing/false — recreate with traefik overlay"
  fi

  local rule
  rule="$(docker inspect happroxy_3xui --format '{{index .Config.Labels "traefik.http.routers.happroxy-panel.rule"}}' 2>/dev/null || true)"
  if [[ "${rule}" == *"${PANEL_DOMAIN}"* ]] || [[ "${rule}" == *"Host(\`${PANEL_DOMAIN}\`)"* ]]; then
    log "Router rule: ${rule}"
  elif [[ -n "${rule}" ]]; then
    warn "Router rule looks wrong: ${rule}"
    fail "Expected Host(\`${PANEL_DOMAIN}\`) — check .env and recreate container"
  else
    fail "No happroxy-panel Traefik labels on container"
  fi

  log ""
  log "In Traefik dashboard (HTTP → Routers) expect:"
  log "  happroxy-panel@docker  Host(\`${PANEL_DOMAIN}\`)"
  log "  happroxy-sub@docker    Host(\`${PANEL_DOMAIN}\`) && PathPrefix(\`/sub/\`)"
  log ""
  log "If missing, run:"
  log "  cd /opt/happroxy && docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d --force-recreate"

  [[ "${FAIL}" -eq 0 ]] && log "OK" || exit 1
}

main "$@"

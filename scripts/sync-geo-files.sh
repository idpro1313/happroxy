#!/usr/bin/env bash
# Download Loyalsoldier geoip.dat / geosite.dat for Happ routing (self-host via Traefik /geo/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/data-dir.sh"

GEO_DIR="${DATA_DIR}/geo"
MIN_GEOIP_BYTES=5000000
MIN_GEOSITE_BYTES=500000

log() { printf '[sync-geo] %s\n' "$*"; }
warn() { printf '[sync-geo] WARN: %s\n' "$*" >&2; }
die() { printf '[sync-geo] ERROR: %s\n' "$*" >&2; exit 1; }

GEOIP_MIRRORS=(
  "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
)

GEOSITE_MIRRORS=(
  "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
)

download_one() {
  local dest="$1"
  shift
  local url tmp size min_bytes="$1"
  shift
  tmp="${dest}.part"

  for url in "$@"; do
    log "Trying ${url}"
    if curl -fsSL --retry 3 --connect-timeout 30 --max-time 600 -o "${tmp}" "${url}"; then
      size="$(wc -c < "${tmp}" | tr -d ' ')"
      if [[ "${size}" -ge "${min_bytes}" ]]; then
        mv -f "${tmp}" "${dest}"
        log "OK $(basename "${dest}") (${size} bytes) from ${url}"
        return 0
      fi
      warn "File too small (${size} bytes): ${url}"
    else
      warn "Download failed: ${url}"
    fi
    rm -f "${tmp}"
  done
  return 1
}

print_urls() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  if [[ -n "${PANEL_DOMAIN:-}" && "${USE_HTTPS:-true}" != "false" ]]; then
    log ""
    log "Self-host URLs (add to .env and regenerate routing deeplink):"
    log "  GEOIP_URL=https://${PANEL_DOMAIN}/geo/geoip.dat"
    log "  GEOSITE_URL=https://${PANEL_DOMAIN}/geo/geosite.dat"
    log ""
    log "Then: docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d"
    log "      bash scripts/generate-routing-deeplink.sh"
  else
    warn "Set PANEL_DOMAIN + USE_HTTPS for self-host URLs in routing profile"
  fi
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl required"
  mkdir -p "${GEO_DIR}"

  download_one "${GEO_DIR}/geoip.dat" "${MIN_GEOIP_BYTES}" "${GEOIP_MIRRORS[@]}" \
    || die "geoip.dat download failed from all mirrors"
  download_one "${GEO_DIR}/geosite.dat" "${MIN_GEOSITE_BYTES}" "${GEOSITE_MIRRORS[@]}" \
    || die "geosite.dat download failed from all mirrors"

  print_urls
}

main "$@"

#!/usr/bin/env bash
# Copy Let's Encrypt certificates into happroxy cert dir for Hysteria2 / Trojan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[sync-le-certs] %s\n' "$*"; }
warn() { printf '[sync-le-certs] WARN: %s\n' "$*" >&2; }
die() { printf '[sync-le-certs] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/sync-le-certs.sh"
  fi
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  load_env_file "${PROJECT_DIR}/.env"

  local domain="${PANEL_DOMAIN:-}"
  [[ -n "${domain}" ]] || die "Set PANEL_DOMAIN in .env (e.g. vpn.example.com)"

  local le_dir="${LE_CERT_DIR:-/etc/letsencrypt/live/${domain}}"
  local src_full="${le_dir}/fullchain.pem"
  local src_key="${le_dir}/privkey.pem"

  [[ -f "${src_full}" && -f "${src_key}" ]] || die "Missing ${src_full} or ${src_key}. Run certbot or scripts/setup-https.sh first."

  mkdir -p "${DATA_CERT_DIR}"
  cp -a "${src_full}" "${DATA_CERT_DIR}/fullchain.pem"
  cp -a "${src_key}" "${DATA_CERT_DIR}/privkey.pem"
  cp -a "${src_full}" "${DATA_CERT_DIR}/selfsigned.crt"
  cp -a "${src_key}" "${DATA_CERT_DIR}/selfsigned.key"
  chmod 600 "${DATA_CERT_DIR}/privkey.pem" "${DATA_CERT_DIR}/selfsigned.key"

  log "Installed LE certs to ${DATA_CERT_DIR}/"
  log "  fullchain.pem / selfsigned.crt"
  log "  privkey.pem   / selfsigned.key"
  log ""
  log "In 3X-UI inbounds (HY2/Trojan) use:"
  log "  /root/cert/fullchain.pem  (or selfsigned.crt)"
  log "  /root/cert/privkey.pem    (or selfsigned.key)"
  log ""
  log "Restart Xray: docker restart happroxy_3xui"
}

main "$@"

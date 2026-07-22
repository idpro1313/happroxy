#!/usr/bin/env bash
# Export Let's Encrypt certs from Traefik acme.json into happroxy cert dir (HY2/Trojan).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[sync-traefik-certs] %s\n' "$*"; }
warn() { printf '[sync-traefik-certs] WARN: %s\n' "$*" >&2; }
die() { printf '[sync-traefik-certs] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Run as root: sudo bash scripts/sync-traefik-certs.sh"
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  load_env_file "${PROJECT_DIR}/.env"

  local domain="${PANEL_DOMAIN:-}"
  [[ -n "${domain}" ]] || die "Set PANEL_DOMAIN in .env"

  local acme="${TRAEFIK_ACME_FILE:-/opt/webserver/traefikdata/letsencrypt/acme.json}"
  [[ -f "${acme}" ]] || die "Traefik acme.json not found: ${acme}"

  if ! command -v docker >/dev/null 2>&1; then
    die "Docker required to run traefik-certs-dumper"
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  log "Dumping certs from ${acme} for domain ${domain}..."
  docker run --rm \
    -v "${acme}:/acme.json:ro" \
    -v "${tmp}:/output" \
    ldez/traefik-certs-dumper:v2.8.3 \
    dump --version v2 --source /acme.json --dest /output --domain "${domain}" >/dev/null

  local cert_dir="${tmp}/certs/${domain}"
  [[ -f "${cert_dir}/certificate.crt" && -f "${cert_dir}/privatekey.key" ]] \
    || die "Cert for ${domain} not found in acme.json yet. Open https://${domain}/ once Traefik issued LE."

  mkdir -p "${DATA_CERT_DIR}"
  cp -a "${cert_dir}/certificate.crt" "${DATA_CERT_DIR}/fullchain.pem"
  cp -a "${cert_dir}/privatekey.key" "${DATA_CERT_DIR}/privkey.pem"
  cp -a "${DATA_CERT_DIR}/fullchain.pem" "${DATA_CERT_DIR}/selfsigned.crt"
  cp -a "${DATA_CERT_DIR}/privkey.pem" "${DATA_CERT_DIR}/selfsigned.key"
  chmod 600 "${DATA_CERT_DIR}/privkey.pem" "${DATA_CERT_DIR}/selfsigned.key"

  log "Installed Traefik LE certs to ${DATA_CERT_DIR}/"
  log "Restart: docker restart happroxy_3xui"
}

main "$@"

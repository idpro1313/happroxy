#!/usr/bin/env bash
# Migrate happroxy to HTTPS via domain (Traefik on 443 + optional certbot for inbounds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[setup-https] %s\n' "$*"; }
warn() { printf '[setup-https] WARN: %s\n' "$*" >&2; }
die() { printf '[setup-https] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Run as root: sudo bash scripts/setup-https.sh"
}

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/setup-https.sh [options]

Options:
  --domain NAME     Public FQDN (default: vpn.idpro13.ru or PANEL_DOMAIN from .env)
  --email ADDR      Let's Encrypt contact email (required for certbot)
  --skip-certbot    Only update .env + panel DB; Traefik handles TLS for panel/sub
  --skip-traefik    Do not print/install Traefik dynamic config
  --traefik-dir DIR Copy config/traefik/happroxy.yml to DIR (Traefik file provider)

Example:
  sudo bash scripts/setup-https.sh --domain vpn.idpro13.ru --email admin@idpro13.ru
EOF
}

check_dns() {
  local domain="$1" expected_ip="$2"
  local resolved=""
  resolved="$(getent ahosts "${domain}" 2>/dev/null | awk '/STREAM/ {print $1; exit}' || true)"
  if [[ -z "${resolved}" ]]; then
    warn "DNS for ${domain} not resolved yet. Create A-record → ${expected_ip}"
    return 1
  fi
  if [[ "${resolved}" != "${expected_ip}" ]]; then
    warn "DNS ${domain} → ${resolved}, expected ${expected_ip}"
    return 1
  fi
  log "DNS OK: ${domain} → ${resolved}"
}

update_env_domain() {
  local env_file="${PROJECT_DIR}/.env"
  local domain="$1"
  [[ -f "${env_file}" ]] || die ".env not found — run install.sh first"

  set_kv() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${env_file}"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
    else
      echo "${key}=${val}" >> "${env_file}"
    fi
  }

  set_kv "PANEL_DOMAIN" "${domain}"
  set_kv "USE_HTTPS" "true"
  log "Updated .env: PANEL_DOMAIN=${domain}, USE_HTTPS=true"
}

render_traefik_config() {
  local domain="$1" panel_port="$2" sub_port="$3" upstream="$4" src dst
  src="${PROJECT_DIR}/config/traefik/happroxy.yml"
  dst="${PROJECT_DIR}/config/traefik/happroxy.generated.yml"
  [[ -f "${src}" ]] || die "Missing ${src}"

  sed -e "s/vpn\\.idpro13\\.ru/${domain}/g" \
      -e "s/172\\.17\\.0\\.1:38471/${upstream}:${panel_port}/g" \
      -e "s/172\\.17\\.0\\.1:2096/${upstream}:${sub_port}/g" \
      "${src}" > "${dst}"
  printf '%s' "${dst}"
}

run_certbot() {
  local domain="$1" email="$2" webroot="${CERTBOT_WEBROOT:-/var/www/certbot}"
  mkdir -p "${webroot}"

  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    log "Let's Encrypt cert already exists for ${domain}"
    return 0
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    log "Installing certbot..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
  fi

  log "Requesting certificate (webroot ${webroot})..."
  log "Ensure Traefik routes http://${domain}/.well-known/acme-challenge/ → ${webroot}"
  certbot certonly --webroot -w "${webroot}" \
    -d "${domain}" \
    --email "${email}" \
    --agree-tos --non-interactive --keep-until-expiring
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  local domain="" email="" skip_certbot=false skip_traefik=false traefik_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      --email) email="$2"; shift 2 ;;
      --skip-certbot) skip_certbot=true; shift ;;
      --skip-traefik) skip_traefik=true; shift ;;
      --traefik-dir) traefik_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  domain="${domain:-${PANEL_DOMAIN:-vpn.idpro13.ru}}"
  [[ -n "${SERVER_IP:-}" ]] || die "Set SERVER_IP in .env"

  log "Domain: ${domain}"
  log "Server IP: ${SERVER_IP}"
  check_dns "${domain}" "${SERVER_IP}" || warn "Continue after fixing DNS if HTTPS fails."

  update_env_domain "${domain}"

  local upstream="${TRAEFIK_UPSTREAM_HOST:-172.17.0.1}"
  local panel_port="${PANEL_PORT:-38471}"
  local sub_port="${SUB_PORT:-2096}"

  if [[ "${skip_traefik}" != "true" ]]; then
    local generated
    generated="$(render_traefik_config "${domain}" "${panel_port}" "${sub_port}" "${upstream}")"
    log "Generated Traefik config: ${generated}"
    log ""
    log "Add to Traefik file provider (adjust certResolver name if not 'letsencrypt'):"
    log "  ${generated}"
    if [[ -n "${traefik_dir}" ]]; then
      mkdir -p "${traefik_dir}"
      cp "${generated}" "${traefik_dir}/happroxy.yml"
      log "Copied to ${traefik_dir}/happroxy.yml — reload Traefik."
    else
      log "Or: sudo bash scripts/setup-https.sh --traefik-dir /path/to/traefik/dynamic"
    fi
    log ""
    log "If Traefik runs in Docker and 172.17.0.1 fails, set in .env:"
    log "  TRAEFIK_UPSTREAM_HOST=<host-gateway-IP>"
  fi

  if [[ "${skip_certbot}" != "true" ]]; then
    [[ -n "${email}" ]] || die "Provide --email for Let's Encrypt (inbounds HY2/Trojan)"
    run_certbot "${domain}" "${email}" || warn "certbot failed — panel/sub can still use Traefik LE"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      bash "${SCRIPT_DIR}/sync-le-certs.sh"
    fi
  fi

  log "Updating 3X-UI subscription settings (HTTPS subURI)..."
  bash "${SCRIPT_DIR}/repair-panel.sh"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/public-url.sh"
  load_env_file "${PROJECT_DIR}/.env"

  cat <<EOF

================================================================================
HTTPS setup complete (domain: ${domain})

Panel:        $(build_panel_public_url)
Subscription: $(build_sub_public_base)<subId>

Manual steps:
  1. Traefik: deploy dynamic config and reload (see above)
  2. DNS: A-record ${domain} → ${SERVER_IP}
  3. Панель → Подписка → URI обратного прокси = $(build_sub_public_base)
  4. Входящие → Стратегия адреса → пользовательский: ${domain}
  5. Happ: удалите старую подписку, добавьте новый HTTPS URL, обновите routing:
       bash scripts/generate-routing-deeplink.sh
  6. Cert renewal cron (inbounds):
       0 3 * * * root cd /opt/happroxy && certbot renew -q && bash scripts/sync-le-certs.sh && docker restart happroxy_3xui
================================================================================

EOF
}

main "$@"

#!/usr/bin/env bash
# Install and bootstrap happroxy (3X-UI) on Ubuntu 24.04.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/install.sh"
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

ensure_swap() {
  if swapon --show | grep -q .; then
    log "Swap already enabled."
    return
  fi

  log "Creating 2G swap file..."
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  cat >/etc/sysctl.d/99-happroxy-swappiness.conf <<'EOF'
vm.swappiness=10
EOF
  sysctl -p /etc/sysctl.d/99-happroxy-swappiness.conf >/dev/null
  log "Swap enabled (2G, swappiness=10)."
}

ensure_packages() {
  local missing=()
  for pkg in curl openssl ca-certificates; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done

  if ((${#missing[@]} > 0)); then
    log "Installing packages: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
  else
    log "Installing Docker..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin is required. Install docker-compose-v2."
  fi
}

generate_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

ensure_env() {
  local env_file="${PROJECT_DIR}/.env"
  local example_file="${PROJECT_DIR}/.env.example"
  local env_created=false

  if [[ ! -f "${env_file}" ]]; then
    log "Creating .env from .env.example..."
    cp "${example_file}" "${env_file}"
    env_created=true
  fi

  # Fix legacy unquoted values with spaces.
  if grep -q '^SUB_PROFILE_TITLE=Family VPN$' "${env_file}" 2>/dev/null; then
    sed -i 's/^SUB_PROFILE_TITLE=Family VPN/SUB_PROFILE_TITLE="Семейный VPN"/' "${env_file}"
  fi
  if grep -q '^SUB_PROFILE_TITLE="Family VPN"$' "${env_file}" 2>/dev/null; then
    sed -i 's/^SUB_PROFILE_TITLE="Family VPN"/SUB_PROFILE_TITLE="Семейный VPN"/' "${env_file}"
  fi

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/prompt.sh"
  load_env_file "${env_file}"

  local detected_ip
  detected_ip="$(detect_public_ip)"

  if [[ "${env_created}" == "true" ]] || [[ -z "${SERVER_IP:-}" ]]; then
    if happroxy_is_interactive; then
      prompt_install_env "${env_file}" "${SERVER_IP:-${detected_ip}}"
      load_env_file "${env_file}"
    elif [[ -z "${SERVER_IP:-}" && -n "${detected_ip}" ]]; then
      # shellcheck disable=SC1091
      set_env_kv "${env_file}" "SERVER_IP" "${detected_ip}"
      log "Detected public IP: ${detected_ip}"
      load_env_file "${env_file}"
    fi
  fi

  [[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP not set. Run install interactively or set SERVER_IP in .env"

  if ! grep -q '^XUI_ADMIN_PASSWORD=' "${env_file}"; then
    local admin_user admin_pass
    admin_user="admin_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    admin_pass="$(generate_password)"
    {
      echo ""
      echo "XUI_ADMIN_USER=${admin_user}"
      echo "XUI_ADMIN_PASSWORD=${admin_pass}"
    } >> "${env_file}"
    log "Generated admin credentials (save these — shown once):"
    log "  User: ${admin_user}"
    log "  Pass: ${admin_pass}"
  fi
}

ensure_dirs() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"

  log "Persistent data directory: ${DATA_DIR}"
  mkdir -p "${DATA_DB_DIR}" "${DATA_CERT_DIR}" "${DATA_BACKUP_DIR}"
  chmod 700 "${DATA_DIR}" "${DATA_DB_DIR}" "${DATA_CERT_DIR}"
  log "Created: ${DATA_DB_DIR}, ${DATA_CERT_DIR}, ${DATA_BACKUP_DIR}"
}

generate_self_signed_cert() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"

  local cert_dir="${DATA_CERT_DIR}"
  local key="${cert_dir}/selfsigned.key"
  local crt="${cert_dir}/selfsigned.crt"

  if [[ -f "${key}" && -f "${crt}" ]]; then
    log "Self-signed certificate already exists."
    return
  fi

  local ip="${SERVER_IP:-127.0.0.1}"
  local cn="${PANEL_DOMAIN:-${ip}}"
  local san="IP:${ip}"
  if [[ -n "${PANEL_DOMAIN:-}" ]]; then
    san="DNS:${PANEL_DOMAIN},IP:${ip}"
  fi

  log "Generating self-signed certificate for ${cn}..."
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${crt}" \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=${san}" 2>/dev/null
  chmod 600 "${key}"
  log "Certificate: ${crt}"
}

preflight_ports() {
  log "Running port pre-flight check..."
  bash "${SCRIPT_DIR}/configure-firewall.sh"
}

start_stack() {
  log "Starting 3X-UI container..."
  cd "${PROJECT_DIR}"
  docker compose pull
  docker compose up -d
  docker compose ps
}

print_next_steps() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/data-dir.sh"
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"
  cat <<EOF

================================================================================
happroxy / 3X-UI is running.

Data dir:   ${DATA_DIR}
  db/       panel database and settings
  cert/     TLS certificates for inbounds
  backups/  automatic backup archives

SERVER_IP:     ${SERVER_IP}
PANEL_DOMAIN:  ${PANEL_DOMAIN:-(not set — HTTP only on port ${PANEL_PORT})}

Panel (direct): http://${SERVER_IP}:${PANEL_PORT}/
Run: bash scripts/show-urls.sh  — actual URLs (HTTPS / webBasePath)

Default 3X-UI login on first start: admin / admin
Сразу смените пароль в Настройки панели → Учетная запись.

If install.sh generated XUI_ADMIN_* values, use those after first login change
or set a new password in the panel UI.

Next steps:
  1. Change admin password in panel
  2. Configure inbounds — README.md § «Настройка 3X-UI»
  3. bash scripts/show-urls.sh  — panel and subscription URLs
  4. Import subscription URL into Happ

Health:   bash scripts/healthcheck.sh
Backup:   bash scripts/backup.sh
Update:   bash scripts/update.sh
================================================================================

EOF
}

main() {
  local run_https=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive) export HAPPROXY_NON_INTERACTIVE=1; shift ;;
      -h|--help)
        echo "Usage: sudo bash scripts/install.sh [--non-interactive]"
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  require_root
  cd "${PROJECT_DIR}"

  chmod +x "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/lib/*.sh 2>/dev/null || true

  ensure_packages
  ensure_docker
  ensure_swap
  ensure_env

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"
  [[ -n "${PANEL_DOMAIN:-}" ]] && run_https=true

  ensure_dirs
  generate_self_signed_cert
  preflight_ports
  start_stack

  if [[ "${run_https}" == "true" ]]; then
    log "Configuring HTTPS (Traefik) for ${PANEL_DOMAIN}..."
    local https_args=(--domain "${PANEL_DOMAIN}" --docker-labels)
    [[ "${HAPPROXY_NON_INTERACTIVE:-0}" == "1" ]] && https_args+=(--non-interactive)
    bash "${SCRIPT_DIR}/setup-https.sh" "${https_args[@]}"
  fi

  print_next_steps
}

main "$@"

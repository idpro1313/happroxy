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

  if [[ ! -f "${env_file}" ]]; then
    log "Creating .env from .env.example..."
    cp "${example_file}" "${env_file}"
  fi

  # shellcheck disable=SC1091
  source "${env_file}"

  local detected_ip
  detected_ip="$(detect_public_ip)"

  if [[ -z "${SERVER_IP:-}" && -n "${detected_ip}" ]]; then
    sed -i "s/^SERVER_IP=.*/SERVER_IP=${detected_ip}/" "${env_file}"
    log "Detected public IP: ${detected_ip}"
  elif [[ -z "${SERVER_IP:-}" ]]; then
    die "Set SERVER_IP in .env manually."
  fi

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
  mkdir -p "${PROJECT_DIR}/db" "${PROJECT_DIR}/cert" "${PROJECT_DIR}/backups"
  chmod 700 "${PROJECT_DIR}/db" "${PROJECT_DIR}/cert"
}

generate_self_signed_cert() {
  local cert_dir="${PROJECT_DIR}/cert"
  local key="${cert_dir}/selfsigned.key"
  local crt="${cert_dir}/selfsigned.crt"

  if [[ -f "${key}" && -f "${crt}" ]]; then
    log "Self-signed certificate already exists."
    return
  fi

  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  local ip="${SERVER_IP:-127.0.0.1}"

  log "Generating self-signed certificate for IP ${ip}..."
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${key}" \
    -out "${crt}" \
    -subj "/CN=${ip}" \
    -addext "subjectAltName=IP:${ip}" 2>/dev/null
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
  source "${PROJECT_DIR}/.env"
  cat <<EOF

================================================================================
happroxy / 3X-UI is running.

Panel URL:  https://${SERVER_IP}:${PANEL_PORT}/
            (accept self-signed certificate warning in browser)

Default 3X-UI login on first start: admin / admin
Change credentials immediately in Panel Settings.

If install.sh generated XUI_ADMIN_* values, use those after first login change
or set a new password in the panel UI.

Next steps:
  1. Open the panel and change admin password
  2. Configure inbounds — see README.md section "Настройка 3X-UI"
  3. Set Subscription Listen IP to: ${SERVER_IP}
  4. Import subscription URL into Happ app

Health check:  bash scripts/healthcheck.sh
Backup:        bash scripts/backup.sh
Update:        bash scripts/update.sh
================================================================================

EOF
}

main() {
  require_root
  cd "${PROJECT_DIR}"

  chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true

  ensure_packages
  ensure_docker
  ensure_swap
  ensure_dirs
  ensure_env
  generate_self_signed_cert
  preflight_ports
  start_stack
  print_next_steps
}

main "$@"

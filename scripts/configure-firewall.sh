#!/usr/bin/env bash
# Pre-flight port conflict check and UFW rules for happroxy / 3X-UI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"
fi

PANEL_PORT="${PANEL_PORT:-38471}"
HY2_PORT="${HY2_PORT:-4443}"
SS_PORT="${SS_PORT:-8388}"
VMESS_PORT="${VMESS_PORT:-16888}"
TROJAN_PORT="${TROJAN_PORT:-8443}"
ENABLE_TROJAN="${ENABLE_TROJAN:-true}"

# Ports that must stay untouched on this VM (Traefik, Portainer, wg-dashboard).
RESERVED_PORTS=(80 443 8080 8000 9443 10086 17998)

log() { printf '[configure-firewall] %s\n' "$*"; }
die() { printf '[configure-firewall] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

port_in_use() {
  local port="$1"
  ss -tulpn 2>/dev/null | grep -qE "[:.]${port}\b"
}

check_port_free() {
  local port="$1"
  local label="$2"

  for reserved in "${RESERVED_PORTS[@]}"; do
    if [[ "${port}" -eq "${reserved}" ]]; then
      die "Port ${port} (${label}) is reserved for existing services on this VM."
    fi
  done

  if port_in_use "${port}"; then
    die "Port ${port} (${label}) is already in use. Change it in .env and retry."
  fi
}

check_hy2_port() {
  check_port_free "${HY2_PORT}" "Hysteria2"
}

install_packages() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "Installing ufw..."
    apt-get update -qq
    apt-get install -y -qq ufw
  fi
  if ! command -v ss >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq iproute2
  fi
}

configure_ufw() {
  log "Configuring UFW (existing rules are preserved)..."

  ufw --force enable >/dev/null 2>&1 || true

  ufw allow 22/tcp comment 'SSH' >/dev/null || ufw allow 22/tcp

  ufw allow "${PANEL_PORT}/tcp" comment '3X-UI panel' >/dev/null
  ufw allow "${HY2_PORT}/udp" comment 'Hysteria2 UDP' >/dev/null
  ufw allow "${HY2_PORT}/tcp" comment 'Hysteria2 TCP' >/dev/null
  ufw allow "${SS_PORT}/tcp" comment 'Shadowsocks' >/dev/null
  ufw allow "${VMESS_PORT}/tcp" comment 'VMess' >/dev/null

  if [[ "${ENABLE_TROJAN}" == "true" ]]; then
    ufw allow "${TROJAN_PORT}/tcp" comment 'Trojan' >/dev/null
  fi

  log "UFW status:"
  ufw status numbered || true
}

main() {
  require_root
  install_packages

  log "Checking ports..."
  check_port_free "${PANEL_PORT}" "3X-UI panel"
  check_hy2_port
  check_port_free "${SS_PORT}" "Shadowsocks"
  check_port_free "${VMESS_PORT}" "VMess"

  if [[ "${ENABLE_TROJAN}" == "true" ]]; then
    check_port_free "${TROJAN_PORT}" "Trojan"
  fi

  log "All required ports are free."
  configure_ufw
  log "Done."
}

main "$@"

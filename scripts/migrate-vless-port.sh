#!/usr/bin/env bash
# Move VLESS Reality to another TCP port (e.g. when ISP blocks 4433 from clients).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[migrate-vless-port] %s\n' "$*"; }
warn() { printf '[migrate-vless-port] WARN: %s\n' "$*" >&2; }
die() { printf '[migrate-vless-port] ERROR: %s\n' "$*" >&2; exit 1; }

DRY_RUN=false
NEW_PORT=""

usage() {
  cat <<EOF
Usage: sudo bash scripts/migrate-vless-port.sh [NEW_PORT] [--dry-run]

Move VLESS Reality inbound to another port and recreate the container.

Examples:
  sudo bash scripts/migrate-vless-port.sh 8444
  sudo bash scripts/migrate-vless-port.sh --dry-run 8444

Default NEW_PORT: 8444 (do not use 8443 — reserved for TROJAN_PORT in docker-compose).

After migration:
  1. bash scripts/watch-vless-connect.sh     (on server, while connecting from Happ)
  2. Refresh subscription in Happ
  3. bash scripts/print-client-port-test.sh    (run tests on Windows PC)
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash scripts/migrate-vless-port.sh [PORT]"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *)
        if [[ -z "${NEW_PORT}" ]]; then
          NEW_PORT="$1"
          shift
        else
          die "Unexpected argument: $1"
        fi
        ;;
    esac
  done
  NEW_PORT="${NEW_PORT:-8444}"
}

validate_port() {
  local port="$1"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/check-port.sh"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"

  local p
  for p in "${PANEL_PORT:-38471}" "${SUB_PORT:-2096}" "${HY2_PORT:-4443}" \
    "${SS_PORT:-8388}" "${VMESS_PORT:-16888}"; do
    if [[ "${port}" -eq "${p}" ]]; then
      die "Port ${port} conflicts with existing service port in .env (${p})"
    fi
  done

  if [[ "${port}" -eq "${TROJAN_PORT:-8443}" ]]; then
    die "Port ${port} equals TROJAN_PORT (${TROJAN_PORT:-8443}) in docker-compose — use e.g. 8444 or 2053"
  fi

  if [[ "${port}" -eq "${VLESS_PORT:-4433}" ]]; then
    die "VLESS is already on port ${port}"
  fi

  if ! haproxy_check_proxy_port "${port}" "VLESS Reality"; then
    exit 1
  fi
}

main() {
  parse_args "$@"
  require_root
  cd "${PROJECT_DIR}"

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/prompt.sh"

  local old_port="${VLESS_PORT:-4433}"
  validate_port "${NEW_PORT}"

  log "Plan: VLESS ${old_port}/tcp → ${NEW_PORT}/tcp"
  log "Domain: ${PANEL_DOMAIN:-${SERVER_IP:-?}}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run — no changes applied."
    log "Apply: sudo bash scripts/migrate-vless-port.sh ${NEW_PORT}"
    exit 0
  fi

  set_env_kv "${PROJECT_DIR}/.env" "VLESS_PORT" "${NEW_PORT}"
  log "Updated .env: VLESS_PORT=${NEW_PORT}"

  log "Reconfiguring inbound and container..."
  VLESS_PORT="${NEW_PORT}" bash "${SCRIPT_DIR}/setup-vless-reality.sh"

  log "Done. Old port ${old_port} may remain open in UFW (harmless)."
  log ""
  log "Next on server:  bash scripts/watch-vless-connect.sh"
  log "Next on PC:      see scripts/print-client-port-test.sh"
  log "Happ:            refresh subscription → connect vless-reality (:${NEW_PORT})"
}

main "$@"

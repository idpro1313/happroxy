#!/usr/bin/env bash
# Static validation of happroxy repo (no Docker required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ERR=0

log() { printf '[validate] %s\n' "$*"; }
fail() { printf '[validate] FAIL: %s\n' "$*" >&2; ERR=1; }

check_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    log "OK file: ${f#${PROJECT_DIR}/}"
  else
    fail "Missing file: ${f}"
  fi
}

check_executable() {
  local f="$1"
  if [[ -x "${f}" ]]; then
    log "OK executable: ${f#${PROJECT_DIR}/}"
  else
    fail "Not executable: ${f#${PROJECT_DIR}/} (run: chmod +x scripts/*.sh)"
  fi
}

check_json() {
  local f="$1"
  if python3 -m json.tool "${f}" >/dev/null 2>&1; then
    log "OK JSON: ${f#${PROJECT_DIR}/}"
  elif command -v jq >/dev/null 2>&1 && jq empty "${f}" >/dev/null 2>&1; then
    log "OK JSON: ${f#${PROJECT_DIR}/}"
  else
    fail "Invalid JSON: ${f}"
  fi
}

check_bash_syntax() {
  local f="$1"
  if bash -n "${f}" 2>/dev/null; then
    log "OK syntax: ${f#${PROJECT_DIR}/}"
  else
    fail "Bash syntax error: ${f}"
  fi
}

check_env_example() {
  local required=(DATA_DIR SERVER_IP PANEL_PORT HY2_PORT SS_PORT VMESS_PORT TROJAN_PORT)
  local key
  for key in "${required[@]}"; do
    if grep -q "^${key}=" "${PROJECT_DIR}/.env.example"; then
      log "OK .env.example has ${key}"
    else
      fail ".env.example missing ${key}"
    fi
  done
}

check_reserved_ports() {
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  load_env_file "${PROJECT_DIR}/.env.example"
  local reserved=(80 443 8080 8000 9443 10086 17998)
  local ports=("${PANEL_PORT:-38471}" "${HY2_PORT:-4443}" "${SS_PORT:-8388}" "${VMESS_PORT:-16888}" "${TROJAN_PORT:-8443}")
  local p r
  for p in "${ports[@]}"; do
    for r in "${reserved[@]}"; do
      if [[ "${p}" -eq "${r}" ]]; then
        fail "Port ${p} conflicts with reserved VM port ${r}"
      fi
    done
  done
  log "OK no reserved port conflicts in .env.example defaults"
}

main() {
  log "Validating happroxy repository..."

  check_file "${PROJECT_DIR}/docker-compose.yml"
  check_file "${PROJECT_DIR}/.env.example"
  check_file "${PROJECT_DIR}/.gitignore"
  check_file "${PROJECT_DIR}/README.md"
  check_file "${PROJECT_DIR}/config/happ-routing.json"
  check_file "${PROJECT_DIR}/scripts/lib/load-env.sh"
  check_bash_syntax "${PROJECT_DIR}/scripts/lib/load-env.sh"
  check_file "${PROJECT_DIR}/scripts/lib/data-dir.sh"
  check_bash_syntax "${PROJECT_DIR}/scripts/lib/data-dir.sh"

  for s in install configure-firewall backup update healthcheck acceptance-test generate-routing-deeplink validate repair-panel; do
    check_file "${PROJECT_DIR}/scripts/${s}.sh"
    check_bash_syntax "${PROJECT_DIR}/scripts/${s}.sh"
  done

  check_json "${PROJECT_DIR}/config/happ-routing.json"
  check_env_example
  check_reserved_ports

  if command -v docker >/dev/null 2>&1; then
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" config 2>/dev/null | grep -q '/opt/happdata'; then
      log "OK docker compose uses external DATA_DIR volume"
    else
      fail "docker compose does not mount /opt/happdata"
    fi
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
      log "OK docker compose config"
    else
      fail "docker compose config failed"
    fi
  else
    log "SKIP docker compose config (docker not installed)"
  fi

  if [[ "${ERR}" -eq 0 ]]; then
    log "All static checks passed."
    exit 0
  fi
  exit 1
}

main "$@"

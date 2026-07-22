#!/usr/bin/env bash
# Fix VLESS for Happ: sync DB, optional port migration, diagnose, client test hints.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[fix-vless] %s\n' "$*"; }
die() { printf '[fix-vless] ERROR: %s\n' "$*" >&2; exit 1; }

MIGRATE_PORT=""
DRY_RUN=false
SKIP_DIAGNOSE=false

usage() {
  cat <<EOF
Usage: sudo bash scripts/fix-vless-client.sh [options]

When Happ shows VLESS connected but no traffic (or only .ru sites work):

  sudo bash scripts/fix-vless-client.sh --migrate-port 8444

Options:
  --migrate-port [PORT]   Move VLESS to PORT (default 8444) — use if PC cannot reach current VLESS port
  --dry-run               Show migration plan only
  --skip-diagnose         Skip diagnose-client.sh at the end

Workflow:
  1. This script (server)
  2. bash scripts/watch-vless-connect.sh          — in another SSH session
  3. scripts/out/client-port-test.ps1 on Windows  — bash scripts/print-client-port-test.sh
  4. Refresh subscription in Happ → vless-reality
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --migrate-port)
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
          MIGRATE_PORT="$2"
          shift 2
        else
          MIGRATE_PORT="8444"
          shift
        fi
        ;;
      --dry-run) DRY_RUN=true; shift ;;
      --skip-diagnose) SKIP_DIAGNOSE=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

require_root_if_migrate() {
  if [[ -n "${MIGRATE_PORT}" || "${DRY_RUN}" == "true" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Port migration requires root: sudo bash scripts/fix-vless-client.sh --migrate-port"
  fi
}

sync_db() {
  local db
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/db.sh"
  db="$(find_db_file 2>/dev/null || true)"
  if [[ -z "${db}" || ! -f "${db}" ]]; then
    warn "Database not found — skip JSON sync"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 required"
  fi
  log "Syncing client JSON (tgId, VLESS UUIDs)..."
  python3 "${SCRIPT_DIR}/lib/fix-client-json.py" "${db}" | sed 's/^/[fix-vless] /'
}

main() {
  parse_args "$@"
  require_root_if_migrate
  cd "${PROJECT_DIR}"

  sync_db

  if [[ -n "${MIGRATE_PORT}" ]]; then
    log "Migrating VLESS to port ${MIGRATE_PORT}..."
    local migrate_args=("${MIGRATE_PORT}")
    [[ "${DRY_RUN}" == "true" ]] && migrate_args=(--dry-run "${MIGRATE_PORT}")
    bash "${SCRIPT_DIR}/migrate-vless-port.sh" "${migrate_args[@]}"
  elif [[ "${DRY_RUN}" == "true" ]]; then
    bash "${SCRIPT_DIR}/migrate-vless-port.sh" --dry-run 8444
  else
    if docker ps --format '{{.Names}}' | grep -q happroxy_3xui; then
      log "Restarting container..."
      docker restart happroxy_3xui >/dev/null
      sleep 3
    fi
  fi

  if [[ "${SKIP_DIAGNOSE}" != "true" && "${DRY_RUN}" != "true" ]]; then
    log ""
    bash "${SCRIPT_DIR}/diagnose-client.sh" || true
  fi

  if [[ "${DRY_RUN}" != "true" ]]; then
    log ""
    bash "${SCRIPT_DIR}/print-client-port-test.sh"
    cat <<EOF

=== Next steps ===

Server (second SSH window):
  bash scripts/watch-vless-connect.sh

Windows PC:
  Copy scripts/out/client-port-test.ps1 and run in PowerShell

Happ:
  Refresh subscription → connect vless-reality
  If foreign sites still fail: use ss-fallback until VLESS port test passes

EOF
  fi
}

warn() { printf '[fix-vless] WARN: %s\n' "$*" >&2; }

main "$@"

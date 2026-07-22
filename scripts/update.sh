#!/usr/bin/env bash
# Pull latest 3X-UI image and restart the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[update] %s\n' "$*"; }
die() { printf '[update] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  cd "${PROJECT_DIR}"

  if [[ ! -f docker-compose.yml ]]; then
    die "docker-compose.yml not found in ${PROJECT_DIR}"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is not installed."
  fi

  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/compose.sh"
  load_env_file "${PROJECT_DIR}/.env"

  log "Creating pre-update backup..."
  bash "${SCRIPT_DIR}/backup.sh"

  log "Pulling latest image..."
  compose_pull "${PROJECT_DIR}"

  log "Recreating container..."
  compose_up "${PROJECT_DIR}"

  log "Waiting for panel to start..."
  sleep 5

  bash "${SCRIPT_DIR}/healthcheck.sh"
  log "Update complete."
}

main "$@"

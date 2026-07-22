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

  log "Creating pre-update backup..."
  bash "${SCRIPT_DIR}/backup.sh"

  log "Pulling latest image..."
  docker compose pull

  log "Recreating container..."
  docker compose up -d

  log "Waiting for panel to start..."
  sleep 5

  bash "${SCRIPT_DIR}/healthcheck.sh"
  log "Update complete."
}

main "$@"

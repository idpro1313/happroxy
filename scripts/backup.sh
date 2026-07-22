#!/usr/bin/env bash
# Backup 3X-UI database and certificates from DATA_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/data-dir.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="${DATA_BACKUP_DIR}/happroxy_${TIMESTAMP}.tar.gz"
RETAIN_DAYS="${RETAIN_DAYS:-14}"

log() { printf '[backup] %s\n' "$*"; }
die() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  mkdir -p "${DATA_BACKUP_DIR}"

  if [[ ! -d "${DATA_DB_DIR}" ]]; then
    die "Database directory not found: ${DATA_DB_DIR}. Has 3X-UI been started?"
  fi

  log "Creating backup: ${ARCHIVE}"
  if [[ -f "${PROJECT_DIR}/.env" ]]; then
    tar -czf "${ARCHIVE}" \
      -C "${DATA_DIR}" db cert \
      -C "${PROJECT_DIR}" .env
  else
    tar -czf "${ARCHIVE}" -C "${DATA_DIR}" db cert
  fi

  log "Backup size: $(du -h "${ARCHIVE}" | cut -f1)"

  find "${DATA_BACKUP_DIR}" -name 'happroxy_*.tar.gz' -mtime +"${RETAIN_DAYS}" -delete 2>/dev/null || true
  log "Removed backups older than ${RETAIN_DAYS} days."

  log "Done. Restore with:"
  log "  sudo mkdir -p ${DATA_DIR}"
  log "  sudo tar -xzf ${ARCHIVE} -C ${DATA_DIR}"
  log "  cd ${PROJECT_DIR} && docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d"
}

main "$@"

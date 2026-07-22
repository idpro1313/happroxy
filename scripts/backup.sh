#!/usr/bin/env bash
# Backup 3X-UI database and certificates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="${BACKUP_DIR}/happroxy_${TIMESTAMP}.tar.gz"
RETAIN_DAYS="${RETAIN_DAYS:-14}"

log() { printf '[backup] %s\n' "$*"; }
die() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  mkdir -p "${BACKUP_DIR}"

  if [[ ! -d "${PROJECT_DIR}/db" ]]; then
    die "db/ directory not found. Has 3X-UI been started?"
  fi

  log "Creating backup: ${ARCHIVE}"
  tar -czf "${ARCHIVE}" \
    -C "${PROJECT_DIR}" \
    db cert .env 2>/dev/null \
    || tar -czf "${ARCHIVE}" -C "${PROJECT_DIR}" db cert

  log "Backup size: $(du -h "${ARCHIVE}" | cut -f1)"

  if [[ -d "${BACKUP_DIR}" ]]; then
    find "${BACKUP_DIR}" -name 'happroxy_*.tar.gz' -mtime +"${RETAIN_DAYS}" -delete 2>/dev/null || true
    log "Removed backups older than ${RETAIN_DAYS} days."
  fi

  log "Done. Restore with:"
  log "  tar -xzf ${ARCHIVE} -C ${PROJECT_DIR}"
  log "  docker compose -f ${PROJECT_DIR}/docker-compose.yml up -d"
}

main "$@"

#!/usr/bin/env bash
# Resolve persistent data paths (independent of container lifecycle).
set -euo pipefail

_happroxy_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_happroxy_project_dir="$(cd "${_happroxy_lib_dir}/../.." && pwd)"

if [[ -f "${_happroxy_project_dir}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${_happroxy_project_dir}/.env"
fi

DATA_DIR="${DATA_DIR:-/opt/happdata}"
DATA_DB_DIR="${DATA_DIR}/db"
DATA_CERT_DIR="${DATA_DIR}/cert"
DATA_BACKUP_DIR="${DATA_DIR}/backups"

export DATA_DIR DATA_DB_DIR DATA_CERT_DIR DATA_BACKUP_DIR

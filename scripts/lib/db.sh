#!/usr/bin/env bash
# Shared helpers for reading 3X-UI SQLite database on the host.
set -euo pipefail

_happroxy_db_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_happroxy_db_lib_dir}/data-dir.sh"

find_db_file() {
  local candidates=(
    "${DATA_DB_DIR}/x-ui.db"
    "${DATA_DB_DIR}/3x-ui.db"
    "${DATA_DB_DIR}/db.sqlite"
  )
  local f found
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      printf '%s' "${f}"
      return 0
    fi
  done
  found="$(find "${DATA_DB_DIR}" -maxdepth 1 -type f -name '*.db' 2>/dev/null | head -n1 || true)"
  if [[ -n "${found}" ]]; then
    printf '%s' "${found}"
    return 0
  fi
  return 1
}

get_setting_value() {
  local db="$1" key="$2"
  sqlite3 "${db}" "SELECT value FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null || true
}

get_panel_web_path() {
  local db="$1"
  local path
  path="$(get_setting_value "${db}" "webBasePath")"
  if [[ -z "${path}" || "${path}" == "/" ]]; then
    printf '/'
    return
  fi
  [[ "${path}" == /* ]] || path="/${path}"
  [[ "${path}" == */ ]] || path="${path}/"
  printf '%s' "${path}"
}

get_first_sub_id() {
  local db="$1"
  python3 - "${db}" <<'PY'
import json
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)
try:
    for (settings,) in conn.execute("SELECT settings FROM inbounds WHERE enable=1"):
        try:
            data = json.loads(settings or "{}")
        except json.JSONDecodeError:
            continue
        for client in data.get("clients") or []:
            if not client.get("enable", True):
                continue
            sub_id = client.get("subId") or client.get("id")
            if sub_id:
                print(sub_id)
                raise SystemExit(0)
except sqlite3.Error:
    pass
raise SystemExit(1)
PY
}

decode_subscription_body() {
  python3 - <<'PY'
import base64
import sys

raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)

# Plain text subscription (one link per line)
if "://" in raw.splitlines()[0]:
    print(raw)
    raise SystemExit(0)

# Base64 (standard or url-safe, with or without padding)
for decoder in (base64.b64decode, base64.urlsafe_b64decode):
    for src in (raw, raw + "=" * (-len(raw) % 4)):
        try:
            print(decoder(src).decode("utf-8", errors="replace"))
            raise SystemExit(0)
        except Exception:
            pass

print(raw)
PY
}

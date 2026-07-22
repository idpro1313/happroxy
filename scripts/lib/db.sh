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

# Fetch subscription body; prints body to stdout, returns 0 on success.
# Sets SUB_FETCH_URL and SUB_FETCH_CODE (exported) for diagnostics.
fetch_subscription_raw() {
  local sub_id="$1"
  local db="${2:-}"
  local sub_path sub_paths=() url code body_file="/tmp/happroxy_sub.txt"
  local -a urls=()

  sub_path="${SUB_PATH:-/sub/family}"
  if [[ -n "${db}" && -f "${db}" ]]; then
    local db_path db_enable
    db_path="$(get_setting_value "${db}" "subPath")"
    [[ -n "${db_path}" ]] && sub_path="${db_path}"
    db_enable="$(get_setting_value "${db}" "subEnable")"
    if [[ "${db_enable}" == "false" ]]; then
      SUB_FETCH_CODE="disabled"
      SUB_FETCH_URL="subEnable=false in panel DB"
      return 1
    fi
  fi

  normalize_sub_path_var() {
    local p="$1"
    [[ "${p}" == /* ]] || p="/${p}"
    [[ "${p}" == */ ]] || p="${p}/"
    printf '%s' "${p}"
  }

  sub_paths=(
    "$(normalize_sub_path_var "${sub_path}")"
    "/sub/"
  )

  # shellcheck disable=SC1091
  source "${_happroxy_db_lib_dir}/public-url.sh" 2>/dev/null || true
  if [[ -n "${PANEL_DOMAIN:-}" ]] && declare -F build_sub_public_base >/dev/null 2>&1; then
      local pub_base
      pub_base="$(build_sub_public_base)"
      urls+=("${pub_base}${sub_id}")
  fi

  local p
  for p in "${sub_paths[@]}"; do
    urls+=("http://127.0.0.1:${SUB_PORT:-2096}${p}${sub_id}")
    urls+=("http://127.0.0.1:${PANEL_PORT:-38471}${p}${sub_id}")
    if [[ -n "${SERVER_IP:-}" ]]; then
      urls+=("http://${SERVER_IP}:${SUB_PORT:-2096}${p}${sub_id}")
    fi
  done

  for url in "${urls[@]}"; do
    [[ -n "${url}" ]] || continue
    if [[ "${url}" == https://* ]]; then
      code="$(curl -fsSk -o "${body_file}" -w '%{http_code}' --max-time 15 "${url}" 2>/dev/null || echo "000")"
    else
      code="$(curl -fsS -o "${body_file}" -w '%{http_code}' --max-time 15 "${url}" 2>/dev/null || echo "000")"
    fi
    SUB_FETCH_URL="${url}"
    SUB_FETCH_CODE="${code}"
    if [[ "${code}" == "200" && -s "${body_file}" ]]; then
      if grep -q '://' "${body_file}" 2>/dev/null; then
        cat "${body_file}"
        return 0
      fi
      # Accept base64 subscription without plain :// on first line
      if [[ "$(wc -c < "${body_file}")" -gt 20 ]]; then
        cat "${body_file}"
        return 0
      fi
    fi
  done

  SUB_FETCH_CODE="${SUB_FETCH_CODE:-000}"
  return 1
}

decode_subscription_file() {
  local file="$1"
  [[ -s "${file}" ]] || return 1
  decode_subscription_body < "${file}"
}

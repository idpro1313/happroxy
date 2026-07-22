#!/usr/bin/env bash
# Safe .env loader — handles unquoted values with spaces (no `source`).

load_env_file() {
  local file="${1:-}"
  [[ -n "${file}" && -f "${file}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Strip Windows CR if present
    line="${line//$'\r'/}"

    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      value="${value//$'\r'/}"

      if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      # Avoid export failures on odd values; assign then export
      if ! printf -v "${key}" '%s' "${value}" 2>/dev/null; then
        printf '[load-env] WARN: skip invalid key %s\n' "${key}" >&2
        continue
      fi
      export "${key}"
    fi
  done < "${file}"
}

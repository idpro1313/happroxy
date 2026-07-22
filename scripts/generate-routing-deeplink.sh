#!/usr/bin/env bash
# Encode config/happ-routing.json to Happ routing deeplink.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUTING_FILE="${PROJECT_DIR}/config/happ-routing.json"

if [[ ! -f "${ROUTING_FILE}" ]]; then
  echo "Missing ${ROUTING_FILE}" >&2
  exit 1
fi

compact_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))' < "${ROUTING_FILE}"
  elif command -v jq >/dev/null 2>&1; then
    jq -c . "${ROUTING_FILE}"
  else
    tr -d '\n' < "${ROUTING_FILE}" | sed 's/  *//g'
  fi
}

JSON_COMPACT="$(compact_json)"
B64="$(printf '%s' "${JSON_COMPACT}" | base64 -w 0 2>/dev/null || printf '%s' "${JSON_COMPACT}" | base64)"

echo "Вставьте в 3X-UI → Настройки панели → Подписка → Правила маршрутизации:"
echo ""
echo "happ://routing/add/${B64}"
echo ""
echo "Имя профиля (Name) в JSON должно совпадать с «Заголовок подписки»."

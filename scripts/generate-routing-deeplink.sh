#!/usr/bin/env bash
# Encode config/happ-routing.json to Happ routing deeplink (injects SERVER_IP as direct).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUTING_FILE="${PROJECT_DIR}/config/happ-routing.json"

if [[ ! -f "${ROUTING_FILE}" ]]; then
  echo "Missing ${ROUTING_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env_file "${PROJECT_DIR}/.env"

SERVER_IP="${SERVER_IP:-}"
if [[ -z "${SERVER_IP}" ]]; then
  echo "WARN: SERVER_IP not set in .env — add server IP to DirectIp manually" >&2
fi

build_json() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 required to inject SERVER_IP into routing JSON" >&2
    exit 1
  fi

  python3 - "${ROUTING_FILE}" "${SERVER_IP}" <<'PY'
import json
import sys

path, server_ip = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

direct = data.setdefault("DirectIp", [])
for entry in ("geoip:private", "geoip:ru"):
    if entry not in direct:
        direct.append(entry)

if server_ip:
    cidr = server_ip if "/" in server_ip else f"{server_ip}/32"
    if cidr not in direct and server_ip not in direct:
        direct.append(cidr)

print(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
PY
}

JSON_COMPACT="$(build_json)"
B64="$(printf '%s' "${JSON_COMPACT}" | base64 -w 0 2>/dev/null || printf '%s' "${JSON_COMPACT}" | base64)"

echo "Вставьте в 3X-UI → Настройки панели → Подписка → Правила маршрутизации:"
echo ""
echo "happ://routing/add/${B64}"
echo ""
echo "Имя профиля (Name) в JSON должно совпадать с «Заголовок подписки»."
if [[ -n "${SERVER_IP}" ]]; then
  echo "DirectIp включает IP сервера ${SERVER_IP}/32 — панель доступна при включённом Happ."
fi

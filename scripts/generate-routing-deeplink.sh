#!/usr/bin/env bash
# Encode config/happ-routing.json to Happ routing deeplink (Happ official schema).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUTING_FILE="${PROJECT_DIR}/config/happ-routing.json"

PRINT_JSON=false
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: bash scripts/generate-routing-deeplink.sh [--print-json] [--validate]

Generates happ://routing/add/{base64} for Happ «Правила маршрутизации».

  --print-json   Print JSON only (debug)
  --validate     Validate template, exit 1 on errors

Name in JSON must match «Заголовок подписки» in 3X-UI (SUB_PROFILE_TITLE).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-json) PRINT_JSON=true; shift ;;
    --validate) VALIDATE_ONLY=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -f "${ROUTING_FILE}" ]]; then
  echo "Missing ${ROUTING_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env_file "${PROJECT_DIR}/.env"

SERVER_IP="${SERVER_IP:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
SUB_TITLE="${SUB_PROFILE_TITLE:-Семейный VPN}"
GEO_USE_BUILTIN="${GEO_USE_BUILTIN:-false}"
GEOIP_URL="${GEOIP_URL:-}"
GEOSITE_URL="${GEOSITE_URL:-}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/data-dir.sh"

if [[ "${GEO_USE_BUILTIN}" != "true" && -z "${GEOIP_URL}" && -z "${GEOSITE_URL}" \
    && -n "${PANEL_DOMAIN}" && -f "${DATA_DIR}/geo/geoip.dat" && -f "${DATA_DIR}/geo/geosite.dat" ]]; then
  GEOIP_URL="https://${PANEL_DOMAIN}/geo/geoip.dat"
  GEOSITE_URL="https://${PANEL_DOMAIN}/geo/geosite.dat"
fi

PY_GEO=()
if [[ "${GEO_USE_BUILTIN}" == "true" ]]; then
  PY_GEO+=(--geo-builtin)
else
  [[ -n "${GEOIP_URL}" ]] && PY_GEO+=(--geoip-url "${GEOIP_URL}")
  [[ -n "${GEOSITE_URL}" ]] && PY_GEO+=(--geosite-url "${GEOSITE_URL}")
fi

if [[ -z "${SERVER_IP}" && -z "${PANEL_DOMAIN}" ]]; then
  echo "WARN: SERVER_IP / PANEL_DOMAIN not set in .env" >&2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required" >&2
  exit 1
fi

PY_COMMON=(--profile-name "${SUB_TITLE}" "${PY_GEO[@]}")

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  if python3 "${SCRIPT_DIR}/lib/happ-routing.py" "${ROUTING_FILE}" "${SERVER_IP}" "${PANEL_DOMAIN}" \
      "${PY_COMMON[@]}" --validate-only; then
    echo "OK: happ-routing.json matches Happ schema (Name=${SUB_TITLE})"
    exit 0
  fi
  exit 1
fi

if ! python3 "${SCRIPT_DIR}/lib/happ-routing.py" "${ROUTING_FILE}" "${SERVER_IP}" "${PANEL_DOMAIN}" \
    "${PY_COMMON[@]}" --validate-only >/dev/null 2>&1; then
  echo "Routing profile validation failed:" >&2
  python3 "${SCRIPT_DIR}/lib/happ-routing.py" "${ROUTING_FILE}" "${SERVER_IP}" "${PANEL_DOMAIN}" \
    "${PY_COMMON[@]}" --validate-only >&2 || true
  exit 1
fi

JSON_COMPACT="$(python3 "${SCRIPT_DIR}/lib/happ-routing.py" "${ROUTING_FILE}" "${SERVER_IP}" "${PANEL_DOMAIN}" \
  "${PY_COMMON[@]}" --json-only)"
B64="$(python3 "${SCRIPT_DIR}/lib/happ-routing.py" "${ROUTING_FILE}" "${SERVER_IP}" "${PANEL_DOMAIN}" \
  "${PY_COMMON[@]}" --b64-only)"

if [[ "${PRINT_JSON}" == "true" ]]; then
  python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2, ensure_ascii=False))" "${JSON_COMPACT}"
  exit 0
fi

cat <<EOF
Вставьте в Happ → Подписка «${SUB_TITLE}» → Правила маршрутизации:

happ://routing/add/${B64}

Или откройте ссылку на телефоне с установленным Happ.

Важно:
  • Name в JSON = «${SUB_TITLE}» (= Заголовок подписки в 3X-UI)
  • После добавления — переподключите VPN (reconnect)
  • При первом импорте Happ скачает geoip.dat / geosite.dat (до ~3 мин)
  • Если geo не качается — sync-geo-files.sh + self-host, или GEO_USE_BUILTIN=true в .env
EOF

if [[ "${GEO_USE_BUILTIN}" == "true" ]]; then
  echo "  • Geo: встроенные файлы Happ (без загрузки)"
elif [[ -n "${GEOIP_URL}" ]]; then
  echo "  • Geoipurl: ${GEOIP_URL}"
fi
if [[ -n "${GEOSITE_URL}" ]]; then
  echo "  • Geositeurl: ${GEOSITE_URL}"
fi

if [[ -n "${SERVER_IP}" ]]; then
  echo "  • DirectIp: ${SERVER_IP}/32 (панель/сервер мимо туннеля)"
fi
if [[ -n "${PANEL_DOMAIN}" ]]; then
  echo "  • DirectSites: ${PANEL_DOMAIN}"
fi

echo ""
echo "Проверка JSON: bash scripts/generate-routing-deeplink.sh --print-json"

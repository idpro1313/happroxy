#!/usr/bin/env bash
# Generate Happ encrypted subscription link (happ://crypt5/...) from plain HTTPS URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CRYPTO_API="${HAPP_CRYPTO_API:-https://crypto.happ.su/api-v2.php}"

log() { printf '[crypto-sub] %s\n' "$*"; }
die() { printf '[crypto-sub] ERROR: %s\n' "$*" >&2; exit 1; }

build_plain_sub_url() {
  local db sub_id sub_base url
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/load-env.sh"
  source "${SCRIPT_DIR}/lib/db.sh"
  source "${SCRIPT_DIR}/lib/public-url.sh"
  load_env_file "${PROJECT_DIR}/.env"

  db="$(find_db_file 2>/dev/null || true)"
  sub_id=""
  if [[ -n "${db}" && -f "${db}" ]]; then
    sub_id="$(get_first_sub_id "${db}" 2>/dev/null || true)"
  fi
  [[ -n "${sub_id}" ]] || die "No client subId in database — add a client in 3X-UI panel first"

  sub_base="$(build_sub_public_base)"
  url="${sub_base}${sub_id}"
  printf '%s' "${url}"
}

append_provider_id() {
  local url="$1" provider_id="$2"
  [[ -n "${provider_id}" ]] || { printf '%s' "${url}"; return; }
  if [[ "${url}" == *'?'* ]]; then
    printf '%s&providerid=%s' "${url}" "${provider_id}"
  else
    printf '%s?providerid=%s' "${url}" "${provider_id}"
  fi
}

fetch_crypto_link() {
  local plain_url="$1"
  local payload response crypto

  if ! command -v curl >/dev/null 2>&1; then
    die "curl is required"
  fi

  payload="$(python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1]}))' "${plain_url}")"
  response="$(curl -fsS --max-time 30 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${CRYPTO_API}" 2>/dev/null || true)"

  [[ -n "${response}" ]] || die "Empty response from ${CRYPTO_API}"

  if [[ "${response}" == happ://crypt* ]]; then
    printf '%s' "${response}"
    return 0
  fi

  crypto="$(python3 - <<'PY' "${response}"
import json
import sys

raw = sys.argv[1].strip()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(raw)
    raise SystemExit(0)

for key in ("url", "link", "crypto", "encrypted", "result", "data"):
    val = data.get(key)
    if isinstance(val, str) and val.startswith("happ://crypt"):
        print(val)
        raise SystemExit(0)

if isinstance(data.get("data"), dict):
    for key in ("url", "link"):
        val = data["data"].get(key)
        if isinstance(val, str) and val.startswith("happ://crypt"):
            print(val)
            raise SystemExit(0)

print(raw)
PY
)"

  [[ "${crypto}" == happ://crypt* ]] || die "Unexpected API response (expected happ://crypt...): ${response}"
  printf '%s' "${crypto}"
}

main() {
  local plain_url="" provider_id="" show_plain=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plain) show_plain=true; shift ;;
      --url)
        plain_url="${2:-}"
        shift 2
        ;;
      --provider-id)
        provider_id="${2:-}"
        shift 2
        ;;
      -h|--help)
        cat <<EOF
Usage: bash scripts/generate-crypto-subscription.sh [OPTIONS]

Generate Happ encrypted subscription (happ://crypt5/...) via official API.

Options:
  --plain           Also print the plain HTTPS subscription URL (admin only)
  --url URL         Encrypt this URL instead of auto-detect from DB
  --provider-id ID  Append ?providerid=ID before encryption (Phase 2.4+)

Do not commit crypto links to git — regenerate after subId changes.
EOF
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  cd "${PROJECT_DIR}"

  if [[ -z "${plain_url}" ]]; then
    plain_url="$(build_plain_sub_url)"
  fi

  if [[ -n "${provider_id}" ]]; then
    plain_url="$(append_provider_id "${plain_url}" "${provider_id}")"
    log "Provider ID appended to URL"
  fi

  log "Plain subscription URL:"
  printf '%s\n' "${plain_url}"

  log "Requesting encrypted link from ${CRYPTO_API} ..."
  local crypto_link
  crypto_link="$(fetch_crypto_link "${plain_url}")"

  echo ""
  echo "Encrypted subscription (share with family):"
  echo "${crypto_link}"
  echo ""
  echo "Import in Happ: + → Subscription URL → paste happ://crypt5/..."
  echo "After server changes, re-run this script and re-import in Happ."

  if [[ "${show_plain}" == "true" ]]; then
    echo ""
    echo "Plain URL (admin): ${plain_url}"
  fi
}

main "$@"

#!/usr/bin/env bash
# Generate X25519 key pair for VLESS Reality (via xray in Docker).

generate_reality_keypair() {
  local private_key="" public_key="" output line key val

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx happroxy_3xui; then
    output="$(docker exec happroxy_3xui xray x25519 2>/dev/null || true)"
  fi

  if [[ -z "${output}" ]]; then
    output="$(docker run --rm ghcr.io/xtls/xray-core:latest xray x25519 2>/dev/null || true)"
  fi

  if [[ -z "${output}" ]]; then
    output="$(docker run --rm teddysun/xray xray x25519 2>/dev/null || true)"
  fi

  if [[ -z "${output}" ]]; then
    printf '[reality-keys] ERROR: cannot run xray x25519 (need Docker)\n' >&2
    return 1
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^[Pp]rivate[[:space:]]*[Kk]ey:[[:space:]]*(.+)$ ]]; then
      private_key="${BASH_REMATCH[1]}"
      private_key="${private_key//[[:space:]]/}"
    elif [[ "${line}" =~ ^[Pp]ublic[[:space:]]*[Kk]ey:[[:space:]]*(.+)$ ]]; then
      public_key="${BASH_REMATCH[1]}"
      public_key="${public_key//[[:space:]]/}"
    elif [[ "${line}" == *":"* ]]; then
      key="${line%%:*}"
      val="${line#*:}"
      key="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
      val="${val//[[:space:]]/}"
      case "${key}" in
        privatekey) private_key="${val}" ;;
        publickey) public_key="${val}" ;;
      esac
    fi
  done <<<"${output}"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    printf '[reality-keys] ERROR: failed to parse xray x25519 output:\n%s\n' "${output}" >&2
    return 1
  fi

  REALITY_PRIVATE_KEY="${private_key}"
  REALITY_PUBLIC_KEY="${public_key}"
  export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
  return 0
}

generate_reality_short_id() {
  local n="${1:-8}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex $((n / 2)) 2>/dev/null | cut -c1-"${n}"
    return
  fi
  head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-"${n}"
}

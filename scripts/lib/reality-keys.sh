#!/usr/bin/env bash
# Generate X25519 key pair for VLESS Reality (xray or Python fallback).

_reality_x25519_output() {
  local out="" bin="" image

  # Official image: ENTRYPOINT is /usr/local/bin/xray — pass subcommand only.
  for image in ghcr.io/xtls/xray-core:latest ghcr.io/xtls/xray-core teddysun/xray:latest teddysun/xray; do
    out="$(docker run --rm "${image}" x25519 2>/dev/null || true)"
    if _reality_output_looks_valid "${out}"; then
      printf '%s' "${out}"
      return 0
    fi
    # Some images need explicit entrypoint override.
    out="$(docker run --rm --entrypoint /usr/local/bin/xray "${image}" x25519 2>/dev/null || true)"
    if _reality_output_looks_valid "${out}"; then
      printf '%s' "${out}"
      return 0
    fi
  done

  # 3X-UI container bundles xray outside PATH.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx happroxy_3xui; then
    out="$(docker exec happroxy_3xui sh -c '
      for p in \
        /usr/local/x-ui/bin/xray-linux-amd64 \
        /usr/local/x-ui/bin/xray \
        /usr/local/bin/xray \
        /usr/bin/xray; do
        if [ -x "$p" ]; then
          "$p" x25519
          exit 0
        fi
      done
      found="$(find /usr/local /app -maxdepth 4 -type f -name "xray*" 2>/dev/null | head -n1)"
      if [ -n "$found" ] && [ -x "$found" ]; then
        "$found" x25519
        exit 0
      fi
      exit 1
    ' 2>/dev/null || true)"
    if _reality_output_looks_valid "${out}"; then
      printf '%s' "${out}"
      return 0
    fi
  fi

  # Python fallback (no extra packages — uses same clamping as Xray).
  if command -v python3 >/dev/null 2>&1; then
    out="$(python3 "${_REALITY_KEYS_LIB_DIR}/reality-keys.py" 2>/dev/null || true)"
    if _reality_output_looks_valid "${out}"; then
      printf '%s' "${out}"
      return 0
    fi
  fi

  return 1
}

_reality_output_looks_valid() {
  local out="$1"
  [[ -n "${out}" ]] || return 1
  [[ "${out}" == *PrivateKey:* ]] || [[ "${out}" == *Private*Key:* ]] || return 1
  [[ "${out}" == *PublicKey:* ]] || [[ "${out}" == *Password*PublicKey*:* ]] || return 1
  [[ "${out}" != *"OCI runtime"* ]] || return 1
  [[ "${out}" != *"executable file not found"* ]] || return 1
  return 0
}

_parse_reality_keypair() {
  local output="$1"
  local private_key="" public_key="" line key val

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^[Pp]rivate[Kk]ey:[[:space:]]*(.+)$ ]]; then
      private_key="${BASH_REMATCH[1]}"
      private_key="${private_key//[[:space:]]/}"
    elif [[ "${line}" =~ ^[Pp]ublic[Kk]ey:[[:space:]]*(.+)$ ]]; then
      public_key="${BASH_REMATCH[1]}"
      public_key="${public_key//[[:space:]]/}"
    elif [[ "${line}" =~ [Pp]assword[[:space:]]*\([Pp]ublic[Kk]ey\):[[:space:]]*(.+)$ ]]; then
      public_key="${BASH_REMATCH[1]}"
      public_key="${public_key//[[:space:]]/}"
    elif [[ "${line}" == *":"* ]]; then
      key="${line%%:*}"
      val="${line#*:}"
      key="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
      val="${val//[[:space:]]/}"
      case "${key}" in
        privatekey) private_key="${val}" ;;
        publickey|password(publickey)) public_key="${val}" ;;
      esac
    fi
  done <<<"${output}"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    return 1
  fi

  REALITY_PRIVATE_KEY="${private_key}"
  REALITY_PUBLIC_KEY="${public_key}"
  export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
  return 0
}

generate_reality_keypair() {
  local output=""

  _REALITY_KEYS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if ! output="$(_reality_x25519_output)"; then
    printf '[reality-keys] ERROR: cannot generate x25519 keys (tried xray Docker images, 3X-UI container, python3)\n' >&2
    printf '[reality-keys] Hint: docker pull ghcr.io/xtls/xray-core:latest\n' >&2
    return 1
  fi

  if ! _parse_reality_keypair "${output}"; then
    printf '[reality-keys] ERROR: failed to parse x25519 output:\n%s\n' "${output}" >&2
    return 1
  fi

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

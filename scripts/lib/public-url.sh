#!/usr/bin/env bash
# Build public panel/subscription URLs from .env (IP or HTTPS domain).
# Intentionally no "set -e" here — this file is sourced by other scripts.

normalize_sub_path() {
  local path="${1:-/sub/family}"
  [[ "${path}" == /* ]] || path="/${path}"
  [[ "${path}" == */ ]] || path="${path}/"
  printf '%s' "${path}"
}

public_scheme() {
  if [[ -n "${PUBLIC_SCHEME:-}" ]]; then
    printf '%s' "${PUBLIC_SCHEME}"
    return
  fi
  if [[ -n "${PANEL_DOMAIN:-}" && "${USE_HTTPS:-true}" != "false" ]]; then
    printf 'https'
  else
    printf 'http'
  fi
}

build_panel_public_url() {
  local scheme path base
  scheme="$(public_scheme)"
  if [[ -n "${PANEL_DOMAIN:-}" ]]; then
    base="${PANEL_DOMAIN}"
  else
    base="${SERVER_IP:?SERVER_IP or PANEL_DOMAIN required}:${PANEL_PORT:-38471}"
  fi
  path="${PANEL_WEB_PATH:-/}"
  [[ "${path}" == /* ]] || path="/${path}"
  printf '%s://%s%s' "${scheme}" "${base}" "${path}"
}

build_sub_public_base() {
  local scheme sub_path base
  scheme="$(public_scheme)"
  sub_path="$(normalize_sub_path "${SUB_PATH:-/sub/family}")"

  if [[ -n "${SUB_PUBLIC_BASE:-}" ]]; then
    local out="${SUB_PUBLIC_BASE}"
    [[ "${out}" == */ ]] || out="${out}/"
    printf '%s' "${out}"
    return
  fi

  if [[ -n "${PANEL_DOMAIN:-}" ]]; then
    base="${PANEL_DOMAIN}"
    printf '%s://%s%s' "${scheme}" "${base}" "${sub_path}"
    return
  fi

  printf 'http://%s:%s%s' "${SERVER_IP:?SERVER_IP required}" "${SUB_PORT:-2096}" "${sub_path}"
}

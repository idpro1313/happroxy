#!/usr/bin/env bash
# Interactive prompts for install / setup (no hardcoded server IP or domain).

happroxy_is_interactive() {
  [[ -t 0 ]] && [[ "${HAPPROXY_NON_INTERACTIVE:-0}" != "1" ]]
}

validate_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS=. read -r o1 o2 o3 o4 <<<"${ip}"
  for o in "${o1}" "${o2}" "${o3}" "${o4}"; do
    [[ "${o}" -le 255 ]] || return 1
  done
}

validate_fqdn() {
  local d="${1,,}"
  [[ "${d}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

# Read line with optional default; empty input keeps default.
prompt_with_default() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${prompt}" "${default}" >&2
  else
    printf '%s: ' "${prompt}" >&2
  fi
  IFS= read -r reply || reply=""
  if [[ -z "${reply}" ]]; then
    printf '%s' "${default}"
  else
    printf '%s' "${reply}"
  fi
}

prompt_server_ip() {
  local detected="${1:-}" ip=""
  while true; do
    ip="$(prompt_with_default "Публичный IP сервера (SERVER_IP)" "${detected}")"
    ip="${ip//[[:space:]]/}"
    if validate_ipv4 "${ip}"; then
      printf '%s' "${ip}"
      return 0
    fi
    printf '[prompt] Некорректный IPv4, повторите.\n' >&2
  done
}

# Optional domain; empty = skip HTTPS for now.
prompt_panel_domain() {
  local current="${1:-}" domain=""
  domain="$(prompt_with_default "Домен панели/подписки (PANEL_DOMAIN, Enter — пропустить)" "${current}")"
  domain="${domain//[[:space:]]/}"
  domain="${domain%/}"
  if [[ -z "${domain}" ]]; then
    printf '%s' ""
    return 0
  fi
  if validate_fqdn "${domain}"; then
    printf '%s' "${domain}"
    return 0
  fi
  printf '[prompt] WARN: домен выглядит необычно: %s (продолжаем)\n' "${domain}" >&2
  printf '%s' "${domain}"
}

set_env_kv() {
  local env_file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${env_file}"
  else
    echo "${key}=${val}" >> "${env_file}"
  fi
}

prompt_install_env() {
  local env_file="$1" detected_ip="${2:-}"
  local ip domain

  if ! happroxy_is_interactive; then
    return 0
  fi

  printf '\n=== Настройка сервера ===\n' >&2
  ip="$(prompt_server_ip "${detected_ip}")"
  set_env_kv "${env_file}" "SERVER_IP" "${ip}"
  printf '[prompt] SERVER_IP=%s\n' "${ip}" >&2

  domain="$(prompt_panel_domain "")"
  if [[ -n "${domain}" ]]; then
    set_env_kv "${env_file}" "PANEL_DOMAIN" "${domain}"
    set_env_kv "${env_file}" "USE_HTTPS" "true"
    printf '[prompt] PANEL_DOMAIN=%s\n' "${domain}" >&2
  else
    printf '[prompt] PANEL_DOMAIN не задан — HTTPS настроите позже: bash scripts/setup-https.sh\n' >&2
  fi
  printf '\n' >&2
}

prompt_setup_https_domain() {
  local current="${1:-}"
  if [[ -n "${current}" ]]; then
    printf '%s' "${current}"
    return 0
  fi
  if happroxy_is_interactive; then
    prompt_panel_domain ""
    return
  fi
  printf '%s' ""
}

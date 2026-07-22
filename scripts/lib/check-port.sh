#!/usr/bin/env bash
# Validate a TCP port for happroxy proxy inbounds.

haproxy_reserved_ports() {
  printf '%s\n' 80 443 8080 8000 9443 10086 17998
}

haproxy_port_in_use() {
  local port="$1"
  ss -tln 2>/dev/null | grep -qE ":${port} "
}

haproxy_check_proxy_port() {
  local port="$1"
  local label="${2:-port}"
  local reserved p

  if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
    printf 'Invalid port: %s\n' "${port}" >&2
    return 1
  fi

  while read -r reserved; do
    [[ -z "${reserved}" ]] && continue
    if [[ "${port}" -eq "${reserved}" ]]; then
      printf 'Port %s (%s) is reserved for Traefik/other services on this VM.\n' "${port}" "${label}" >&2
      return 1
    fi
  done < <(haproxy_reserved_ports)

  if haproxy_port_in_use "${port}"; then
    printf 'Port %s (%s) is already in use on the host.\n' "${port}" "${label}" >&2
    return 1
  fi

  return 0
}

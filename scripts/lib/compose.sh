#!/usr/bin/env bash
# docker compose helpers — keep Traefik overlay when PANEL_DOMAIN is set.

compose_files_args() {
  local project_dir="${1:?project dir}"
  local files=(-f "${project_dir}/docker-compose.yml")
  if [[ -n "${PANEL_DOMAIN:-}" && -f "${project_dir}/docker-compose.traefik.yml" ]]; then
    files+=(-f "${project_dir}/docker-compose.traefik.yml")
  fi
  printf '%s\n' "${files[@]}"
}

compose_cmd() {
  local project_dir="${1:?project dir}"
  shift
  local -a files
  mapfile -t files < <(compose_files_args "${project_dir}")
  docker compose "${files[@]}" "$@"
}

compose_up() {
  local project_dir="${1:?project dir}"
  shift || true
  compose_cmd "${project_dir}" up -d "$@"
}

compose_stop() {
  local project_dir="${1:?project dir}"
  shift || true
  compose_cmd "${project_dir}" stop "$@"
}

compose_pull() {
  local project_dir="${1:?project dir}"
  shift || true
  compose_cmd "${project_dir}" pull "$@"
}

using_traefik_overlay() {
  local project_dir="${1:?project dir}"
  [[ -n "${PANEL_DOMAIN:-}" && -f "${project_dir}/docker-compose.traefik.yml" ]]
}

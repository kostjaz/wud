#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${containers_json:-}" ]]; then
    echo "containers_json is required; configure the command trigger in batch mode" >&2
    exit 1
fi

if ! jq -e 'type == "array" and length > 0' >/dev/null <<<"${containers_json}"; then
    echo "containers_json must be a non-empty JSON array" >&2
    exit 1
fi

mapfile -t services < <(
    jq -r '
        .[]
        | .labels["com.docker.compose.service"] // empty
    ' <<<"${containers_json}" | sort -u
)

if (( ${#services[@]} == 0 )); then
    echo "No Docker Compose services found in containers_json" >&2
    exit 1
fi

mapfile -t detected_projects < <(
    jq -r '
        .[]
        | .labels["com.docker.compose.project"] // empty
    ' <<<"${containers_json}" | sort -u
)

if (( ${#detected_projects[@]} > 1 )); then
    echo "A single command trigger batch cannot update multiple Compose projects" >&2
    printf 'Projects: %s\n' "${detected_projects[*]}" >&2
    exit 1
fi

compose_file="${WUD_COMPOSE_FILE:-/opt/s2snext/docker-compose.yml}"
compose_project="${WUD_COMPOSE_PROJECT:-${detected_projects[0]:-}}"

if [[ ! -r "${compose_file}" ]]; then
    echo "Compose file is not readable: ${compose_file}" >&2
    exit 1
fi

compose_command=(docker compose --file "${compose_file}")

if [[ -n "${compose_project}" ]]; then
    compose_command+=(--project-name "${compose_project}")
fi

if [[ -n "${WUD_COMPOSE_PROJECT_DIRECTORY:-}" ]]; then
    compose_command+=(--project-directory "${WUD_COMPOSE_PROJECT_DIRECTORY}")
fi

printf 'Updating Compose services:'
printf ' %q' "${services[@]}"
printf '\n'

"${compose_command[@]}" up \
    --detach \
    --pull always \
    --no-deps \
    "${services[@]}"

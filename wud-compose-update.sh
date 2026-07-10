#!/usr/bin/env bash
set -Eeuo pipefail

lock_file="${WUD_COMPOSE_LOCK_FILE:-/tmp/wud-compose-update.lock}"
lock_timeout="${WUD_COMPOSE_LOCK_TIMEOUT:-1800}"

if ! command -v flock >/dev/null 2>&1; then
    echo "flock is required but was not found" >&2
    exit 1
fi

exec 9>"${lock_file}"
lock_deadline=$((SECONDS + lock_timeout))
while ! flock -n 9; do
    if (( SECONDS >= lock_deadline )); then
        echo "Another Compose update is still running; timed out waiting for lock: ${lock_file}" >&2
        exit 75
    fi

    sleep 1
done

echo "Acquired Compose update lock: ${lock_file}"

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

normalize_bool() {
    case "${1,,}" in
        1|true|yes|y|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

registry_login_server() {
    local registry_url="$1"

    registry_url="${registry_url#http://}"
    registry_url="${registry_url#https://}"
    printf '%s\n' "${registry_url%%/*}"
}

configure_docker_registry_auth() {
    local docker_config registry_server

    if ! normalize_bool "${WUD_COMPOSE_DOCKER_LOGIN:-true}"; then
        echo "Docker registry login is disabled"
        return 0
    fi

    if [[ -z "${WUD_REGISTRY_CUSTOM_YANDEX_URL:-}" ||
        -z "${WUD_REGISTRY_CUSTOM_YANDEX_LOGIN:-}" ||
        -z "${WUD_REGISTRY_CUSTOM_YANDEX_PASSWORD:-}" ]]; then
        echo "Docker registry login skipped: WUD_REGISTRY_CUSTOM_YANDEX_URL, LOGIN or PASSWORD is not set"
        return 0
    fi

    docker_config="${WUD_COMPOSE_DOCKER_CONFIG:-${DOCKER_CONFIG:-/tmp/wud-docker-config}}"
    if [[ "${docker_config}" == "/" ]]; then
        docker_config="/tmp/wud-docker-config"
    fi

    export DOCKER_CONFIG="${docker_config}"
    mkdir -p "${DOCKER_CONFIG}"

    registry_server="$(registry_login_server "${WUD_REGISTRY_CUSTOM_YANDEX_URL}")"
    echo "Logging in to Docker registry: ${registry_server}"
    printf '%s' "${WUD_REGISTRY_CUSTOM_YANDEX_PASSWORD}" \
        | docker login "${registry_server}" \
            --username "${WUD_REGISTRY_CUSTOM_YANDEX_LOGIN}" \
            --password-stdin
}

collect_service_image_ids() {
    local service container_id image_id

    for service in "${services[@]}"; do
        while IFS= read -r container_id; do
            [[ -n "${container_id}" ]] || continue

            image_id="$(docker inspect --format '{{.Image}}' "${container_id}" 2>/dev/null || true)"
            [[ -n "${image_id}" ]] || continue
            printf '%s\n' "${image_id}"
        done < <("${compose_command[@]}" ps -q "${service}" 2>/dev/null || true)
    done | sort -u
}

image_id_in_list() {
    local needle="$1"
    local image_id
    shift

    for image_id in "$@"; do
        [[ "${image_id}" != "${needle}" ]] || return 0
    done

    return 1
}

image_is_used_by_container() {
    local image_id="$1"

    [[ -n "$(docker ps --all --quiet --filter "ancestor=${image_id}" 2>/dev/null)" ]]
}

prune_old_service_images() {
    local image_id
    local -a previous_image_ids=("$@")
    local -a current_image_ids=()

    if (( ${#previous_image_ids[@]} == 0 )); then
        echo "No previous service images found to prune"
        return 0
    fi

    mapfile -t current_image_ids < <(collect_service_image_ids)

    for image_id in "${previous_image_ids[@]}"; do
        if image_id_in_list "${image_id}" "${current_image_ids[@]}"; then
            echo "Keeping image still used by updated services: ${image_id}"
            continue
        fi

        if image_is_used_by_container "${image_id}"; then
            echo "Keeping image still used by another container: ${image_id}"
            continue
        fi

        echo "Removing old service image: ${image_id}"
        if ! docker image rm "${image_id}"; then
            echo "Failed to remove old service image: ${image_id}" >&2
        fi
    done
}

configure_docker_registry_auth

mapfile -t previous_image_ids < <(collect_service_image_ids)

printf 'Updating Compose services:'
printf ' %q' "${services[@]}"
printf '\n'

"${compose_command[@]}" up \
    --detach \
    --pull always \
    --no-deps \
    "${services[@]}"

if normalize_bool "${WUD_COMPOSE_PRUNE_OLD_IMAGES:-true}"; then
    prune_old_service_images "${previous_image_ids[@]}"
else
    echo "Old service image pruning is disabled"
fi

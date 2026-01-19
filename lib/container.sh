#!/bin/bash
# container.sh - Start and manage the dev container

# Default UID/GID for devcontainer users (virtiofs mapped)
CONTAINER_USER_UID="${CONTAINER_USER_UID:-107}"
CONTAINER_USER_GID="${CONTAINER_USER_GID:-107}"
CONTAINER_NEEDS_INIT_EXEC="false"
CONTAINER_NEEDS_INIT_STAGE="false"
CONTAINER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODESPACE_HOST_ROOT="$(dirname "${CONTAINER_LIB_DIR}")"
WORKSPACE_INIT_SOURCE="${CODESPACE_HOST_ROOT}/init/workspace-init.sh"
WORKSPACE_INIT_DEST_DIR="/tmp/codespace-init"
WORKSPACE_INIT_DEST="${WORKSPACE_INIT_DEST_DIR}/workspace-init.sh"
WORKSPACE_INIT_MOUNTED="false"
WORKSPACE_INIT_MOUNT_SOURCE=""
CONTAINER_LOG_STREAM_PID=""
WORKSPACE_INIT_LOG="/tmp/workspace-init.log"

fix_workspace_permissions() {
    local workspace="$1"
    # No-op on host side - virtiofs doesn't allow chown from host
    # Permissions are fixed inside the container after start
    log_debug "workspace permissions will be fixed inside container"
}

fix_permissions_in_container() {
    local container="$1"
    local workspace="$2"

    log_info "fixing workspace permissions inside container"

    # Run chown inside the container where we have permission
    if ! docker exec -u 0 "${container}" chown -R "${CONTAINER_USER_UID}:${CONTAINER_USER_GID}" "${workspace}" 2>/dev/null; then
        log_warn "could not fix workspace permissions - user may have issues"
    fi
}

start_devcontainer() {
    local image="$1"
    local name="$2"
    local workspace="$3"

    # Normalize: strip CR/LF
    image="$(printf '%s' "$image" | tr -d '\r\n')"

    # Trim surrounding whitespace
    image="$(echo "$image" | xargs)"

    # Strip *all* quote characters – handles "…", '…', …''
    image="${image//\"/}"
    image="${image//\'/}"

    if [[ -z "$image" ]]; then
        log_error "devcontainer image is empty after normalization"
        exit 1
    fi

    log_info "starting dev container: ${name} with image: ${image}"

    CONTAINER_NEEDS_INIT_EXEC="false"
    CONTAINER_NEEDS_INIT_STAGE="false"

    # Remove existing container if present
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}\$"; then
        log_info "removing existing container"
        docker rm -f "${name}" >/dev/null 2>&1 || true
    fi

    local run_args=(
        --name "${name}"
        --hostname "${REPO_NAME}"
        -d
    )

    # Init process (recommended for proper signal handling)
    local use_init="false"
    if [[ "${DC_INIT}" == "true" ]]; then
        use_init="true"
    fi

    # Network mode - host for simplicity with Coder
    run_args+=(--network host)

    local docker_mount_root="/workspaces"
    local config_mount_source="/run/config"
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        docker_mount_root="/var/workspaces"
        config_mount_source="/var/config"
    fi

    # Workspace mount
    local workspace_mount_source="${workspace}"
    local workspace_mount_target="${workspace}"
    if [[ "${workspace}" == /workspaces/* ]]; then
        workspace_mount_source="${docker_mount_root}"
        workspace_mount_target="/workspaces"
        log_debug "mounting workspace root to avoid missing subdir in daemon namespace"
    fi
    run_args+=(-v "${workspace_mount_source}:${workspace_mount_target}:cached")
    run_args+=(-w "${workspace}")

    if [[ -S /var/run/docker.sock ]]; then
        run_args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
    fi

    # Provide docker CLI inside the devcontainer when using dind
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        local docker_stage="/var/run/codespace/docker"
        if [[ -x "/usr/local/bin/docker" ]]; then
            mkdir -p "$(dirname "${docker_stage}")" 2>/dev/null || true
            if cp "/usr/local/bin/docker" "${docker_stage}" 2>/dev/null; then
                chmod 755 "${docker_stage}" 2>/dev/null || true
                run_args+=(-v "${docker_stage}:/usr/local/bin/docker:ro")
            else
                log_warn "failed to stage docker CLI at ${docker_stage}"
            fi
        else
            log_warn "docker CLI not found at /usr/local/bin/docker; skipping mount"
        fi
    fi

    # Config mount (for tokens)
    run_args+=(-v "${config_mount_source}:/run/config:ro")

    # Stage workspace init on the shared workspace mount for dind, then mount it in.
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        local stage_dir="${docker_mount_root}/.codespace-init"
        local stage_path="${stage_dir}/workspace-init.sh"
        if mkdir -p "${stage_dir}" 2>/dev/null; then
            chmod 777 "${stage_dir}" 2>/dev/null || true
            if cp "${WORKSPACE_INIT_SOURCE}" "${stage_path}" 2>/dev/null; then
                chmod +x "${stage_path}" 2>/dev/null || true
                WORKSPACE_INIT_MOUNTED="true"
                WORKSPACE_INIT_MOUNT_SOURCE="${stage_path}"
                run_args+=(-v "${WORKSPACE_INIT_MOUNT_SOURCE}:${WORKSPACE_INIT_DEST}:ro")
                log_debug "staged workspace-init at ${WORKSPACE_INIT_MOUNT_SOURCE}"
            else
                log_warn "failed to stage workspace-init at ${stage_path}"
            fi
        else
            log_warn "failed to create workspace-init staging dir at ${stage_dir}"
        fi
    fi

    # Additional mounts from devcontainer.json
    add_configured_mounts run_args

    # Environment variables
    add_environment_vars run_args

    # Security configuration
    add_security_config run_args

    # Additional run args from devcontainer.json
    if [[ -n "${DC_RUN_ARGS}" ]]; then
        # Word splitting intentional here
        # shellcheck disable=SC2206
        run_args+=(${DC_RUN_ARGS})
    fi

    # Image and command
    run_args+=(--user "${CONTAINER_USER_UID}:${CONTAINER_USER_GID}")
    local cmd_args=()
    if image_has_entrypoint_or_cmd "${image}"; then
        log_info "image has entrypoint/cmd; using image defaults and starting workspace init via exec"
        CONTAINER_NEEDS_INIT_EXEC="true"
    else
        log_info "image has no entrypoint/cmd (or only a shell); waiting to exec workspace-init (coder agent stays PID 1)"
        CONTAINER_NEEDS_INIT_STAGE="true"
        run_args+=(--entrypoint "/bin/sh")
        cmd_args+=("-c" "while [ ! -x ${WORKSPACE_INIT_DEST} ]; do sleep 0.2; done; exec ${WORKSPACE_INIT_DEST}")
    fi
    run_args+=("${image}")
    run_args+=("${cmd_args[@]}")

    log_info "devcontainer image raw: '$(printf '%q' "$image")'"
    log_debug "run_args as array:"
    for i in "${!run_args[@]}"; do
        log_debug "  [$i] = '$(printf '%q' "${run_args[$i]}")'"
    done

    log_debug "docker run ${run_args[*]}"

    local run_output=""
    local run_status=0
    if [[ "${use_init}" == "true" ]]; then
        local errexit_set=0
        case $- in
            *e*) errexit_set=1 ;;
        esac
        if ((errexit_set)); then
            set +e
        fi
        run_output=$(docker run --init "${run_args[@]}" 2>&1)
        run_status=$?
        if ((errexit_set)); then
            set -e
        fi
        if [[ -z "${run_output}" ]]; then
            run_output="(no output)"
        fi

        if ((run_status != 0)); then
            if echo "${run_output}" | grep -qi "docker-init"; then
                log_warn "docker-init not available on daemon; retrying without --init"
                docker rm -f "${name}" >/dev/null 2>&1 || true
                use_init="false"
            else
                log_error "failed to start container"
                log_error "${run_output}"
                exit 1
            fi
        else
            if docker ps -a --format '{{.Names}}' | grep -q "^${name}\$"; then
                local state_status=""
                local state_error=""
                state_status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"
                state_error="$(docker inspect -f '{{.State.Error}}' "${name}" 2>/dev/null || true)"
                if [[ "${state_status}" == "created" ]] && echo "${state_error}" | grep -qi "docker-init"; then
                    log_warn "docker-init not available on daemon; retrying without --init"
                    docker rm -f "${name}" >/dev/null 2>&1 || true
                    use_init="false"
                fi
            fi
        fi
    fi

    if [[ "${use_init}" == "false" ]]; then
        local errexit_set=0
        case $- in
            *e*) errexit_set=1 ;;
        esac
        if ((errexit_set)); then
            set +e
        fi
        run_output=$(docker run "${run_args[@]}" 2>&1)
        run_status=$?
        if ((errexit_set)); then
            set -e
        fi
        if ((run_status != 0)); then
            log_error "failed to start container"
            log_error "${run_output}"
            exit 1
        fi
    fi

    # Wait for container to be running
    local attempts=0
    while [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != "true" ]]; do
        ((attempts++))
        if ((attempts > 30)); then
            log_error "container failed to start"
            docker logs "${name}" 2>&1 | tail -20
            exit 1
        fi
        sleep 0.5
    done

    log_info "container started"
    start_devcontainer_log_stream "${name}"

    if [[ "${CONTAINER_NEEDS_INIT_STAGE}" == "true" && "${CONTAINER_NEEDS_INIT_EXEC}" != "true" ]]; then
        if ! stage_workspace_init "${name}"; then
            log_error "failed to stage workspace init script for entrypointless image"
            exit 1
        fi
    fi
}

add_configured_mounts() {
    local -n args=$1

    if [[ "${DC_MOUNTS}" == "[]" || -z "${DC_MOUNTS}" ]]; then
        return
    fi

    while IFS= read -r mount; do
        [[ -z "${mount}" ]] && continue

        if [[ "${mount:0:1}" == "{" ]]; then
            # Object format: {"type": "bind", "source": "...", "target": "..."}
            local type source target
            type=$(echo "${mount}" | jq -r '.type // "bind"')
            source=$(echo "${mount}" | jq -r '.source')
            target=$(echo "${mount}" | jq -r '.target')

            # Expand variables
            source=$(expand_mount_path "${source}")
            target=$(expand_mount_path "${target}")

            case "${type}" in
                bind)
                    # Ensure source exists for bind mounts
                    if [[ ! -e "${source}" ]]; then
                        mkdir -p "${source}"
                    fi
                    args+=(-v "${source}:${target}")
                    ;;
                volume)
                    args+=(-v "${source}:${target}")
                    ;;
                tmpfs)
                    args+=(--tmpfs "${target}")
                    ;;
            esac
        else
            # String format: "type=bind,source=...,target=..."
            local expanded
            expanded=$(expand_mount_path "${mount}")
            args+=(--mount "${expanded}")
        fi
    done < <(echo "${DC_MOUNTS}" | jq -r '.[] | @json' 2>/dev/null)
}

expand_mount_path() {
    local path="$1"

    # Common devcontainer variables
    path="${path//\$\{localWorkspaceFolder\}/${WORKDIR}}"
    path="${path//\$\{containerWorkspaceFolder\}/${WORKDIR}}"
    path="${path//\$\{localWorkspaceFolderBasename\}/${REPO_NAME}}"
    path="${path//\$\{localEnv:HOME\}/${HOME:-/root}}"
    path="${path//\$\{localEnv:USER\}/${USER:-root}}"

    echo "${path}"
}

image_has_entrypoint_or_cmd() {
    local image="$1"
    local entrypoint="null"
    local cmd="null"

    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        return 1
    fi

    entrypoint="$(docker image inspect -f '{{json .Config.Entrypoint}}' "${image}" 2>/dev/null || echo "null")"
    cmd="$(docker image inspect -f '{{json .Config.Cmd}}' "${image}" 2>/dev/null || echo "null")"

    if [[ "${entrypoint}" != "null" && "${entrypoint}" != "[]" ]]; then
        return 0
    fi
    if [[ "${cmd}" != "null" && "${cmd}" != "[]" ]]; then
        case "${cmd}" in
            "[\"/bin/bash\"]"|"[\"/bin/sh\"]"|"[\"bash\"]"|"[\"sh\"]")
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    fi
    return 1
}

start_workspace_init_exec() {
    local container="$1"

    log_info "starting workspace services inside container"

    if ! stage_workspace_init "${container}"; then
        log_warn "failed to stage workspace-init inside container"
        return
    fi

    if ! docker exec -d -u "${CONTAINER_USER_UID}:${CONTAINER_USER_GID}" \
        "${container}" /bin/sh -c "${WORKSPACE_INIT_DEST} >/proc/1/fd/1 2>/proc/1/fd/2" >/dev/null 2>&1; then
        log_warn "failed to start workspace init via exec"
        return
    fi

    sleep 2
    if docker exec "${container}" /bin/sh -c 'ps aux 2>/dev/null | grep -v grep | grep -q "coder agent"' >/dev/null 2>&1; then
        log_info "coder agent is running"
    else
        log_warn "coder agent not detected yet; check /tmp/workspace-init.log in the devcontainer"
    fi
}

start_devcontainer_log_stream() {
    local container="$1"

    if [[ -n "${CONTAINER_LOG_STREAM_PID}" ]]; then
        return
    fi

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}\$"; then
        return
    fi

    log_info "streaming devcontainer logs"
    docker logs -f "${container}" 2>&1 | sed 's/^/[devcontainer] /' >&2 &
    CONTAINER_LOG_STREAM_PID=$!
}

stage_workspace_init() {
    local container="$1"

    if [[ "${WORKSPACE_INIT_MOUNTED}" == "true" ]]; then
        return 0
    fi

    if [[ ! -f "${WORKSPACE_INIT_SOURCE}" ]]; then
        log_error "workspace init script not found at ${WORKSPACE_INIT_SOURCE}"
        return 1
    fi

    if ! docker exec -u 0 "${container}" /bin/sh -c "mkdir -p '${WORKSPACE_INIT_DEST_DIR}'" >/dev/null 2>&1; then
        log_warn "failed to create workspace init directory in container"
        return 1
    fi

    if ! docker exec -i -u 0 "${container}" /bin/sh -c "cat > '${WORKSPACE_INIT_DEST}' && chmod +x '${WORKSPACE_INIT_DEST}'" < "${WORKSPACE_INIT_SOURCE}"; then
        log_warn "failed to copy workspace init script into container"
        return 1
    fi

    return 0
}

add_environment_vars() {
    local -n args=$1

    # Standard devcontainer environment
    args+=(-e "REMOTE_CONTAINERS=true")
    args+=(-e "CODESPACES=true")
    args+=(-e "CODESPACE_NAME=${REPO_NAME}")

    # Tokens from config
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        args+=(-e "GITHUB_TOKEN=${GITHUB_TOKEN}")
        args+=(-e "GH_ENTERPRISE_TOKEN=${GITHUB_TOKEN}")
    fi
    if [[ -n "${CODER_AGENT_TOKEN:-}" ]]; then
        args+=(-e "CODER_AGENT_TOKEN=${CODER_AGENT_TOKEN}")
    fi
    if [[ -n "${CODER_AGENT_URL:-}" ]]; then
        args+=(-e "CODER_AGENT_URL=${CODER_AGENT_URL}")
    fi

    # VS Code server port (support both names)
    if [[ -n "${CODER_VSCODE_PORT:-}" ]]; then
        args+=(-e "CODER_VSCODE_PORT=${CODER_VSCODE_PORT}")
        args+=(-e "CODE_SERVER_PORT=${CODER_VSCODE_PORT}")
    fi

    # Workspace metadata
    if [[ -n "${WORKSPACE_ID:-}" ]]; then
        args+=(-e "WORKSPACE_ID=${WORKSPACE_ID}")
    fi

    if [[ -n "${CODER_VERSION:-}" ]]; then
        args+=(-e "CODER_VERSION=${CODER_VERSION}")
    fi

    # Remote user for scripts
    if [[ -n "${DC_REMOTE_USER}" ]]; then
        args+=(-e "REMOTE_USER=${DC_REMOTE_USER}")
    fi

    local user_env="${DC_REMOTE_USER:-${REMOTE_USER:-codespace}}"
    args+=(-e "USER=${user_env}")
    args+=(-e "LOGNAME=${user_env}")
    args+=(-e "USERNAME=${user_env}")
    args+=(-e "PATH=${PATH}")

    # Container env from devcontainer.json
    if [[ "${DC_CONTAINER_ENV}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            value=$(expand_env_value "${value}")
            args+=(-e "${key}=${value}")
        done < <(echo "${DC_CONTAINER_ENV}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi

    # Remote env from devcontainer.json
    if [[ "${DC_REMOTE_ENV}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            value=$(expand_env_value "${value}")
            args+=(-e "${key}=${value}")
        done < <(echo "${DC_REMOTE_ENV}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
}

expand_env_value() {
    local value="$1"

    # Expand ${localEnv:VAR} patterns
    while [[ "${value}" =~ \$\{localEnv:([^}]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"
        value="${value//\$\{localEnv:${var_name}\}/${var_value}}"
    done

    # Expand ${containerEnv:VAR} - these reference other container env vars
    # We can't fully resolve these at build time, so leave them for the shell
    while [[ "${value}" =~ \$\{containerEnv:([^}]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        value="${value//\$\{containerEnv:${var_name}\}/\$${var_name}}"
    done

    echo "${value}"
}

add_security_config() {
    local -n args=$1

    # Privileged mode
    if [[ "${DC_PRIVILEGED}" == "true" ]]; then
        args+=(--privileged)
    fi

    # Capabilities
    if [[ "${DC_CAP_ADD}" != "[]" ]]; then
        while IFS= read -r cap; do
            [[ -n "${cap}" ]] && args+=(--cap-add "${cap}")
        done < <(echo "${DC_CAP_ADD}" | jq -r '.[]')
    fi

    # Security options
    if [[ "${DC_SECURITY_OPT}" != "[]" ]]; then
        while IFS= read -r opt; do
            [[ -n "${opt}" ]] && args+=(--security-opt "${opt}")
        done < <(echo "${DC_SECURITY_OPT}" | jq -r '.[]')
    fi
}

# Execute a command inside the container
exec_in_container() {
    local container="$1"
    shift
    local cmd=("$@")

    local exec_args=()

    # Run as remote user if specified
    if [[ -n "${DC_REMOTE_USER}" ]]; then
        exec_args+=(-u "${DC_REMOTE_USER}")
    fi

    # Working directory
    exec_args+=(-w "${WORKDIR}")

    docker exec "${exec_args[@]}" "${container}" "${cmd[@]}"
}

# Execute interactively (for shells)
exec_interactive() {
    local container="$1"
    shift
    local cmd=("$@")

    local exec_args=(-it)

    if [[ -n "${DC_REMOTE_USER}" ]]; then
        exec_args+=(-u "${DC_REMOTE_USER}")
    fi

    exec_args+=(-w "${WORKDIR}")

    docker exec "${exec_args[@]}" "${container}" "${cmd[@]}"
}

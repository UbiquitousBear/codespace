#!/bin/bash
# container.sh - Start and manage the dev container

# Default UID/GID for devcontainer users (vscode, codespace, etc.)
CONTAINER_USER_UID="${CONTAINER_USER_UID:-1000}"
CONTAINER_USER_GID="${CONTAINER_USER_GID:-1000}"

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
    if ! docker exec "${container}" chown -R "${CONTAINER_USER_UID}:${CONTAINER_USER_GID}" "${workspace}" 2>/dev/null; then
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
    if [[ "${DC_INIT}" == "true" ]]; then
        run_args+=(--init)
    fi

    # Network mode - host for simplicity with Coder
    run_args+=(--network host)

    # Workspace mount
    run_args+=(-v "${workspace}:${workspace}:cached")
    run_args+=(-w "${workspace}")

    # Config mount (for tokens)
    run_args+=(-v "/run/config:/run/config:ro")

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
    run_args+=("${image}")
    run_args+=(sleep infinity)

    log_info "devcontainer image raw: '$(printf '%q' "$image")'"
    log_debug "run_args as array:"
    for i in "${!run_args[@]}"; do
        log_debug "  [$i] = '$(printf '%q' "${run_args[$i]}")'"
    done

    log_debug "docker run ${run_args[*]}"

    if ! docker run "${run_args[@]}" >/dev/null; then
        log_error "failed to start container"
        exit 1
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

    # Remote user for scripts
    if [[ -n "${DC_REMOTE_USER}" ]]; then
        args+=(-e "REMOTE_USER=${DC_REMOTE_USER}")
    fi

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

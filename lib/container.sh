#!/usr/bin/env bash
# lib/container.sh

start_container() {
    local image="$1"
    local name="$2"
    
    # Remove existing container if present
    docker rm -f "${name}" 2>/dev/null || true
    
    local run_args=(
        --name "${name}"
        --hostname "${WORKSPACE_NAME}"
        -d
        --init
    )
    
    # Workspace mount
    run_args+=(-v "${WORKSPACE_PATH}:/workspaces/${WORKSPACE_NAME}:cached")
    run_args+=(-w "/workspaces/${WORKSPACE_NAME}")
    
    # Additional mounts from config
    add_mounts run_args
    
    # Environment variables
    add_environment run_args
    
    # User
    if [[ -n "${DEVCONTAINER_REMOTE_USER}" ]]; then
        # We'll start as root and su later, or use --user
        # Most devcontainers expect to start as root then drop privileges
        run_args+=(-e "REMOTE_USER=${DEVCONTAINER_REMOTE_USER}")
    fi
    
    # Security options
    if [[ "${DEVCONTAINER_PRIVILEGED}" == "true" ]]; then
        run_args+=(--privileged)
    fi
    
    # Cap add
    if [[ "${DEVCONTAINER_CAP_ADD}" != "[]" ]]; then
        while IFS= read -r cap; do
            run_args+=(--cap-add "${cap}")
        done < <(echo "${DEVCONTAINER_CAP_ADD}" | jq -r '.[]')
    fi
    
    # Security opts
    if [[ "${DEVCONTAINER_SECURITY_OPT}" != "[]" ]]; then
        while IFS= read -r opt; do
            run_args+=(--security-opt "${opt}")
        done < <(echo "${DEVCONTAINER_SECURITY_OPT}" | jq -r '.[]')
    fi
    
    # Additional run args (escape hatch from devcontainer.json)
    if [[ -n "${DEVCONTAINER_RUN_ARGS}" ]]; then
        # shellcheck disable=SC2206
        run_args+=(${DEVCONTAINER_RUN_ARGS})
    fi
    
    # Keep container running
    run_args+=("${image}")
    run_args+=(sleep infinity)
    
    log debug "docker run ${run_args[*]}"
    docker run "${run_args[@]}"
    
    # Wait for container to be running
    local attempts=0
    while [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != "true" ]]; do
        ((attempts++))
        if ((attempts > 30)); then
            log error "container failed to start"
            docker logs "${name}"
            exit 1
        fi
        sleep 0.5
    done
    
    log info "container started: ${name}"
}

add_mounts() {
    local -n args=$1
    
    if [[ "${DEVCONTAINER_MOUNTS}" == "[]" ]]; then
        return
    fi
    
    while IFS= read -r mount; do
        # Mount can be a string "type=bind,source=...,target=..." or object
        if [[ "${mount:0:1}" == "{" ]]; then
            # Object format
            local type source target
            type=$(echo "${mount}" | jq -r '.type // "bind"')
            source=$(echo "${mount}" | jq -r '.source')
            target=$(echo "${mount}" | jq -r '.target')
            
            # Expand variables in source
            source=$(expand_mount_vars "${source}")
            
            if [[ "${type}" == "bind" ]]; then
                args+=(-v "${source}:${target}")
            elif [[ "${type}" == "volume" ]]; then
                args+=(-v "${source}:${target}")
            elif [[ "${type}" == "tmpfs" ]]; then
                args+=(--tmpfs "${target}")
            fi
        else
            # String format - pass through
            mount=$(expand_mount_vars "${mount}")
            args+=(--mount "${mount}")
        fi
    done < <(echo "${DEVCONTAINER_MOUNTS}" | jq -c '.[]')
}

expand_mount_vars() {
    local mount="$1"
    
    # Common variables used in devcontainer mounts
    mount="${mount//\$\{localWorkspaceFolder\}/${WORKSPACE_PATH}}"
    mount="${mount//\$\{containerWorkspaceFolder\}/\/workspaces\/${WORKSPACE_NAME}}"
    mount="${mount//\$\{localEnv:HOME\}/${HOME:-/root}}"
    mount="${mount//\$\{localEnv:USER\}/${USER:-root}}"
    
    echo "${mount}"
}

add_environment() {
    local -n args=$1
    
    # Container env
    if [[ "${DEVCONTAINER_CONTAINER_ENV}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            value=$(expand_env_vars "${value}")
            args+=(-e "${key}=${value}")
        done < <(echo "${DEVCONTAINER_CONTAINER_ENV}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    # Remote env (for when user connects)
    if [[ "${DEVCONTAINER_REMOTE_ENV}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            value=$(expand_env_vars "${value}")
            args+=(-e "${key}=${value}")
        done < <(echo "${DEVCONTAINER_REMOTE_ENV}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    # Standard devcontainer env vars
    args+=(-e "REMOTE_CONTAINERS=true")
    args+=(-e "CODESPACES=true")
    args+=(-e "CODESPACE_NAME=${WORKSPACE_NAME}")
}

expand_env_vars() {
    local value="$1"
    
    # Expand ${localEnv:VAR} and ${containerEnv:VAR} patterns
    # For localEnv, use host values; containerEnv handled at runtime
    while [[ "${value}" =~ \$\{localEnv:([^}]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"
        value="${value//\$\{localEnv:${var_name}\}/${var_value}}"
    done
    
    echo "${value}"
}

exec_in_container() {
    local container="$1"
    shift
    local cmd=("$@")
    
    local user_flag=""
    if [[ -n "${DEVCONTAINER_REMOTE_USER}" ]]; then
        user_flag="-u ${DEVCONTAINER_REMOTE_USER}"
    fi
    
    # shellcheck disable=SC2086
    docker exec ${user_flag} "${container}" "${cmd[@]}"
}
#!/usr/bin/env bash
# lib/config.sh

# Parsed config - populated by parse_config
DEVCONTAINER_IMAGE=""
DEVCONTAINER_DOCKERFILE=""
DEVCONTAINER_CONTEXT=""
DEVCONTAINER_BUILD_ARGS=""
DEVCONTAINER_FEATURES=""
DEVCONTAINER_MOUNTS=""
DEVCONTAINER_CONTAINER_ENV=""
DEVCONTAINER_REMOTE_USER=""
DEVCONTAINER_REMOTE_ENV=""
DEVCONTAINER_POST_CREATE_COMMAND=""
DEVCONTAINER_POST_START_COMMAND=""
DEVCONTAINER_POST_ATTACH_COMMAND=""
DEVCONTAINER_ON_CREATE_COMMAND=""
DEVCONTAINER_UPDATE_CONTENT_COMMAND=""
DEVCONTAINER_FORWARD_PORTS=""
DEVCONTAINER_PRIVILEGED=""
DEVCONTAINER_CAP_ADD=""
DEVCONTAINER_SECURITY_OPT=""
DEVCONTAINER_RUN_ARGS=""

discover_config_dir() {
    local workspace="$1"
    
    # Priority order per spec
    local paths=(
        ".devcontainer/devcontainer.json"
        ".devcontainer.json"
    )
    
    # Check standard paths
    for p in "${paths[@]}"; do
        if [[ -f "${workspace}/${p}" ]]; then
            dirname "${workspace}/${p}"
            return 0
        fi
    done
    
    # Check for subdirectory configs (multi-config)
    # User can specify via DEVCONTAINER_CONFIG env
    if [[ -n "${DEVCONTAINER_CONFIG:-}" ]]; then
        local specified="${workspace}/.devcontainer/${DEVCONTAINER_CONFIG}/devcontainer.json"
        if [[ -f "${specified}" ]]; then
            dirname "${specified}"
            return 0
        fi
    fi
    
    # Check for any subdirectory (take first if only one)
    local subdirs=()
    if [[ -d "${workspace}/.devcontainer" ]]; then
        while IFS= read -r -d '' dir; do
            if [[ -f "${dir}/devcontainer.json" ]]; then
                subdirs+=("${dir}")
            fi
        done < <(find "${workspace}/.devcontainer" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    
    if ((${#subdirs[@]} == 1)); then
        echo "${subdirs[0]}"
        return 0
    elif ((${#subdirs[@]} > 1)); then
        log warn "multiple devcontainer configs found, set DEVCONTAINER_CONFIG to choose"
        log warn "available: ${subdirs[*]}"
        # Default to first alphabetically
        echo "${subdirs[0]}"
        return 0
    fi
    
    return 1
}

parse_config() {
    local config_file="$1"
    
    if ! command -v jq &>/dev/null; then
        log error "jq required for parsing devcontainer.json"
        exit 1
    fi
    
    # Handle JSON with comments (jsonc) - strip // and /* */ comments
    local json
    json=$(sed 's|//.*$||g; s|/\*.*\*/||g' "${config_file}")
    
    # Image or Dockerfile
    DEVCONTAINER_IMAGE=$(echo "$json" | jq -r '.image // empty')
    DEVCONTAINER_DOCKERFILE=$(echo "$json" | jq -r '.build.dockerfile // .dockerFile // empty')
    DEVCONTAINER_CONTEXT=$(echo "$json" | jq -r '.build.context // .context // "."')
    
    # Build args as JSON object
    DEVCONTAINER_BUILD_ARGS=$(echo "$json" | jq -c '.build.args // {}')
    
    # Features as JSON object
    DEVCONTAINER_FEATURES=$(echo "$json" | jq -c '.features // {}')
    
    # Mounts - array of strings or objects
    DEVCONTAINER_MOUNTS=$(echo "$json" | jq -c '.mounts // []')
    
    # Environment
    DEVCONTAINER_CONTAINER_ENV=$(echo "$json" | jq -c '.containerEnv // {}')
    DEVCONTAINER_REMOTE_ENV=$(echo "$json" | jq -c '.remoteEnv // {}')
    
    # User
    DEVCONTAINER_REMOTE_USER=$(echo "$json" | jq -r '.remoteUser // empty')
    
    # Lifecycle commands - can be string, array, or object
    DEVCONTAINER_ON_CREATE_COMMAND=$(echo "$json" | jq -c '.onCreateCommand // empty')
    DEVCONTAINER_UPDATE_CONTENT_COMMAND=$(echo "$json" | jq -c '.updateContentCommand // empty')
    DEVCONTAINER_POST_CREATE_COMMAND=$(echo "$json" | jq -c '.postCreateCommand // empty')
    DEVCONTAINER_POST_START_COMMAND=$(echo "$json" | jq -c '.postStartCommand // empty')
    DEVCONTAINER_POST_ATTACH_COMMAND=$(echo "$json" | jq -c '.postAttachCommand // empty')
    
    # Ports
    DEVCONTAINER_FORWARD_PORTS=$(echo "$json" | jq -c '.forwardPorts // []')
    
    # Security
    DEVCONTAINER_PRIVILEGED=$(echo "$json" | jq -r '.privileged // false')
    DEVCONTAINER_CAP_ADD=$(echo "$json" | jq -c '.capAdd // []')
    DEVCONTAINER_SECURITY_OPT=$(echo "$json" | jq -c '.securityOpt // []')
    
    # Additional run args (escape hatch)
    DEVCONTAINER_RUN_ARGS=$(echo "$json" | jq -r '.runArgs // [] | join(" ")')
    
    log debug "parsed config: image=${DEVCONTAINER_IMAGE} dockerfile=${DEVCONTAINER_DOCKERFILE}"
}
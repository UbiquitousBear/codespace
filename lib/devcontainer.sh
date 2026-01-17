#!/bin/bash
# devcontainer.sh - Discover and parse devcontainer.json

# Parsed configuration - populated by parse_devcontainer_json
export DC_IMAGE=""
export DC_DOCKERFILE=""
export DC_CONTEXT=""
export DC_BUILD_ARGS="{}"
export DC_FEATURES="{}"
export DC_MOUNTS="[]"
export DC_CONTAINER_ENV="{}"
export DC_REMOTE_ENV="{}"
export DC_REMOTE_USER=""
export DC_ON_CREATE_COMMAND=""
export DC_UPDATE_CONTENT_COMMAND=""
export DC_POST_CREATE_COMMAND=""
export DC_POST_START_COMMAND=""
export DC_POST_ATTACH_COMMAND=""
export DC_FORWARD_PORTS="[]"
export DC_PRIVILEGED="false"
export DC_CAP_ADD="[]"
export DC_SECURITY_OPT="[]"
export DC_RUN_ARGS=""
export DC_INIT="true"
export DC_CONTAINER_USER=""

# Path to the devcontainer.json (or directory containing it)
export DC_CONFIG_DIR=""
export DC_CONFIG_FILE=""

discover_devcontainer() {
    local workspace="$1"

    log_info "discovering devcontainer configuration"

    # Priority order per spec:
    # 1. .devcontainer/devcontainer.json
    # 2. .devcontainer.json (at root)
    # 3. .devcontainer/<subdir>/devcontainer.json (if DEVCONTAINER_CONFIG set or only one)

    local paths=(
        ".devcontainer/devcontainer.json"
        ".devcontainer.json"
    )

    for p in "${paths[@]}"; do
        local full="${workspace}/${p}"
        if [[ -f "${full}" ]]; then
            DC_CONFIG_FILE="${full}"
            DC_CONFIG_DIR="$(dirname "${full}")"
            log_info "found: ${p}"
            parse_devcontainer_json "${DC_CONFIG_FILE}"
            return 0
        fi
    done

    # Check for subdirectory configs
    if [[ -d "${workspace}/.devcontainer" ]]; then
        local subdirs=()
        while IFS= read -r -d '' dir; do
            if [[ -f "${dir}/devcontainer.json" ]]; then
                subdirs+=("${dir}")
            fi
        done < <(find "${workspace}/.devcontainer" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

        # If DEVCONTAINER_CONFIG is set, use that specific one
        if [[ -n "${DEVCONTAINER_CONFIG:-}" ]]; then
            local specified="${workspace}/.devcontainer/${DEVCONTAINER_CONFIG}"
            if [[ -f "${specified}/devcontainer.json" ]]; then
                DC_CONFIG_DIR="${specified}"
                DC_CONFIG_FILE="${specified}/devcontainer.json"
                log_info "found (specified): ${DEVCONTAINER_CONFIG}/devcontainer.json"
                parse_devcontainer_json "${DC_CONFIG_FILE}"
                return 0
            fi
        fi

        # If only one subdir, use it
        if ((${#subdirs[@]} == 1)); then
            DC_CONFIG_DIR="${subdirs[0]}"
            DC_CONFIG_FILE="${subdirs[0]}/devcontainer.json"
            log_info "found: $(basename "${subdirs[0]}")/devcontainer.json"
            parse_devcontainer_json "${DC_CONFIG_FILE}"
            return 0
        elif ((${#subdirs[@]} > 1)); then
            log_warn "multiple devcontainer configs found:"
            for d in "${subdirs[@]}"; do
                log_warn "  - $(basename "${d}")"
            done
            log_warn "set DEVCONTAINER_CONFIG to choose, using first: $(basename "${subdirs[0]}")"
            DC_CONFIG_DIR="${subdirs[0]}"
            DC_CONFIG_FILE="${subdirs[0]}/devcontainer.json"
            parse_devcontainer_json "${DC_CONFIG_FILE}"
            return 0
        fi
    fi

    # No devcontainer config found - use defaults
    log_info "no devcontainer.json found, using universal defaults"
    use_universal_defaults
    return 0
}

parse_devcontainer_json() {
    local config_file="$1"

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for parsing devcontainer.json"
        exit 1
    fi

    log_debug "parsing ${config_file}"

    # Strip JSON comments (// and /* */) - devcontainer.json is JSONC
    local json
    json=$(sed -e 's|//.*$||g' -e 's|/\*.*\*/||g' "${config_file}" | tr '\n' ' ')

    # Image or build configuration
    DC_IMAGE=$(echo "$json" | jq -r '.image // empty')
    DC_DOCKERFILE=$(echo "$json" | jq -r '.build.dockerfile // .dockerFile // empty')
    DC_CONTEXT=$(echo "$json" | jq -r '.build.context // .context // "."')
    DC_BUILD_ARGS=$(echo "$json" | jq -c '.build.args // .buildArgs // {}')

    # Features
    DC_FEATURES=$(echo "$json" | jq -c '.features // {}')

    # Runtime configuration
    DC_MOUNTS=$(echo "$json" | jq -c '.mounts // []')
    DC_CONTAINER_ENV=$(echo "$json" | jq -c '.containerEnv // {}')
    DC_REMOTE_ENV=$(echo "$json" | jq -c '.remoteEnv // {}')
    DC_REMOTE_USER=$(echo "$json" | jq -r '.remoteUser // empty')
    DC_CONTAINER_USER=$(echo "$json" | jq -r '.containerUser // empty')

    # Lifecycle commands
    DC_ON_CREATE_COMMAND=$(echo "$json" | jq -c '.onCreateCommand // empty')
    DC_UPDATE_CONTENT_COMMAND=$(echo "$json" | jq -c '.updateContentCommand // empty')
    DC_POST_CREATE_COMMAND=$(echo "$json" | jq -c '.postCreateCommand // empty')
    DC_POST_START_COMMAND=$(echo "$json" | jq -c '.postStartCommand // empty')
    DC_POST_ATTACH_COMMAND=$(echo "$json" | jq -c '.postAttachCommand // empty')

    # Network
    DC_FORWARD_PORTS=$(echo "$json" | jq -c '.forwardPorts // []')

    # Security
    DC_PRIVILEGED=$(echo "$json" | jq -r '.privileged // false')
    DC_CAP_ADD=$(echo "$json" | jq -c '.capAdd // []')
    DC_SECURITY_OPT=$(echo "$json" | jq -c '.securityOpt // []')

    # Extra run args
    DC_RUN_ARGS=$(echo "$json" | jq -r '(.runArgs // []) | join(" ")')

    # Init process
    DC_INIT=$(echo "$json" | jq -r '.init // true')

    log_debug "image=${DC_IMAGE} dockerfile=${DC_DOCKERFILE} remoteUser=${DC_REMOTE_USER}"
}

use_universal_defaults() {
    DC_IMAGE="mcr.microsoft.com/devcontainers/base:ubuntu"
    DC_DOCKERFILE=""
    DC_CONTEXT="."
    DC_BUILD_ARGS="{}"
    DC_FEATURES="{}"
    DC_MOUNTS="[]"
    DC_CONTAINER_ENV="{}"
    DC_REMOTE_ENV="{}"
    DC_REMOTE_USER="codespace"
    DC_ON_CREATE_COMMAND=""
    DC_UPDATE_CONTENT_COMMAND=""
    DC_POST_CREATE_COMMAND=""
    DC_POST_START_COMMAND=""
    DC_POST_ATTACH_COMMAND=""
    DC_FORWARD_PORTS="[]"
    DC_PRIVILEGED="false"
    DC_CAP_ADD="[]"
    DC_SECURITY_OPT="[]"
    DC_RUN_ARGS=""
    DC_INIT="true"
    DC_CONFIG_DIR="${DEFAULTS_DIR}"
    DC_CONFIG_FILE=""
}

has_features() {
    [[ "${DC_FEATURES}" != "{}" && -n "${DC_FEATURES}" ]]
}
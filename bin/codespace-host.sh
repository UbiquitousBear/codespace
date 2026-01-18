#!/bin/bash
# codespace-host - Main entrypoint for dev container orchestration
# Builds and runs a dev container from the project's devcontainer.json,
# or falls back to a universal image if none exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
DEFAULTS_DIR="$(dirname "$SCRIPT_DIR")/defaults"

# Source libraries
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/git.sh"
source "${LIB_DIR}/devcontainer.sh"
source "${LIB_DIR}/build.sh"
source "${LIB_DIR}/container.sh"
source "${LIB_DIR}/hooks.sh"

# Globals set by config/discovery
REPO_URL=""
BRANCH=""
REPO_NAME=""
WORKDIR=""
CONTAINER_NAME=""
IMAGE_REF=""

main() {
    log_info "codespace-host starting"
    if [[ -n "${CODESPACE_HOST_VERSION:-}" ]]; then
        log_info "codespace-host version: ${CODESPACE_HOST_VERSION}"
    else
        log_info "codespace-host version: unknown"
    fi

    # 1. Read configuration from /run/config
    load_config

    # 2. Wait for Docker daemon
    wait_for_docker

    # 3. Clone or update repository
    setup_workspace

    # 4. Discover and parse devcontainer.json
    discover_devcontainer "${WORKDIR}"

    # 5. Build or pull the image
    IMAGE_REF=$(prepare_image "${WORKDIR}")
    log_info "image ready: ${IMAGE_REF}"

    # 6. Start the dev container
    CONTAINER_NAME="devcontainer-${WORKSPACE_ID}"
    start_devcontainer "${IMAGE_REF}" "${CONTAINER_NAME}" "${WORKDIR}"

    # 7. Fix workspace permissions inside the container
    fix_permissions_in_container "${CONTAINER_NAME}" "${WORKDIR}"

    # 8. Run lifecycle hooks
    run_lifecycle_hooks "${CONTAINER_NAME}"

    # 9. Start workspace services if entrypoint wasn't overridden
    if [[ "${CONTAINER_NEEDS_INIT_EXEC}" == "true" ]]; then
        start_workspace_init_exec "${CONTAINER_NAME}"
    fi

    log_info "codespace-host ready"

    # 9. Keep running and handle shutdown
    wait_for_shutdown "${CONTAINER_NAME}"
}

wait_for_docker() {
    log_info "waiting for Docker daemon"
    local attempts=0
    while ! docker info >/tmp/docker-info.log 2>&1; do
        ((attempts++))
        if ((attempts > 60)); then
            log_error "Docker daemon not available after 60 seconds"
            exit 1
        fi
        sleep 1
    done
    log_debug "Docker ready"
}

wait_for_shutdown() {
    local container="$1"

    trap 'shutdown "${container}"' TERM INT

    # Wait for container to exit
    docker wait "${container}" 2>/dev/null || true

    log_info "container exited"
}

shutdown() {
    local container="$1"
    log_info "shutting down"
    docker stop -t 10 "${container}" 2>/dev/null || true
    exit 0
}

main "$@"

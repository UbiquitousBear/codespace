#!/usr/bin/env bash
# bin/codespace-host

set -euo pipefail

CODESPACE_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "${CODESPACE_ROOT}/lib/config.sh"
source "${CODESPACE_ROOT}/lib/build.sh"
source "${CODESPACE_ROOT}/lib/features.sh"
source "${CODESPACE_ROOT}/lib/container.sh"
source "${CODESPACE_ROOT}/lib/hooks.sh"
source "${CODESPACE_ROOT}/lib/expose.sh"

# Configuration from environment (set by Coder/LinuxKit)
WORKSPACE_PATH="${WORKSPACE_PATH:-/workspace}"
WORKSPACE_NAME="${WORKSPACE_NAME:-workspace}"
CONTAINER_NAME="devcontainer-${WORKSPACE_NAME}"
REMOTE_USER="${REMOTE_USER:-}"
LOG_LEVEL="${LOG_LEVEL:-info}"

log() {
    local level="$1"; shift
    [[ "$LOG_LEVEL" == "debug" || "$level" != "debug" ]] && \
        echo "[$(date -Iseconds)] [$level] $*" >&2
}

main() {
    log info "codespace-host starting"
    log info "workspace: ${WORKSPACE_PATH}"

    # Wait for docker
    wait_for_docker

    # 1. Discover devcontainer configuration
    log info "discovering devcontainer config"
    local config_dir config_file
    if ! config_dir=$(discover_config_dir "${WORKSPACE_PATH}"); then
        log info "no devcontainer config found, using universal"
        config_dir="${CODESPACE_ROOT}/defaults/universal"
    fi
    config_file="${config_dir}/devcontainer.json"
    log info "using config: ${config_file}"

    # 2. Parse configuration
    parse_config "${config_file}"

    # 3. Build or pull image
    log info "preparing image"
    local image_ref
    image_ref=$(prepare_image "${config_dir}")
    log info "image ready: ${image_ref}"

    # 4. Apply features (if any)
    if [[ -n "${DEVCONTAINER_FEATURES:-}" ]]; then
        log info "applying features"
        image_ref=$(apply_features "${image_ref}")
    fi

    # 5. Start the container
    log info "starting container"
    start_container "${image_ref}" "${CONTAINER_NAME}"

    # 6. Run lifecycle hooks
    run_hooks "${CONTAINER_NAME}"

    # 7. Start exposure services
    log info "starting services"
    start_ssh_proxy "${CONTAINER_NAME}" &
    start_port_watcher "${CONTAINER_NAME}" &

    # 8. Signal ready
    signal_ready

    log info "codespace-host ready"

    # Keep running - wait for container or signals
    wait_for_shutdown "${CONTAINER_NAME}"
}

wait_for_docker() {
    log debug "waiting for docker daemon"
    local attempts=0
    while ! docker info >/dev/null 2>&1; do
        ((attempts++))
        if ((attempts > 30)); then
            log error "docker daemon not available"
            exit 1
        fi
        sleep 1
    done
    log debug "docker ready"
}

signal_ready() {
    # Signal to Coder that workspace is ready
    # Could be a file touch, API call, or socket notification
    touch /run/codespace-ready
    
    # If Coder agent expects an API call
    if [[ -n "${CODER_AGENT_URL:-}" ]]; then
        curl -sf -X POST "${CODER_AGENT_URL}/ready" || true
    fi
}

wait_for_shutdown() {
    local container="$1"
    
    trap 'shutdown' TERM INT
    
    # Wait for container to exit or signal
    docker wait "${container}" 2>/dev/null || true
}

shutdown() {
    log info "shutting down"
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    exit 0
}

main "$@"
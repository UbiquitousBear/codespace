#!/bin/bash
# coder.sh - Setup and run Coder agent inside the dev container

CODER_BIN="${CODER_BIN:-/usr/local/bin/coder}"

setup_coder_agent() {
    local container="$1"

    log_info "setting up Coder agent"

    # Verify we have the coder binary on host
    if [[ ! -x "${CODER_BIN}" ]]; then
        log_error "coder binary not found at ${CODER_BIN}"
        log_error "the LinuxKit image must include the coder binary"
        exit 1
    fi

    # Verify we have a token
    if [[ -z "${CODER_AGENT_TOKEN:-}" ]]; then
        log_error "CODER_AGENT_TOKEN not set (missing /run/config/coder-token)"
        exit 1
    fi

    # Copy coder binary into container
    log_info "copying coder binary into container"
    if ! docker cp "${CODER_BIN}" "${container}:/usr/local/bin/coder"; then
        log_error "failed to copy coder binary into container"
        exit 1
    fi

    # Ensure it's executable
    docker exec "${container}" chmod +x /usr/local/bin/coder

    # Start the agent
    start_coder_agent "${container}"
}

start_coder_agent() {
    local container="$1"

    log_info "starting Coder agent inside container"

    # Determine which user to run the agent as
    # Priority: DC_REMOTE_USER > DC_CONTAINER_USER > default (codespace)
    local agent_user="${DC_REMOTE_USER:-${DC_CONTAINER_USER:-codespace}}"
    
    # Verify the user exists in the container
    if ! docker exec "${container}" id "${agent_user}" &>/dev/null; then
        log_warn "user '${agent_user}' not found in container, trying 'vscode'"
        agent_user="vscode"
        if ! docker exec "${container}" id "${agent_user}" &>/dev/null; then
            log_warn "user 'vscode' not found, falling back to root"
            agent_user="root"
        fi
    fi
    
    log_info "agent will run as user: ${agent_user}"

    # Build the agent startup script
    # This runs inside the container and:
    # 1. Sets up environment
    # 2. Starts the coder agent
    local agent_script='
set -e

# Read token from mounted config
CODER_AGENT_TOKEN="$(cat /run/config/coder-token 2>/dev/null || echo "")"
if [ -z "$CODER_AGENT_TOKEN" ]; then
    echo "[coder] ERROR: CODER_AGENT_TOKEN missing" >&2
    exit 1
fi
export CODER_AGENT_TOKEN

# Optional: GitHub token
if [ -f /run/config/github-token ]; then
    export GITHUB_TOKEN="$(cat /run/config/github-token)"
    export GH_ENTERPRISE_TOKEN="$GITHUB_TOKEN"
fi

# Coder agent URL (if not using default)
if [ -f /run/config/coder-url ]; then
    export CODER_AGENT_URL="$(cat /run/config/coder-url)"
fi

echo "[coder] Starting Coder agent..."
exec /usr/local/bin/coder agent
'

    # Run agent as the determined user
    if ! docker exec -d -u "${agent_user}" "${container}" /bin/sh -c "${agent_script}"; then
        log_error "failed to start Coder agent"
        exit 1
    fi

    log_info "Coder agent started as ${agent_user}"

    # Give it a moment to initialize
    sleep 2

    # Verify it's running
    if ! docker exec "${container}" pgrep -f "coder agent" >/dev/null 2>&1; then
        log_warn "Coder agent may not be running - check container logs"
        docker exec "${container}" ps aux 2>/dev/null | head -20 || true
    fi
}

# Restart the Coder agent (e.g., after rebuild)
restart_coder_agent() {
    local container="$1"

    log_info "restarting Coder agent"

    # Kill existing agent
    docker exec "${container}" pkill -f "coder agent" 2>/dev/null || true
    sleep 1

    # Start fresh (will determine user automatically)
    start_coder_agent "${container}"
}
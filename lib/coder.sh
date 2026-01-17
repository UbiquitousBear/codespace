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

    # Verify we have the url
    if [[ -z "${CODER_AGENT_URL:-}" ]]; then
        log_error "CODER_AGENT_URL not set (missing /run/config/coder-url)"
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
    CODER_AGENT_URL_FILE="$(cat /run/config/coder-url)"
    if [ -n "$CODER_AGENT_URL_FILE" ]; then
        export CODER_AGENT_URL="$CODER_AGENT_URL_FILE"
    fi
fi

# Start VS Code server (code-server) for Coder app
USER_NAME="$(id -un 2>/dev/null || echo "codespace")"
if [ -z "${HOME:-}" ]; then
    if [ -d "/home/${USER_NAME}" ]; then
        HOME="/home/${USER_NAME}"
    else
        HOME="/root"
    fi
fi
export HOME
export PATH="${HOME}/.local/bin:${PATH}"

VSCODE_PORT="${CODER_VSCODE_PORT:-13337}"
CODE_SERVER_BIN="${CODER_VSCODE_BIN:-}"

if [ -n "${CODE_SERVER_BIN}" ] && [ ! -x "${CODE_SERVER_BIN}" ]; then
    echo "[coder] WARN: CODER_VSCODE_BIN is not executable: ${CODE_SERVER_BIN}"
    CODE_SERVER_BIN=""
fi

if [ -z "${CODE_SERVER_BIN}" ]; then
    if command -v code-server >/dev/null 2>&1; then
        CODE_SERVER_BIN="$(command -v code-server)"
    elif [ -x "${HOME}/.local/bin/code-server" ]; then
        CODE_SERVER_BIN="${HOME}/.local/bin/code-server"
    fi
fi

if [ -n "${CODE_SERVER_BIN}" ]; then
    if pgrep -f "code-server.*${VSCODE_PORT}" >/dev/null 2>&1; then
        echo "[coder] code-server already running on port ${VSCODE_PORT}"
    else
        echo "[coder] Starting code-server on port ${VSCODE_PORT}..."
        "${CODE_SERVER_BIN}" \
            --bind-addr "127.0.0.1:${VSCODE_PORT}" \
            --auth none \
            --disable-telemetry \
            --disable-update-check \
            >/tmp/code-server.log 2>&1 &
    fi
else
    echo "[coder] WARN: code-server not found; ensure it is installed in the devcontainer image."
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

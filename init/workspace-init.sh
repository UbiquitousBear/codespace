#!/bin/sh
set -eu

if (set -o pipefail) 2>/dev/null; then
    set -o pipefail
fi

log() {
    echo "[devcontainer] $*"
}

log_stderr() {
    echo "[devcontainer] $*" >&2
}

LOCK_FILE="/tmp/workspace-init.lock"

process_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$1" >/dev/null 2>&1
        return $?
    fi
    ps aux 2>/dev/null | grep -v grep | grep -q "$1"
}

if [ -f "${LOCK_FILE}" ]; then
    if process_running "coder agent"; then
        log "Detected existing coder agent; refusing to start a second one."
        exit 0
    fi
    log "Stale lock file found; continuing startup."
fi

USER_NAME="$(id -un 2>/dev/null || echo "")"
if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ] || [ "${HOME}" = "/" ]; then
    if [ -n "${USER_NAME}" ] && [ -d "/home/${USER_NAME}" ]; then
        HOME="/home/${USER_NAME}"
    else
        HOME="/workspaces/.home"
    fi
fi
mkdir -p "${HOME}" 2>/dev/null || true
if [ ! -w "${HOME}" ]; then
    HOME="/tmp/dev-home"
    mkdir -p "${HOME}" 2>/dev/null || true
fi
export HOME
export PATH="${HOME}/.local/bin:${PATH}"

if [ -z "${CODER_AGENT_TOKEN:-}" ] && [ -f /run/config/coder-token ]; then
    CODER_AGENT_TOKEN="$(cat /run/config/coder-token)"
fi
if [ -z "${CODER_AGENT_URL:-}" ] && [ -f /run/config/coder-url ]; then
    CODER_AGENT_URL="$(cat /run/config/coder-url)"
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f /run/config/github-token ]; then
    GITHUB_TOKEN="$(cat /run/config/github-token)"
    GH_ENTERPRISE_TOKEN="${GITHUB_TOKEN}"
fi

if [ -z "${CODER_AGENT_TOKEN:-}" ]; then
    log "ERROR: CODER_AGENT_TOKEN missing; cannot start agent."
    exit 1
fi
if [ -z "${CODER_AGENT_URL:-}" ]; then
    log "ERROR: CODER_AGENT_URL missing; cannot start agent."
    exit 1
fi
export CODER_AGENT_TOKEN CODER_AGENT_URL GITHUB_TOKEN GH_ENTERPRISE_TOKEN

CODE_SERVER_PORT="${CODE_SERVER_PORT:-${CODER_VSCODE_PORT:-13337}}"
export CODE_SERVER_PORT
export CODER_VSCODE_PORT="${CODER_VSCODE_PORT:-${CODE_SERVER_PORT}}"

pick_install_dir() {
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        echo "/usr/local/bin"
        return 0
    fi
    if [ -n "${HOME:-}" ]; then
        mkdir -p "${HOME}/.local/bin" 2>/dev/null || true
        echo "${HOME}/.local/bin"
        return 0
    fi
    mkdir -p "/tmp/.local/bin" 2>/dev/null || true
    echo "/tmp/.local/bin"
}

ensure_coder() {
    if command -v coder >/dev/null 2>&1; then
        command -v coder
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "ERROR: curl is required to install coder."
        return 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        log "ERROR: tar is required to install coder."
        return 1
    fi

    install_dir="$(pick_install_dir)"
    version="${CODER_VERSION:-2.28.6}"
    tmp_dir="$(mktemp -d)"

    log_stderr "Installing coder ${version} into ${install_dir}"
    if ! curl -fsSL "https://github.com/coder/coder/releases/download/v${version}/coder_${version}_linux_amd64.tar.gz" \
        -o "${tmp_dir}/coder.tar.gz"; then
        log_stderr "ERROR: failed to download coder ${version}"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! tar -xzf "${tmp_dir}/coder.tar.gz" -C "${tmp_dir}"; then
        log_stderr "ERROR: failed to extract coder ${version}"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [ ! -d "${install_dir}" ]; then
        if ! mkdir -p "${install_dir}" 2>/dev/null; then
            log_stderr "ERROR: failed to create install dir ${install_dir}"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    if [ -f "${tmp_dir}/coder" ]; then
        mv "${tmp_dir}/coder" "${install_dir}/coder"
    else
        mv "${tmp_dir}/coder_${version}_linux_amd64/coder" "${install_dir}/coder"
    fi
    chmod +x "${install_dir}/coder"
    rm -rf "${tmp_dir}"

    echo "${install_dir}/coder"
}

ensure_code_server() {
    if [ -n "${CODER_VSCODE_BIN:-}" ]; then
        if [ -x "${CODER_VSCODE_BIN}" ]; then
            echo "${CODER_VSCODE_BIN}"
            return 0
        fi
        log_stderr "WARN: CODER_VSCODE_BIN is not executable: ${CODER_VSCODE_BIN}"
    fi

    if command -v code-server >/dev/null 2>&1; then
        command -v code-server
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_stderr "WARN: curl is required to install code-server."
        return 1
    fi

    install_prefix="/usr/local"
    if [ ! -w "/usr/local" ]; then
        install_prefix="${HOME}/.local"
    fi
    mkdir -p "${install_prefix}" 2>/dev/null || true

    if command -v bash >/dev/null 2>&1; then
        log_stderr "Installing code-server into ${install_prefix}"
        if ! curl -fsSL https://code-server.dev/install.sh | bash -s -- --method=standalone --prefix="${install_prefix}"; then
            log_stderr "WARN: failed to install code-server"
            return 1
        fi
    else
        log_stderr "WARN: bash is required to install code-server."
        return 1
    fi

    if [ -x "${install_prefix}/bin/code-server" ]; then
        echo "${install_prefix}/bin/code-server"
        return 0
    fi

    return 1
}

if process_running "coder agent"; then
    log "Coder agent already running; exiting."
    exit 0
fi

CODE_SERVER_BIN="$(ensure_code_server || true)"
if [ -n "${CODE_SERVER_BIN}" ]; then
    if process_running "code-server.*${CODE_SERVER_PORT}"; then
        log "code-server already running on port ${CODE_SERVER_PORT}"
    else
        log "Starting code-server on port ${CODE_SERVER_PORT}..."
        "${CODE_SERVER_BIN}" \
            --bind-addr "127.0.0.1:${CODE_SERVER_PORT}" \
            --auth none \
            --disable-telemetry \
            --disable-update-check \
            >/tmp/code-server.log 2>&1 &
    fi
else
    log_stderr "WARN: code-server not found; ensure it is installed in the devcontainer image."
fi

CODER_BIN="$(ensure_coder || true)"
if [ -z "${CODER_BIN}" ] || [ ! -x "${CODER_BIN}" ]; then
    log_stderr "ERROR: coder binary not available; cannot start agent."
    exit 1
fi

echo "$$" > "${LOCK_FILE}"
log "Starting coder agent..."
exec "${CODER_BIN}" agent

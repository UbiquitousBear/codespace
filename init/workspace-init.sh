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
home_invalid=0
case "${HOME:-}" in
    ""|"/"|"/workspaces"|"/workspaces/"*)
        home_invalid=1
        ;;
esac
if [ "${home_invalid}" -eq 1 ] || [ ! -d "${HOME}" ]; then
    if [ -n "${USER_NAME}" ] && [ -d "/home/${USER_NAME}" ]; then
        HOME="/home/${USER_NAME}"
    else
        HOME="/tmp/codespace-home"
    fi
fi
mkdir -p "${HOME}" 2>/dev/null || true
if [ ! -w "${HOME}" ]; then
    HOME="/tmp/dev-home"
    mkdir -p "${HOME}" 2>/dev/null || true
fi
export HOME
REMOTE_USER="${REMOTE_USER:-${USER:-codespace}}"
export USER="${REMOTE_USER}"
export LOGNAME="${REMOTE_USER}"
export USERNAME="${REMOTE_USER}"
if [ -z "${SHELL:-}" ]; then
    if [ -x "/bin/bash" ]; then
        SHELL="/bin/bash"
    else
        SHELL="/bin/sh"
    fi
fi
export SHELL

DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ -z "${PATH:-}" ]; then
    PATH="${DEFAULT_PATH}"
fi
case ":${PATH}:" in
    *:/usr/local/bin:*) ;;
    *) PATH="${DEFAULT_PATH}:${PATH}" ;;
esac
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

CODE_SERVER_PORT="${CODE_SERVER_PORT:-${CODER_VSCODE_PORT:-${PORT:-13337}}}"
PORT="${PORT:-${CODE_SERVER_PORT}}"
CODE_SERVER_PORT="${PORT}"
export CODE_SERVER_PORT
export PORT
export CODER_VSCODE_PORT="${CODER_VSCODE_PORT:-${CODE_SERVER_PORT}}"

CODE_SERVER_BIND_ADDR="${CODE_SERVER_BIND_ADDR:-}"
if [ -n "${CODE_SERVER_BIND_ADDR}" ]; then
    export CODE_SERVER_BIND_ADDR
fi

CODE_SERVER_LOG="${CODE_SERVER_LOG:-/dev/stdout}"
LOG_PATH="${LOG_PATH:-${CODE_SERVER_LOG}}"
PORT="${PORT:-${CODE_SERVER_PORT}}"
INSTALL_PREFIX="${INSTALL_PREFIX:-}"
if [ -z "${INSTALL_PREFIX}" ]; then
    if [ -w "/usr/local" ]; then
        INSTALL_PREFIX="/usr/local"
    else
        INSTALL_PREFIX="${HOME}/.local"
    fi
fi
APP_NAME="${APP_NAME:-code-server}"
ADDITIONAL_ARGS="${ADDITIONAL_ARGS:-}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-}"
EXTENSIONS="${EXTENSIONS:-}"
USE_CACHED="${USE_CACHED:-false}"
USE_CACHED_EXTENSIONS="${USE_CACHED_EXTENSIONS:-false}"
AUTO_INSTALL_EXTENSIONS="${AUTO_INSTALL_EXTENSIONS:-false}"
OFFLINE="${OFFLINE:-false}"
VERSION="${VERSION:-}"
CODER_SCRIPT_BIN_DIR="${CODER_SCRIPT_BIN_DIR:-}"
SETTINGS="${SETTINGS:-}"
MACHINE_SETTINGS="${MACHINE_SETTINGS:-}"

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

extension_arg() {
    if [ -n "${EXTENSIONS_DIR}" ]; then
        mkdir -p "${EXTENSIONS_DIR}" 2>/dev/null || true
        echo "--extensions-dir=${EXTENSIONS_DIR}"
        return 0
    fi
    echo ""
}

ensure_code_server_settings() {
    if [ ! -f "${HOME}/.local/share/code-server/User/settings.json" ]; then
        log "Creating code-server settings file..."
        mkdir -p "${HOME}/.local/share/code-server/User" 2>/dev/null || true
        if command -v jq >/dev/null 2>&1; then
            echo "${SETTINGS}" | jq '.' > "${HOME}/.local/share/code-server/User/settings.json"
        else
            echo "${SETTINGS}" > "${HOME}/.local/share/code-server/User/settings.json"
        fi
    fi

    log "Creating code-server machine settings file..."
    mkdir -p "${HOME}/.local/share/code-server/Machine" 2>/dev/null || true
    if command -v jq >/dev/null 2>&1; then
        echo "${MACHINE_SETTINGS}" | jq '.' > "${HOME}/.local/share/code-server/Machine/settings.json"
    else
        echo "${MACHINE_SETTINGS}" > "${HOME}/.local/share/code-server/Machine/settings.json"
    fi
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
    CODE_SERVER_PATH="${INSTALL_PREFIX}/bin/code-server"

    if ! command -v curl >/dev/null 2>&1; then
        log_stderr "WARN: curl is required to install code-server."
        return 1
    fi

    if [ "${OFFLINE}" = "true" ]; then
        if [ -x "${CODE_SERVER_PATH}" ]; then
            echo "${CODE_SERVER_PATH}"
            return 0
        fi
        log_stderr "ERROR: offline mode enabled but code-server not found at ${CODE_SERVER_PATH}"
        return 1
    fi

    if [ ! -x "${CODE_SERVER_PATH}" ] || [ "${USE_CACHED}" != "true" ]; then
        mkdir -p "${INSTALL_PREFIX}" 2>/dev/null || true
        if [ -n "${CODER_SCRIPT_BIN_DIR}" ] && [ -e "${CODER_SCRIPT_BIN_DIR}/code-server" ]; then
            rm -f "${CODER_SCRIPT_BIN_DIR}/code-server"
        fi

        if command -v bash >/dev/null 2>&1; then
            log_stderr "Installing code-server into ${INSTALL_PREFIX}"
            INSTALL_ARGS="--method=standalone --prefix=${INSTALL_PREFIX}"
            if [ -n "${VERSION}" ]; then
                INSTALL_ARGS="${INSTALL_ARGS} --version=${VERSION}"
            fi
            if ! curl -fsSL https://code-server.dev/install.sh | bash -s -- ${INSTALL_ARGS}; then
                log_stderr "WARN: failed to install code-server"
                return 1
            fi
        else
            log_stderr "WARN: bash is required to install code-server."
            return 1
        fi
    fi

    if [ -x "${CODE_SERVER_PATH}" ]; then
        if [ -n "${CODER_SCRIPT_BIN_DIR}" ] && [ ! -e "${CODER_SCRIPT_BIN_DIR}/code-server" ]; then
            ln -s "${CODE_SERVER_PATH}" "${CODER_SCRIPT_BIN_DIR}/code-server" 2>/dev/null || true
        fi
        echo "${CODE_SERVER_PATH}"
        return 0
    fi

    if [ -n "${CODER_VSCODE_BIN:-}" ] && [ -x "${CODER_VSCODE_BIN}" ]; then
        echo "${CODER_VSCODE_BIN}"
        return 0
    fi

    if command -v code-server >/dev/null 2>&1; then
        command -v code-server
        return 0
    fi

    return 1
}

code_server_extension_installed() {
    _extension="$1"
    if [ "${USE_CACHED_EXTENSIONS}" != "true" ]; then
        return 1
    fi
    printf "%s\n" "${INSTALLED_EXTENSIONS}" | grep -qx "${_extension}"
}

install_code_server_extensions() {
    EXT_ARG="$(extension_arg)"
    INSTALLED_EXTENSIONS="$("${CODE_SERVER_BIN}" --list-extensions ${EXT_ARG} 2>/dev/null || true)"

    IFS=','; set -- ${EXTENSIONS}; unset IFS
    for extension in "$@"; do
        if [ -z "${extension}" ]; then
            continue
        fi
        if code_server_extension_installed "${extension}"; then
            log "Extension already installed: ${extension}"
            continue
        fi
        log "Installing extension ${extension}..."
        if ! "${CODE_SERVER_BIN}" ${EXT_ARG} --force --install-extension "${extension}" >/dev/null 2>&1; then
            log_stderr "WARN: failed to install extension: ${extension}"
        fi
    done

    if [ "${AUTO_INSTALL_EXTENSIONS}" = "true" ]; then
        if ! command -v jq >/dev/null 2>&1; then
            log "jq is required to install extensions from a workspace file."
            return 0
        fi

        WORKSPACE_DIR="${HOME}"
        if [ -n "${FOLDER:-}" ]; then
            WORKSPACE_DIR="${FOLDER}"
        fi
        if [ -f "${WORKSPACE_DIR}/.vscode/extensions.json" ]; then
            log "Installing extensions from ${WORKSPACE_DIR}/.vscode/extensions.json..."
            extensions="$(sed 's|//.*||g' "${WORKSPACE_DIR}/.vscode/extensions.json" | jq -r '.recommendations[]' 2>/dev/null || true)"
            for extension in ${extensions}; do
                if code_server_extension_installed "${extension}"; then
                    continue
                fi
                "${CODE_SERVER_BIN}" ${EXT_ARG} --force --install-extension "${extension}" >/dev/null 2>&1 || true
            done
        fi
    fi
}

start_code_server_bg() {
    (
        log "Ensuring code-server is installed..."
        if ! CODE_SERVER_BIN="$(ensure_code_server)"; then
            log_stderr "WARN: code-server install failed; not starting."
            exit 0
        fi
        ensure_code_server_settings
        install_code_server_extensions
        if [ -z "${CODE_SERVER_BIN}" ] || [ ! -x "${CODE_SERVER_BIN}" ]; then
            log_stderr "WARN: code-server not found; ensure it is installed in the devcontainer image."
            exit 0
        fi
        if process_running "code-server.*${CODE_SERVER_PORT}"; then
            log "code-server already running on port ${CODE_SERVER_PORT}"
            exit 0
        fi
        if [ -n "${CODE_SERVER_BIND_ADDR}" ]; then
            log "Starting code-server on ${CODE_SERVER_BIND_ADDR}..."
        else
            log "Starting code-server on port ${PORT}..."
        fi
        if [ -n "${CODE_SERVER_BIND_ADDR}" ]; then
            "${CODE_SERVER_BIN}" \
                $(extension_arg) \
                --auth none \
                --bind-addr "${CODE_SERVER_BIND_ADDR}" \
                --app-name "${APP_NAME}" \
                ${ADDITIONAL_ARGS} \
                >>"${LOG_PATH}" 2>&1 &
        else
            "${CODE_SERVER_BIN}" \
                $(extension_arg) \
                --auth none \
                --port "${PORT}" \
                --app-name "${APP_NAME}" \
                ${ADDITIONAL_ARGS} \
                >>"${LOG_PATH}" 2>&1 &
        fi
        sleep 1
        if process_running "code-server.*${CODE_SERVER_PORT}"; then
            log "code-server started"
        else
            log_stderr "WARN: code-server failed to start; check logs."
        fi
    ) >>"${LOG_PATH}" 2>&1 &
}

if process_running "coder agent"; then
    log "Coder agent already running; exiting."
    exit 0
fi

start_code_server_bg

CODER_BIN="$(ensure_coder || true)"
if [ -z "${CODER_BIN}" ] || [ ! -x "${CODER_BIN}" ]; then
    log_stderr "ERROR: coder binary not available; cannot start agent."
    exit 1
fi

echo "$$" > "${LOCK_FILE}"
log "Starting coder agent..."
exec "${CODER_BIN}" agent

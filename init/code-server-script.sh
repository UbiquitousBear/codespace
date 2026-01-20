#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[code-server] $*"
}

EXTENSIONS="${EXTENSIONS:-}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-}"
SETTINGS="${SETTINGS:-}"
MACHINE_SETTINGS="${MACHINE_SETTINGS:-}"
OFFLINE="${OFFLINE:-false}"
USE_CACHED="${USE_CACHED:-false}"
USE_CACHED_EXTENSIONS="${USE_CACHED_EXTENSIONS:-false}"
AUTO_INSTALL_EXTENSIONS="${AUTO_INSTALL_EXTENSIONS:-false}"
FOLDER="${FOLDER:-}"
VERSION="${VERSION:-}"
INSTALL_PREFIX="${INSTALL_PREFIX:-}"
LOG_PATH="${LOG_PATH:-/tmp/code-server.log}"
APP_NAME="${APP_NAME:-code-server}"
PORT="${PORT:-13337}"
ADDITIONAL_ARGS="${ADDITIONAL_ARGS:-}"
CODER_SCRIPT_BIN_DIR="${CODER_SCRIPT_BIN_DIR:-}"
CODE_SERVER_BIND_ADDR="${CODE_SERVER_BIND_ADDR:-}"

if [ -z "${INSTALL_PREFIX}" ]; then
    if [ -d "/vscode" ] && [ -w "/vscode" ]; then
        INSTALL_PREFIX="/vscode"
    elif [ -w "/usr/local" ]; then
        INSTALL_PREFIX="/usr/local"
    else
        INSTALL_PREFIX="${HOME}/.local"
    fi
fi

CODE_SERVER="${INSTALL_PREFIX}/bin/code-server"
EXTENSION_ARG=""
if [ -n "${EXTENSIONS_DIR}" ]; then
    EXTENSION_ARG="--extensions-dir=${EXTENSIONS_DIR}"
    mkdir -p "${EXTENSIONS_DIR}"
fi

if [ -n "${LOG_PATH}" ]; then
    mkdir -p "$(dirname "${LOG_PATH}")" 2>/dev/null || true
fi

run_code_server() {
    log "Starting code-server..."
    if [ -n "${CODE_SERVER_BIND_ADDR}" ]; then
        "${CODE_SERVER}" ${EXTENSION_ARG} --auth none --bind-addr "${CODE_SERVER_BIND_ADDR}" \
            --app-name "${APP_NAME}" ${ADDITIONAL_ARGS} >"${LOG_PATH}" 2>&1 &
    else
        "${CODE_SERVER}" ${EXTENSION_ARG} --auth none --port "${PORT}" \
            --app-name "${APP_NAME}" ${ADDITIONAL_ARGS} >"${LOG_PATH}" 2>&1 &
    fi
}

if [ ! -f "${HOME}/.local/share/code-server/User/settings.json" ]; then
    log "Creating code-server settings file..."
    mkdir -p "${HOME}/.local/share/code-server/User"
    if command -v jq >/dev/null 2>&1; then
        echo "${SETTINGS}" | jq '.' > "${HOME}/.local/share/code-server/User/settings.json"
    else
        echo "${SETTINGS}" > "${HOME}/.local/share/code-server/User/settings.json"
    fi
fi

log "Creating code-server machine settings file..."
mkdir -p "${HOME}/.local/share/code-server/Machine"
if command -v jq >/dev/null 2>&1; then
    echo "${MACHINE_SETTINGS}" | jq '.' > "${HOME}/.local/share/code-server/Machine/settings.json"
else
    echo "${MACHINE_SETTINGS}" > "${HOME}/.local/share/code-server/Machine/settings.json"
fi

if [ "${OFFLINE}" = true ]; then
    if [ -x "${CODE_SERVER}" ]; then
        log "Using offline code-server at ${CODE_SERVER}"
        run_code_server
        exit 0
    fi
    log "ERROR: offline mode enabled but ${CODE_SERVER} not found"
    exit 1
fi

if [ ! -x "${CODE_SERVER}" ] || [ "${USE_CACHED}" != true ]; then
    if [ -n "${CODER_SCRIPT_BIN_DIR}" ] && [ -e "${CODER_SCRIPT_BIN_DIR}/code-server" ]; then
        rm -f "${CODER_SCRIPT_BIN_DIR}/code-server"
    fi

    install_args=("--method=standalone" "--prefix=${INSTALL_PREFIX}")
    if [ -n "${VERSION}" ]; then
        install_args+=("--version=${VERSION}")
    fi

    log "Installing code-server into ${INSTALL_PREFIX}..."
    installer="sh"
    if command -v bash >/dev/null 2>&1; then
        installer="bash"
    fi
    if ! curl -fsSL https://code-server.dev/install.sh | "${installer}" -s -- "${install_args[@]}"; then
        log "ERROR: failed to install code-server"
        exit 1
    fi
    log "code-server installed in ${INSTALL_PREFIX}"
fi

if [ -n "${CODER_SCRIPT_BIN_DIR}" ] && [ ! -e "${CODER_SCRIPT_BIN_DIR}/code-server" ]; then
    ln -s "${CODE_SERVER}" "${CODER_SCRIPT_BIN_DIR}/code-server" 2>/dev/null || true
fi

LIST_EXTENSIONS="$("${CODE_SERVER}" --list-extensions ${EXTENSION_ARG} 2>/dev/null || true)"
readarray -t EXTENSIONS_ARRAY <<< "${LIST_EXTENSIONS}"
extension_installed() {
    if [ "${USE_CACHED_EXTENSIONS}" != true ]; then
        return 1
    fi
    for _extension in "${EXTENSIONS_ARRAY[@]}"; do
        if [ "${_extension}" == "$1" ]; then
            log "Extension already installed: $1"
            return 0
        fi
    done
    return 1
}

IFS=',' read -r -a EXTENSIONLIST <<< "${EXTENSIONS}"
for extension in "${EXTENSIONLIST[@]}"; do
    if [ -z "${extension}" ]; then
        continue
    fi
    if extension_installed "${extension}"; then
        continue
    fi
    log "Installing extension ${extension}..."
    if ! "${CODE_SERVER}" ${EXTENSION_ARG} --force --install-extension "${extension}" >/dev/null 2>&1; then
        log "WARN: failed to install extension ${extension}"
    fi
done

if [ "${AUTO_INSTALL_EXTENSIONS}" = true ]; then
    if ! command -v jq >/dev/null 2>&1; then
        log "jq is required to install extensions from a workspace file."
    else
        WORKSPACE_DIR="${HOME}"
        if [ -n "${FOLDER}" ]; then
            WORKSPACE_DIR="${FOLDER}"
        fi
        if [ -f "${WORKSPACE_DIR}/.vscode/extensions.json" ]; then
            log "Installing extensions from ${WORKSPACE_DIR}/.vscode/extensions.json..."
            extensions="$(sed 's|//.*||g' "${WORKSPACE_DIR}/.vscode/extensions.json" | jq -r '.recommendations[]' 2>/dev/null || true)"
            for extension in ${extensions}; do
                if extension_installed "${extension}"; then
                    continue
                fi
                "${CODE_SERVER}" ${EXTENSION_ARG} --force --install-extension "${extension}" >/dev/null 2>&1 || true
            done
        fi
    fi
fi

run_code_server

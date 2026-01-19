#!/bin/bash
# config.sh - Load configuration from /run/config

CONFIG_DIR="${CONFIG_DIR:-/run/config}"

# Exported for use in other scripts
export REPO_URL=""
export BRANCH=""
export GIT_NAME=""
export GIT_EMAIL=""
export WORKSPACE_ID=""
export GIT_USERNAME=""
export GIT_TOKEN=""
export CODER_AGENT_TOKEN=""
export CODER_AGENT_URL=""
export GITHUB_TOKEN=""
export GH_ENTERPRISE_TOKEN=""
export PORT=""
export APP_NAME=""
export LOG_PATH=""
export INSTALL_PREFIX=""
export VERSION=""
export EXTENSIONS=""
export SETTINGS=""
export MACHINE_SETTINGS=""
export FOLDER=""
export OFFLINE=""
export USE_CACHED=""
export USE_CACHED_EXTENSIONS=""
export EXTENSIONS_DIR=""
export AUTO_INSTALL_EXTENSIONS=""
export ADDITIONAL_ARGS=""
export CODER_SCRIPT_BIN_DIR=""
export CODE_SERVER_LOG=""
export CODE_SERVER_BIND_ADDR=""

read_config_file() {
    local name="$1"
    local default="${2:-}"
    local file="${CONFIG_DIR}/${name}"

    if [[ -f "${file}" ]]; then
        cat "${file}"
    else
        echo "${default}"
    fi
}

load_config() {
    log_info "loading configuration from ${CONFIG_DIR}"

    # Required
    REPO_URL="$(read_config_file "repo-url")"
    if [[ -z "${REPO_URL}" ]]; then
        log_error "repo-url not found in ${CONFIG_DIR}"
        exit 1
    fi

    # Optional with defaults
    BRANCH="$(read_config_file "branch" "main")"
    GIT_NAME="$(read_config_file "git-name" "Coder User")"
    GIT_EMAIL="$(read_config_file "git-email" "coder@example.com")"

    # Tokens
    GIT_USERNAME="$(read_config_file "git-username" "")"
    GIT_TOKEN="$(read_config_file "git-token" "")"
    CODER_AGENT_TOKEN="$(read_config_file "coder-token")"
    CODER_AGENT_URL="$(read_config_file "coder-url")"
    GITHUB_TOKEN="$(read_config_file "github-token")"
    GH_ENTERPRISE_TOKEN="${GITHUB_TOKEN}"

    # Optional code-server settings (mirrors coder/registry module vars)
    PORT="$(read_config_file "code-server-port" "")"
    APP_NAME="$(read_config_file "code-server-app-name" "")"
    LOG_PATH="$(read_config_file "code-server-log-path" "")"
    INSTALL_PREFIX="$(read_config_file "code-server-install-prefix" "")"
    VERSION="$(read_config_file "code-server-version" "")"
    EXTENSIONS="$(read_config_file "code-server-extensions" "")"
    SETTINGS="$(read_config_file "code-server-settings" "")"
    MACHINE_SETTINGS="$(read_config_file "code-server-machine-settings" "")"
    FOLDER="$(read_config_file "code-server-folder" "")"
    OFFLINE="$(read_config_file "code-server-offline" "")"
    USE_CACHED="$(read_config_file "code-server-use-cached" "")"
    USE_CACHED_EXTENSIONS="$(read_config_file "code-server-use-cached-extensions" "")"
    EXTENSIONS_DIR="$(read_config_file "code-server-extensions-dir" "")"
    AUTO_INSTALL_EXTENSIONS="$(read_config_file "code-server-auto-install-extensions" "")"
    ADDITIONAL_ARGS="$(read_config_file "code-server-additional-args" "")"
    CODER_SCRIPT_BIN_DIR="$(read_config_file "code-server-script-bin-dir" "")"
    CODE_SERVER_LOG="$(read_config_file "code-server-log" "")"
    CODE_SERVER_BIND_ADDR="$(read_config_file "code-server-bind-addr" "")"

    if [[ -n "${EXTENSIONS}" ]]; then
        EXTENSIONS="$(printf '%s' "${EXTENSIONS}" | tr '\n' ',' | tr -d ' ')"
    fi

    # Derived values
    REPO_NAME="${REPO_URL%.git}"
    REPO_NAME="${REPO_NAME##*/}"
    WORKDIR="/workspaces/${REPO_NAME}"
    WORKSPACE_ID="$(read_config_file "workspace-id" "")"
    if [[ -z "${WORKSPACE_ID}" ]]; then
        WORKSPACE_ID="${REPO_NAME}"
    fi

    # Export for child processes
    export REPO_URL BRANCH GIT_NAME GIT_EMAIL GIT_USERNAME GIT_TOKEN
    export CODER_AGENT_TOKEN CODER_AGENT_URL GITHUB_TOKEN GH_ENTERPRISE_TOKEN
    export REPO_NAME WORKDIR WORKSPACE_ID
    export PORT APP_NAME LOG_PATH INSTALL_PREFIX VERSION EXTENSIONS SETTINGS
    export MACHINE_SETTINGS FOLDER OFFLINE USE_CACHED USE_CACHED_EXTENSIONS
    export EXTENSIONS_DIR AUTO_INSTALL_EXTENSIONS ADDITIONAL_ARGS CODER_SCRIPT_BIN_DIR
    export CODE_SERVER_LOG CODE_SERVER_BIND_ADDR

    log_info "repo: ${REPO_URL}"
    log_info "branch: ${BRANCH}"
    log_info "workdir: ${WORKDIR}"
    log_info "workspace id: ${WORKSPACE_ID}"
}

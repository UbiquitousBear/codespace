#!/bin/bash
# config.sh - Load configuration from /run/config

CONFIG_DIR="${CONFIG_DIR:-/run/config}"

# Exported for use in other scripts
export REPO_URL=""
export BRANCH=""
export GIT_NAME=""
export GIT_EMAIL=""
export CODER_AGENT_TOKEN=""
export CODER_AGENT_URL=""
export GITHUB_TOKEN=""
export GH_ENTERPRISE_TOKEN=""

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
    CODER_AGENT_TOKEN="$(read_config_file "coder-token")"
    CODER_AGENT_URL="$(read_config_file "coder-url")"
    GITHUB_TOKEN="$(read_config_file "github-token")"
    GH_ENTERPRISE_TOKEN="${GITHUB_TOKEN}"

    # Derived values
    REPO_NAME="${REPO_URL%.git}"
    REPO_NAME="${REPO_NAME##*/}"
    WORKDIR="/workspaces/${REPO_NAME}"

    # Export for child processes
    export REPO_URL BRANCH GIT_NAME GIT_EMAIL
    export CODER_AGENT_TOKEN CODER_AGENT_URL GITHUB_TOKEN GH_ENTERPRISE_TOKEN
    export REPO_NAME WORKDIR

    log_info "repo: ${REPO_URL}"
    log_info "branch: ${BRANCH}"
    log_info "workdir: ${WORKDIR}"
}

#!/bin/bash
# git.sh - Git clone and update operations

setup_workspace() {
    log_info "setting up workspace"

    git config --global user.name "${GIT_NAME}"
    git config --global user.email "${GIT_EMAIL}"
    git config --global --add safe.directory "${WORKDIR}"

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git config --global credential.helper store
        cat > ~/.git-credentials <<EOF
https://oauth2:${GITHUB_TOKEN}@github.com
EOF
        chmod 600 ~/.git-credentials
    fi

    mkdir -p /workspaces

    if [[ ! -d "${WORKDIR}/.git" ]]; then
        log_info "cloning repository"
        clone_repo
    else
        log_info "repository already cloned"
    fi

    cd "${WORKDIR}"
    log_info "HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
}

clone_repo() {
    local clone_url="${REPO_URL}"
    local auth_header=""

    if [[ -n "${GITHUB_TOKEN:-}" && "${clone_url}" == *"github.com"* ]]; then
        if [[ "${clone_url}" == git@github.com:* ]]; then
            clone_url="https://github.com/${clone_url#git@github.com:}"
        fi
    fi

    if auth_header="$(build_auth_header)"; then
        clone_url="$(strip_userinfo "${clone_url}")"
        git -c "http.extraHeader=${auth_header}" clone --branch "${BRANCH}" "${clone_url}" "${WORKDIR}"
    else
        git clone --branch "${BRANCH}" "${clone_url}" "${WORKDIR}"
    fi
}

build_auth_header() {
    local user=""
    local token=""

    if [[ "${REPO_URL}" != http://* && "${REPO_URL}" != https://* ]]; then
        return 1
    fi

    if [[ -n "${GIT_TOKEN:-}" ]]; then
        user="${GIT_USERNAME:-oauth2}"
        token="${GIT_TOKEN}"
    elif extract_userinfo "${REPO_URL}"; then
        user="${EXTRACTED_GIT_USER}"
        token="${EXTRACTED_GIT_TOKEN}"
    else
        return 1
    fi

    local auth
    auth="$(printf '%s' "${user}:${token}" | base64 | tr -d '\n')"
    printf 'Authorization: Basic %s' "${auth}"
    return 0
}

strip_userinfo() {
    echo "$1" | sed -E 's#(https?://)[^/@]+@#\1#'
}

extract_userinfo() {
    # Exports EXTRACTED_GIT_USER and EXTRACTED_GIT_TOKEN
    local url="$1"
    local rest="${url#*://}"
    if [[ "${rest}" == "${url}" ]]; then
        return 1
    fi
    local userinfo="${rest%%@*}"
    if [[ "${userinfo}" == "${rest}" ]]; then
        return 1
    fi
    local user="${userinfo%%:*}"
    local token="${userinfo#*:}"
    if [[ -z "${user}" || -z "${token}" ]]; then
        return 1
    fi
    EXTRACTED_GIT_USER="$(url_decode "${user}")"
    EXTRACTED_GIT_TOKEN="$(url_decode "${token}")"
    export EXTRACTED_GIT_USER EXTRACTED_GIT_TOKEN
    return 0
}

url_decode() {
    printf '%b' "${1//%/\\x}"
}

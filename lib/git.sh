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
        log_info "updating existing repository"
        update_repo
    fi

    cd "${WORKDIR}"
    log_info "HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
}

clone_repo() {
    local clone_url="${REPO_URL}"

    if [[ -n "${GITHUB_TOKEN:-}" && "${clone_url}" == *"github.com"* ]]; then
        if [[ "${clone_url}" == git@github.com:* ]]; then
            clone_url="https://github.com/${clone_url#git@github.com:}"
        fi
    fi

    git clone --branch "${BRANCH}" "${clone_url}" "${WORKDIR}"
}

update_repo() {
    cd "${WORKDIR}"
    git fetch origin "${BRANCH}"
    git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" "origin/${BRANCH}"
    git reset --hard "origin/${BRANCH}"
}
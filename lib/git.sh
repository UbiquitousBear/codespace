#!/bin/bash
# git.sh - Git clone and update operations

setup_workspace() {
    log_info "setting up workspace"

    # Configure git identity
    git config --global user.name "${GIT_NAME}"
    git config --global user.email "${GIT_EMAIL}"
    
    # Disable filemode - virtiofs doesn't support chmod
    git config --global core.filemode false
    
    # Trust the workspace directory (git safe.directory)
    git config --global --add safe.directory "${WORKDIR}"

    # Configure credential helper if we have a GitHub token
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git config --global credential.helper store
        cat > ~/.git-credentials <<EOF
https://oauth2:${GITHUB_TOKEN}@github.com
EOF
        chmod 600 ~/.git-credentials 2>/dev/null || true
    fi

    # Ensure /workspaces exists
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

    # If it's a GitHub URL and we have a token, ensure HTTPS
    if [[ -n "${GITHUB_TOKEN:-}" && "${clone_url}" == *"github.com"* ]]; then
        # Convert SSH to HTTPS if needed
        if [[ "${clone_url}" == git@github.com:* ]]; then
            clone_url="https://github.com/${clone_url#git@github.com:}"
        fi
    fi

    # Clone to a temp directory first (avoids virtiofs chmod issues during clone)
    local temp_dir="/tmp/clone-$$"
    
    log_debug "cloning to temp directory first"
    if ! git clone --branch "${BRANCH}" --depth 1 "${clone_url}" "${temp_dir}"; then
        log_warn "shallow clone failed, trying full clone"
        rm -rf "${temp_dir}"
        if ! git clone --branch "${BRANCH}" "${clone_url}" "${temp_dir}"; then
            log_error "git clone failed"
            rm -rf "${temp_dir}"
            exit 1
        fi
    fi

    # Move to final destination
    log_debug "moving clone to workspace"
    rm -rf "${WORKDIR}"
    mv "${temp_dir}" "${WORKDIR}"
    
    # Ensure git config is set in the repo too
    git -C "${WORKDIR}" config core.filemode false
}

update_repo() {
    cd "${WORKDIR}"

    # Ensure filemode is disabled for this repo
    git config core.filemode false

    # Fetch and reset to origin
    git fetch origin "${BRANCH}" --depth 1 2>/dev/null || git fetch origin "${BRANCH}"
    git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" "origin/${BRANCH}"
    git reset --hard "origin/${BRANCH}"
}
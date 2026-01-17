#!/bin/bash
# build.sh - Build or pull the dev container image

prepare_image() {
    local workspace="$1"
    local image_ref=""

    if [[ -n "${DC_IMAGE}" ]]; then
        # Direct image reference
        image_ref="${DC_IMAGE}"
        pull_image "${image_ref}"

    elif [[ -n "${DC_DOCKERFILE}" ]]; then
        # Build from Dockerfile
        image_ref="devcontainer-${REPO_NAME}:latest"
        build_image "${image_ref}"

    else
        # Fallback to universal
        log_warn "no image or Dockerfile specified, using universal"
        image_ref="mcr.microsoft.com/devcontainers/universal:linux"
        pull_image "${image_ref}"
    fi

    # IMPORTANT: this is now the *only* thing that goes to stdout
    echo "${image_ref}"
}

pull_image() {
    local image="$1"

    log_info "pulling image: ${image}"

    # Send all docker pull output to stderr so it doesn't pollute $(prepare_image)
    if ! docker pull "${image}" >&2; then
        log_error "failed to pull image: ${image}"
        exit 1
    fi
}

build_image() {
    local tag="$1"

    # Resolve paths relative to config directory
    local dockerfile="${DC_CONFIG_DIR}/${DC_DOCKERFILE}"
    local context="${DC_CONFIG_DIR}/${DC_CONTEXT}"

    # Context might reference parent directory (common pattern)
    if [[ "${DC_CONTEXT}" == ".." || "${DC_CONTEXT}" == "../"* ]]; then
        context="$(cd "${DC_CONFIG_DIR}" && cd "${DC_CONTEXT}" && pwd)"
    fi

    # Dockerfile might be relative to context instead of config dir
    if [[ ! -f "${dockerfile}" && -f "${context}/${DC_DOCKERFILE}" ]]; then
        dockerfile="${context}/${DC_DOCKERFILE}"
    fi

    log_info "building image: ${tag}"
    log_debug "dockerfile: ${dockerfile}"
    log_debug "context: ${context}"

    local build_args=()

    # Parse build args from JSON
    if [[ "${DC_BUILD_ARGS}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            value=$(expand_build_arg "${value}")
            build_args+=(--build-arg "${key}=${value}")
        done < <(echo "${DC_BUILD_ARGS}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi

    # Enable BuildKit caching
    export DOCKER_BUILDKIT=1
    build_args+=(--build-arg "BUILDKIT_INLINE_CACHE=1")

    # Send all docker build output to stderr as well
    if ! docker build \
        -t "${tag}" \
        -f "${dockerfile}" \
        "${build_args[@]}" \
        "${context}" >&2; then

        log_error "docker build failed"

        # Fallback to universal; only this echo goes to stdout
        log_warn "falling back to universal image"
        echo "mcr.microsoft.com/devcontainers/universal:2"
        return 0
    fi

    # Only the final tag on stdout
    echo "${tag}"
}

expand_build_arg() {
    local value="$1"

    # Common variables used in devcontainer build args
    value="${value//\$\{localWorkspaceFolder\}/${WORKDIR}}"
    value="${value//\$\{localWorkspaceFolderBasename\}/${REPO_NAME}}"
    value="${value//\$\{localEnv:USER\}/${USER:-root}}"
    value="${value//\$\{localEnv:HOME\}/${HOME:-/root}}"

    echo "${value}"
}
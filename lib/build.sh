#!/usr/bin/env bash
# lib/build.sh

prepare_image() {
    local config_dir="$1"
    local image_ref=""
    
    if [[ -n "${DEVCONTAINER_IMAGE}" ]]; then
        # Direct image reference - pull it
        image_ref="${DEVCONTAINER_IMAGE}"
        log info "pulling image: ${image_ref}"
        docker pull "${image_ref}"
        
    elif [[ -n "${DEVCONTAINER_DOCKERFILE}" ]]; then
        # Build from Dockerfile
        image_ref="devcontainer-${WORKSPACE_NAME}:latest"
        build_from_dockerfile "${config_dir}" "${image_ref}"
        
    else
        log error "no image or Dockerfile specified in devcontainer.json"
        exit 1
    fi
    
    echo "${image_ref}"
}

build_from_dockerfile() {
    local config_dir="$1"
    local image_tag="$2"
    
    local dockerfile="${config_dir}/${DEVCONTAINER_DOCKERFILE}"
    local context="${config_dir}/${DEVCONTAINER_CONTEXT}"
    
    # Resolve context - could be relative to workspace
    if [[ "${DEVCONTAINER_CONTEXT}" == ".." || "${DEVCONTAINER_CONTEXT}" == "../"* ]]; then
        context="${WORKSPACE_PATH}/${DEVCONTAINER_CONTEXT#../}"
    fi
    
    log info "building image from ${dockerfile}"
    log debug "context: ${context}"
    
    local build_args=()
    
    # Parse build args from JSON
    if [[ "${DEVCONTAINER_BUILD_ARGS}" != "{}" ]]; then
        while IFS='=' read -r key value; do
            build_args+=(--build-arg "${key}=${value}")
        done < <(echo "${DEVCONTAINER_BUILD_ARGS}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    # Standard build args that devcontainer spec suggests
    build_args+=(--build-arg "BUILDKIT_INLINE_CACHE=1")
    
    docker build \
        -t "${image_tag}" \
        -f "${dockerfile}" \
        "${build_args[@]}" \
        "${context}"
}
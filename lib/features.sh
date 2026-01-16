#!/usr/bin/env bash
# lib/features.sh

# Dev container features are OCI artifacts that add tooling
# See: https://containers.dev/implementors/features/

apply_features() {
    local base_image="$1"
    
    if [[ "${DEVCONTAINER_FEATURES}" == "{}" || -z "${DEVCONTAINER_FEATURES}" ]]; then
        echo "${base_image}"
        return
    fi
    
    local featured_image="devcontainer-${WORKSPACE_NAME}-featured:latest"
    local build_dir
    build_dir=$(mktemp -d)
    trap "rm -rf ${build_dir}" RETURN
    
    # Start Dockerfile
    cat > "${build_dir}/Dockerfile" <<EOF
FROM ${base_image}
EOF
    
    # Process each feature
    local feature_id feature_options
    while IFS='=' read -r feature_id feature_options; do
        log info "applying feature: ${feature_id}"
        install_feature "${feature_id}" "${feature_options}" "${build_dir}"
    done < <(echo "${DEVCONTAINER_FEATURES}" | jq -r 'to_entries[] | "\(.key)=\(.value | @json)"')
    
    # Build the featured image
    docker build -t "${featured_image}" "${build_dir}"
    
    echo "${featured_image}"
}

install_feature() {
    local feature_id="$1"
    local options="$2"
    local build_dir="$3"
    
    # Feature ID formats:
    # - ghcr.io/devcontainers/features/node:1
    # - ./local-feature
    # - ghcr.io/owner/repo/feature:version
    
    local feature_dir="${build_dir}/features/$(echo "${feature_id}" | tr '/:' '_')"
    mkdir -p "${feature_dir}"
    
    if [[ "${feature_id}" == "./"* ]]; then
        # Local feature
        cp -r "${WORKSPACE_PATH}/${feature_id#./}"/* "${feature_dir}/"
    else
        # OCI feature - pull and extract
        pull_oci_feature "${feature_id}" "${feature_dir}"
    fi
    
    # Parse options and generate env vars
    local env_vars=""
    if [[ "${options}" != "{}" && "${options}" != "null" ]]; then
        while IFS='=' read -r key value; do
            local env_name
            env_name=$(echo "${key}" | tr '[:lower:]' '[:upper:]')
            env_vars+="ENV ${env_name}=${value}"$'\n'
        done < <(echo "${options}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    # Add to Dockerfile
    local feature_name
    feature_name=$(basename "${feature_dir}")
    cat >> "${build_dir}/Dockerfile" <<EOF

# Feature: ${feature_id}
${env_vars}
COPY features/${feature_name} /tmp/feature-${feature_name}
RUN cd /tmp/feature-${feature_name} && \\
    chmod +x install.sh && \\
    ./install.sh && \\
    rm -rf /tmp/feature-${feature_name}
EOF
}

pull_oci_feature() {
    local feature_ref="$1"
    local dest_dir="$2"
    
    # Features are OCI artifacts - use crane or oras to pull
    # Fallback to docker if those aren't available
    
    if command -v crane &>/dev/null; then
        local tarball="${dest_dir}/feature.tar.gz"
        crane pull "${feature_ref}" "${tarball}"
        tar -xzf "${tarball}" -C "${dest_dir}"
        rm -f "${tarball}"
        
    elif command -v oras &>/dev/null; then
        oras pull "${feature_ref}" -o "${dest_dir}"
        
    else
        # Fallback: try to docker pull and extract
        # This is hacky but works for testing
        log warn "crane/oras not found, attempting docker fallback"
        local temp_container
        temp_container=$(docker create "${feature_ref}" /bin/true 2>/dev/null || echo "")
        if [[ -n "${temp_container}" ]]; then
            docker cp "${temp_container}:/" "${dest_dir}/"
            docker rm "${temp_container}" >/dev/null
        else
            log error "failed to pull feature: ${feature_ref}"
            return 1
        fi
    fi
}
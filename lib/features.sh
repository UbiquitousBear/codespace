#!/bin/bash
# features.sh - Install dev container features
#
# Dev container features are OCI artifacts that add tooling to images.
# See: https://containers.dev/implementors/features/

FEATURES_CACHE_DIR="${FEATURES_CACHE_DIR:-/tmp/devcontainer-features}"

apply_features() {
    local base_image="$1"

    if [[ "${DC_FEATURES}" == "{}" || -z "${DC_FEATURES}" ]]; then
        echo "${base_image}"
        return
    fi

    log_info "applying dev container features"

    local featured_tag="devcontainer-${REPO_NAME}-featured:latest"
    local build_dir
    build_dir=$(mktemp -d)

    # Start Dockerfile from base image
    cat > "${build_dir}/Dockerfile" <<EOF
FROM ${base_image}
EOF

    mkdir -p "${build_dir}/features"

    # Process each feature
    local feature_count=0
    while IFS='=' read -r feature_id feature_options; do
        log_info "  feature: ${feature_id}"
        if install_feature "${feature_id}" "${feature_options}" "${build_dir}"; then
            ((feature_count++))
        fi
    done < <(echo "${DC_FEATURES}" | jq -r 'to_entries[] | "\(.key)=\(.value | @json)"')

    if ((feature_count == 0)); then
        log_warn "no features were installed"
        rm -rf "${build_dir}"
        echo "${base_image}"
        return
    fi

    # Build the featured image
    log_info "building featured image"
    if docker build -t "${featured_tag}" "${build_dir}" >/dev/null; then
        rm -rf "${build_dir}"
        echo "${featured_tag}"
    else
        log_error "failed to build featured image"
        rm -rf "${build_dir}"
        echo "${base_image}"
    fi
}

install_feature() {
    local feature_id="$1"
    local options="$2"
    local build_dir="$3"

    # Feature ID formats:
    # - ghcr.io/devcontainers/features/node:1
    # - ghcr.io/owner/repo/feature:version
    # - ./local-feature (relative to .devcontainer)

    local feature_name
    feature_name=$(echo "${feature_id}" | tr '/:@' '___')
    local feature_dir="${build_dir}/features/${feature_name}"
    mkdir -p "${feature_dir}"

    if [[ "${feature_id}" == "./"* ]]; then
        # Local feature - copy from workspace
        local local_path="${DC_CONFIG_DIR}/${feature_id#./}"
        if [[ -d "${local_path}" ]]; then
            cp -r "${local_path}"/* "${feature_dir}/"
        else
            log_warn "local feature not found: ${local_path}"
            return 1
        fi
    else
        # OCI feature - pull and extract
        if ! pull_oci_feature "${feature_id}" "${feature_dir}"; then
            log_warn "failed to pull feature: ${feature_id}"
            return 1
        fi
    fi

    # Check for install.sh
    if [[ ! -f "${feature_dir}/install.sh" ]]; then
        log_warn "feature missing install.sh: ${feature_id}"
        return 1
    fi

    # Parse options and generate environment variables
    local env_lines=""
    if [[ "${options}" != "{}" && "${options}" != "null" && "${options}" != "true" ]]; then
        while IFS='=' read -r key value; do
            # Feature options become environment variables with uppercase names
            local env_name
            env_name=$(echo "${key}" | tr '[:lower:]-' '[:upper:]_')
            env_lines+="ENV ${env_name}=\"${value}\""$'\n'
        done < <(echo "${options}" | jq -r 'if type == "object" then to_entries[] | "\(.key)=\(.value)" else empty end' 2>/dev/null)
    fi

    # Append to Dockerfile
    cat >> "${build_dir}/Dockerfile" <<EOF

# Feature: ${feature_id}
${env_lines}
COPY features/${feature_name} /tmp/devcontainer-features/${feature_name}
RUN cd /tmp/devcontainer-features/${feature_name} && \\
    chmod +x install.sh && \\
    ./install.sh && \\
    rm -rf /tmp/devcontainer-features/${feature_name}
EOF

    return 0
}

pull_oci_feature() {
    local feature_ref="$1"
    local dest_dir="$2"

    # Normalize the feature reference
    # ghcr.io/devcontainers/features/node:1 -> ghcr.io/devcontainers/features/node:1
    # devcontainers/features/node:1 -> ghcr.io/devcontainers/features/node:1

    if [[ "${feature_ref}" != *"/"*"/"* ]]; then
        feature_ref="ghcr.io/${feature_ref}"
    fi

    # Check cache first
    local cache_key
    cache_key=$(echo "${feature_ref}" | tr '/:@' '___')
    local cache_dir="${FEATURES_CACHE_DIR}/${cache_key}"

    if [[ -d "${cache_dir}" && -f "${cache_dir}/install.sh" ]]; then
        log_debug "using cached feature: ${feature_ref}"
        cp -r "${cache_dir}"/* "${dest_dir}/"
        return 0
    fi

    mkdir -p "${FEATURES_CACHE_DIR}"

    # Try different methods to pull the OCI artifact

    # Method 1: oras (preferred)
    if command -v oras &>/dev/null; then
        log_debug "pulling feature with oras: ${feature_ref}"
        if oras pull "${feature_ref}" -o "${dest_dir}" 2>/dev/null; then
            # Cache it
            mkdir -p "${cache_dir}"
            cp -r "${dest_dir}"/* "${cache_dir}/"
            return 0
        fi
    fi

    # Method 2: crane
    if command -v crane &>/dev/null; then
        log_debug "pulling feature with crane: ${feature_ref}"
        local tarball="${dest_dir}/feature.tar"
        if crane pull "${feature_ref}" "${tarball}" 2>/dev/null; then
            tar -xf "${tarball}" -C "${dest_dir}" 2>/dev/null || true
            rm -f "${tarball}"
            if [[ -f "${dest_dir}/install.sh" ]]; then
                mkdir -p "${cache_dir}"
                cp -r "${dest_dir}"/* "${cache_dir}/"
                return 0
            fi
        fi
    fi

    # Method 3: Manual OCI registry pull with curl
    # This is a simplified implementation for ghcr.io
    if [[ "${feature_ref}" == ghcr.io/* ]]; then
        if pull_ghcr_feature "${feature_ref}" "${dest_dir}"; then
            mkdir -p "${cache_dir}"
            cp -r "${dest_dir}"/* "${cache_dir}/"
            return 0
        fi
    fi

    log_warn "could not pull feature: ${feature_ref}"
    log_warn "install 'oras' or 'crane' for feature support"
    return 1
}

pull_ghcr_feature() {
    local feature_ref="$1"
    local dest_dir="$2"

    # Parse ghcr.io/owner/repo/name:tag
    local path="${feature_ref#ghcr.io/}"
    local name_with_tag="${path##*/}"
    local repo_path="${path%/*}"

    local name="${name_with_tag%%:*}"
    local tag="${name_with_tag#*:}"
    [[ "${tag}" == "${name}" ]] && tag="latest"

    log_debug "fetching ghcr.io manifest for ${repo_path}/${name}:${tag}"

    # Get manifest
    local manifest
    manifest=$(curl -sfL \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://ghcr.io/v2/${repo_path}/${name}/manifests/${tag}" 2>/dev/null)

    if [[ -z "${manifest}" ]]; then
        return 1
    fi

    # Find the layer (features are typically single-layer tgz)
    local layer_digest
    layer_digest=$(echo "${manifest}" | jq -r '.layers[0].digest // empty')

    if [[ -z "${layer_digest}" ]]; then
        return 1
    fi

    # Download and extract layer
    local layer_url="https://ghcr.io/v2/${repo_path}/${name}/blobs/${layer_digest}"

    if curl -sfL "${layer_url}" | tar -xz -C "${dest_dir}" 2>/dev/null; then
        return 0
    fi

    return 1
}
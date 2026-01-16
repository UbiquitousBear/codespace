#!/usr/bin/env bash
# lib/hooks.sh

run_hooks() {
    local container="$1"
    
    # Hook execution order per devcontainer spec:
    # 1. onCreateCommand
    # 2. updateContentCommand  
    # 3. postCreateCommand
    # 4. postStartCommand
    # 5. postAttachCommand (run when user attaches, handled by expose.sh)
    
    run_hook "${container}" "onCreateCommand" "${DEVCONTAINER_ON_CREATE_COMMAND}"
    run_hook "${container}" "updateContentCommand" "${DEVCONTAINER_UPDATE_CONTENT_COMMAND}"
    run_hook "${container}" "postCreateCommand" "${DEVCONTAINER_POST_CREATE_COMMAND}"
    run_hook "${container}" "postStartCommand" "${DEVCONTAINER_POST_START_COMMAND}"
    
    # postAttachCommand is stored for later
}

run_hook() {
    local container="$1"
    local hook_name="$2"
    local hook_value="$3"
    
    if [[ -z "${hook_value}" || "${hook_value}" == "null" ]]; then
        return
    fi
    
    log info "running ${hook_name}"
    
    # Hook can be:
    # - string: "npm install"
    # - array: ["npm", "install"]
    # - object: {"install": "npm install", "build": "npm run build"}
    
    local hook_type
    hook_type=$(echo "${hook_value}" | jq -r 'type')
    
    case "${hook_type}" in
        string)
            run_hook_command "${container}" "${hook_name}" "${hook_value}"
            ;;
        array)
            # Array is a single command with args
            local cmd
            cmd=$(echo "${hook_value}" | jq -r 'join(" ")')
            run_hook_command "${container}" "${hook_name}" "${cmd}"
            ;;
        object)
            # Object is multiple named commands - run in parallel or sequence
            # Per spec, they can run in parallel
            local pids=()
            while IFS='=' read -r name cmd; do
                log debug "${hook_name}/${name}: ${cmd}"
                run_hook_command "${container}" "${hook_name}/${name}" "${cmd}" &
                pids+=($!)
            done < <(echo "${hook_value}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
            
            # Wait for all
            local failed=0
            for pid in "${pids[@]}"; do
                if ! wait "$pid"; then
                    ((failed++))
                fi
            done
            
            if ((failed > 0)); then
                log warn "${hook_name}: ${failed} command(s) failed"
            fi
            ;;
    esac
}

run_hook_command() {
    local container="$1"
    local hook_name="$2"
    local cmd="$3"
    
    # Remove quotes if it's a JSON string
    cmd=$(echo "${cmd}" | jq -r '. // empty' 2>/dev/null || echo "${cmd}")
    
    log debug "${hook_name}: ${cmd}"
    
    local user_args=""
    if [[ -n "${DEVCONTAINER_REMOTE_USER}" ]]; then
        user_args="-u ${DEVCONTAINER_REMOTE_USER}"
    fi
    
    # Run in container's working directory
    # shellcheck disable=SC2086
    if ! docker exec ${user_args} -w "/workspaces/${WORKSPACE_NAME}" \
        "${container}" /bin/sh -c "${cmd}"; then
        log warn "${hook_name} failed: ${cmd}"
        return 1
    fi
}
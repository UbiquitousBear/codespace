#!/bin/bash
# hooks.sh - Run devcontainer lifecycle hooks
#
# Execution order per spec:
# 1. onCreateCommand - after container created, before user attached
# 2. updateContentCommand - after source updated (we run this on every start for simplicity)
# 3. postCreateCommand - after onCreateCommand, first start only
# 4. postStartCommand - after container starts (every start)
# 5. postAttachCommand - after user attaches (handled separately by IDE/Coder)

# Track if this is first run (for postCreateCommand)
FIRST_RUN_MARKER="/tmp/.devcontainer-first-run-${REPO_NAME}"

run_lifecycle_hooks() {
    local container="$1"

    log_info "running lifecycle hooks"

    local is_first_run=false
    if ! docker exec "${container}" test -f "${FIRST_RUN_MARKER}" 2>/dev/null; then
        is_first_run=true
    fi

    # onCreateCommand - always on first run
    if [[ "${is_first_run}" == "true" ]]; then
        run_hook "${container}" "onCreateCommand" "${DC_ON_CREATE_COMMAND}"
    fi

    # updateContentCommand - we run this every time since source may have changed
    run_hook "${container}" "updateContentCommand" "${DC_UPDATE_CONTENT_COMMAND}"

    # postCreateCommand - only on first run
    if [[ "${is_first_run}" == "true" ]]; then
        run_hook "${container}" "postCreateCommand" "${DC_POST_CREATE_COMMAND}"
    fi

    # postStartCommand - every start
    run_hook "${container}" "postStartCommand" "${DC_POST_START_COMMAND}"

    # Mark that we've done first run
    if [[ "${is_first_run}" == "true" ]]; then
        docker exec "${container}" touch "${FIRST_RUN_MARKER}" 2>/dev/null || true
    fi

    log_info "lifecycle hooks complete"
}

run_hook() {
    local container="$1"
    local hook_name="$2"
    local hook_value="$3"

    # Skip if empty or null
    if [[ -z "${hook_value}" || "${hook_value}" == "null" || "${hook_value}" == '""' ]]; then
        return 0
    fi

    log_info "  ${hook_name}"

    # Determine the type of command specification
    local hook_type
    hook_type=$(echo "${hook_value}" | jq -r 'type' 2>/dev/null || echo "string")

    case "${hook_type}" in
        string)
            # Simple string command
            local cmd
            cmd=$(echo "${hook_value}" | jq -r '.' 2>/dev/null || echo "${hook_value}")
            run_hook_command "${container}" "${hook_name}" "${cmd}"
            ;;

        array)
            # Array is a single command with arguments
            local cmd
            cmd=$(echo "${hook_value}" | jq -r 'join(" ")' 2>/dev/null)
            run_hook_command "${container}" "${hook_name}" "${cmd}"
            ;;

        object)
            # Object is multiple named commands - run in parallel
            run_hook_parallel "${container}" "${hook_name}" "${hook_value}"
            ;;

        *)
            log_warn "${hook_name}: unknown command format"
            ;;
    esac
}

run_hook_command() {
    local container="$1"
    local hook_name="$2"
    local cmd="$3"

    [[ -z "${cmd}" ]] && return 0

    log_debug "${hook_name}: ${cmd}"

    local exec_args=()

    # Run as remote user if specified
    if [[ -n "${DC_REMOTE_USER}" ]]; then
        exec_args+=(-u "${DC_REMOTE_USER}")
    fi

    exec_args+=(-w "${WORKDIR}")

    # Run with shell to handle complex commands
    if ! docker exec "${exec_args[@]}" "${container}" /bin/sh -c "${cmd}"; then
        log_warn "${hook_name} failed (exit $?): ${cmd}"
        # Don't fail the whole process - some hooks fail legitimately
        return 1
    fi

    return 0
}

run_hook_parallel() {
    local container="$1"
    local hook_name="$2"
    local commands="$3"

    local pids=()
    local names=()

    # Start all commands in parallel
    while IFS='=' read -r name cmd; do
        [[ -z "${name}" ]] && continue

        log_debug "${hook_name}/${name}: ${cmd}"

        # Run each command in background
        (
            local exec_args=()
            if [[ -n "${DC_REMOTE_USER}" ]]; then
                exec_args+=(-u "${DC_REMOTE_USER}")
            fi
            exec_args+=(-w "${WORKDIR}")

            docker exec "${exec_args[@]}" "${container}" /bin/sh -c "${cmd}"
        ) &

        pids+=($!)
        names+=("${name}")
    done < <(echo "${commands}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

    # Wait for all and collect results
    local failed=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            log_warn "${hook_name}/${names[$i]} failed"
            ((failed++))
        fi
    done

    if ((failed > 0)); then
        log_warn "${hook_name}: ${failed}/${#pids[@]} command(s) failed"
    fi

    return 0
}

# Run postAttachCommand - called when user connects
run_post_attach() {
    local container="$1"

    if [[ -n "${DC_POST_ATTACH_COMMAND}" && "${DC_POST_ATTACH_COMMAND}" != "null" ]]; then
        run_hook "${container}" "postAttachCommand" "${DC_POST_ATTACH_COMMAND}"
    fi
}
#!/usr/bin/env bash
# lib/expose.sh

start_ssh_proxy() {
    local container="$1"
    
    # SSH into the codespace VM gets proxied into the container
    # This could be a simple socat/netcat proxy or a proper SSH server
    
    local ssh_port="${SSH_PORT:-2222}"
    
    log info "starting SSH proxy on port ${ssh_port}"
    
    # Option 1: Use docker exec as SSH backend
    # This assumes an SSH server is running on the host (LinuxKit)
    # and we proxy commands into the container
    
    # Create a wrapper script for SSH to exec into container
    cat > /usr/local/bin/devcontainer-shell <<'SHELL'
#!/bin/sh
CONTAINER="${DEVCONTAINER_NAME:-devcontainer}"
USER="${DEVCONTAINER_USER:-root}"

if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
    exec docker exec -i -u "${USER}" "${CONTAINER}" /bin/sh -c "$SSH_ORIGINAL_COMMAND"
else
    exec docker exec -it -u "${USER}" "${CONTAINER}" /bin/sh -l
fi
SHELL
    chmod +x /usr/local/bin/devcontainer-shell
    
    # Set env for the shell wrapper
    export DEVCONTAINER_NAME="${container}"
    export DEVCONTAINER_USER="${DEVCONTAINER_REMOTE_USER:-root}"
    
    # If SSH is handled by Coder agent, we just need to ensure
    # the docker exec path works. Coder will SSH to the VM and
    # run commands that we proxy into the container.
}

start_port_watcher() {
    local container="$1"
    
    log info "starting port watcher"
    
    # Watch for listening ports inside the container
    # Notify Coder agent of new ports
    
    local known_ports=""
    
    while true; do
        sleep 5
        
        # Get listening ports from container
        local current_ports
        current_ports=$(docker exec "${container}" \
            sh -c 'ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null' | \
            grep LISTEN | \
            awk '{print $4}' | \
            grep -oE '[0-9]+$' | \
            sort -u | \
            tr '\n' ' ')
        
        if [[ "${current_ports}" != "${known_ports}" ]]; then
            log debug "ports changed: ${current_ports}"
            known_ports="${current_ports}"
            
            # Notify Coder if configured
            if [[ -n "${CODER_AGENT_URL:-}" ]]; then
                notify_ports "${current_ports}"
            fi
            
            # Also write to a file for other processes
            echo "${current_ports}" > /run/devcontainer-ports
        fi
    done
}

notify_ports() {
    local ports="$1"
    
    # Convert to JSON array
    local json_ports
    json_ports=$(echo "${ports}" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s .)
    
    curl -sf -X POST "${CODER_AGENT_URL}/ports" \
        -H "Content-Type: application/json" \
        -d "{\"ports\": ${json_ports}}" || true
}

run_post_attach() {
    local container="$1"
    
    # Called when a user attaches (e.g., SSH session starts)
    if [[ -n "${DEVCONTAINER_POST_ATTACH_COMMAND}" && "${DEVCONTAINER_POST_ATTACH_COMMAND}" != "null" ]]; then
        run_hook "${container}" "postAttachCommand" "${DEVCONTAINER_POST_ATTACH_COMMAND}"
    fi
}
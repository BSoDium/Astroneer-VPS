#!/usr/bin/env bash
# =============================================================================
# lib/ssh.sh — SSH helpers for communicating with the Windows VM
# Must be sourced AFTER lib/common.sh and lib/env.sh.
#
# Security note: StrictHostKeyChecking is disabled because the VM runs on a
# local libvirt NAT network (192.168.122.x). The host key changes every time
# the VM is recreated. This is an accepted trade-off for a local-only VM.
# SSHPASS env var is used (sshpass -e) to avoid leaking the password in the
# process list (visible via `ps aux`).
# =============================================================================

# SSH options used everywhere
readonly SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

# Run a command on the VM via SSH.
vm_ssh() {
    SSHPASS="$WIN_PASSWORD" sshpass -e ssh \
        "${SSH_OPTS[@]}" \
        "$WIN_USERNAME@$VM_IP" "$@"
}

# Run a command on the VM, suppressing stderr.
vm_ssh_quiet() {
    vm_ssh "$@" 2>/dev/null
}

# Copy files to the VM via SCP.
vm_scp() {
    SSHPASS="$WIN_PASSWORD" sshpass -e scp \
        "${SSH_OPTS[@]}" \
        "$@"
}

# Test if SSH is reachable (returns 0/1, no output).
ssh_ready() {
    vm_ssh_quiet "echo ok" &>/dev/null
}

# Wait for SSH with a configurable timeout.
# Usage: wait_ssh [timeout_seconds]
wait_ssh() {
    local timeout="${1:-$SSH_TIMEOUT_DEFAULT}"
    local elapsed=0
    while [[ "$elapsed" -lt "$timeout" ]]; do
        if ssh_ready; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "\r  Waiting for SSH... %ds" "$elapsed"
    done
    echo ""
    return 1
}

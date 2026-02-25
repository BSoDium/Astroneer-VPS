#!/usr/bin/env bash
# =============================================================================
# lib/vm.sh — VM lifecycle helpers (virsh wrappers and guard functions)
# Must be sourced AFTER lib/common.sh and lib/env.sh.
# =============================================================================

# Check if the VM is currently running.
vm_running() {
    sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"
}

# Guard: fail unless the VM is running.
require_running() {
    if ! vm_running; then
        fail "VM is not running. Start it with: ./manage.sh start"
    fi
}

# Guard: fail unless SSH is reachable.
require_ssh() {
    if ! ssh_ready; then
        fail "SSH is not available. Is the VM running?"
    fi
}

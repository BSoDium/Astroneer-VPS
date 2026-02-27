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

# =============================================================================
# Data sync — docker-style host directories ↔ VM
# =============================================================================

# Push host data/config, data/saves, data/mods to the VM.
# INI files are converted from LF to CRLF for Windows compatibility.
sync_to_vm() {
    ensure_data_dirs
    info "Syncing data to VM..."

    # Ensure VM-side directories exist
    vm_ssh_quiet "New-Item -ItemType Directory -Path '$VM_CONFIG_DIR' -Force | Out-Null; \
                  New-Item -ItemType Directory -Path '$VM_SAVES_DIR' -Force | Out-Null; \
                  New-Item -ItemType Directory -Path '$VM_MODS_DIR' -Force | Out-Null" || true

    local tmpdir
    tmpdir=$(mktemp -d)

    # --- Config files (LF → CRLF) ---
    shopt -s nullglob
    local ini_files=("$DATA_CONFIG_DIR"/*.ini)
    shopt -u nullglob

    if [[ ${#ini_files[@]} -gt 0 ]]; then
        for ini in "${ini_files[@]}"; do
            local basename
            basename=$(basename "$ini")
            sed 's/\r*$/\r/' "$ini" > "$tmpdir/$basename"

            if [[ "$basename" == "Launcher.ini" ]]; then
                vm_scp "$tmpdir/$basename" \
                    "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Launcher.ini"
            else
                vm_scp "$tmpdir/$basename" \
                    "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/Config/WindowsServer/$basename"
            fi
        done
        ok "Config files synced (${#ini_files[@]} files)"
    fi

    # --- Save files ---
    shopt -s nullglob
    local save_files=("$DATA_SAVES_DIR"/*)
    shopt -u nullglob

    if [[ ${#save_files[@]} -gt 0 ]]; then
        vm_scp -r "$DATA_SAVES_DIR"/* \
            "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/SaveGames/" || true
        ok "Save files synced (${#save_files[@]} items)"
    fi

    # --- Mod files ---
    shopt -s nullglob
    local mod_files=("$DATA_MODS_DIR"/*.pak)
    shopt -u nullglob

    if [[ ${#mod_files[@]} -gt 0 ]]; then
        vm_scp "$DATA_MODS_DIR"/*.pak \
            "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Content/Paks/" || true
        ok "Mod files synced (${#mod_files[@]} .pak files)"
    fi

    rm -rf "$tmpdir"
}

# Pull VM data (config, saves, backups) to the host.
# INI files are converted from CRLF to LF for clean host-side editing.
sync_from_vm() {
    ensure_data_dirs
    info "Syncing data from VM..."

    # --- Config files ---
    vm_scp "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Launcher.ini" \
        "$DATA_CONFIG_DIR/Launcher.ini" 2>/dev/null || true
    vm_scp "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/Config/WindowsServer/AstroServerSettings.ini" \
        "$DATA_CONFIG_DIR/AstroServerSettings.ini" 2>/dev/null || true
    vm_scp "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/Config/WindowsServer/Engine.ini" \
        "$DATA_CONFIG_DIR/Engine.ini" 2>/dev/null || true

    # Convert CRLF → LF for clean host editing
    shopt -s nullglob
    for ini in "$DATA_CONFIG_DIR"/*.ini; do
        sed -i 's/\r$//' "$ini"
    done
    shopt -u nullglob
    ok "Config files pulled"

    # --- Save files ---
    vm_scp -r "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/SaveGames/*" \
        "$DATA_SAVES_DIR/" 2>/dev/null || true
    ok "Save files pulled"

    # --- Backups ---
    vm_ssh_quiet "Test-Path '$VM_BACKUPS_DIR'" 2>/dev/null | tr -d '\r' | grep -qi true && {
        vm_scp -r "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/Backup/LauncherBackups/*" \
            "$DATA_BACKUPS_DIR/" 2>/dev/null || true
        ok "Backup files pulled"
    } || true
}

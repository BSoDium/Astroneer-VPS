#!/usr/bin/env bash
# =============================================================================
# manage.sh — Manage the Astroneer Windows VM
# Usage: ./manage.sh <command>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
info()  { echo -e "${CYAN}==> $*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }

# SSH helper
vm_ssh() {
    sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$WIN_USERNAME@$VM_IP" "$@"
}

vm_ssh_quiet() {
    vm_ssh "$@" 2>/dev/null
}

# Check if VM is running
vm_running() {
    sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"
}

# Check if SSH is reachable
ssh_ready() {
    vm_ssh_quiet "echo ok" &>/dev/null
}

# Wait for SSH with timeout
wait_ssh() {
    local timeout=${1:-120}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if ssh_ready; then return 0; fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "\r  Waiting for SSH... %ds" $elapsed
    done
    echo ""
    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_start() {
    if vm_running; then
        ok "VM is already running"
    else
        info "Starting VM: $VM_NAME"
        sudo virsh start "$VM_NAME"
    fi

    info "Waiting for SSH..."
    if wait_ssh 180; then
        echo ""
        ok "VM ready — SSH: $WIN_USERNAME@$VM_IP"
    else
        warn "VM started but SSH not yet available"
        warn "It may still be booting. Try: ./manage.sh ssh"
    fi
}

cmd_stop() {
    if ! vm_running; then
        ok "VM is already stopped"
        return
    fi

    info "Shutting down VM gracefully..."
    # Try graceful shutdown via SSH first
    if ssh_ready; then
        vm_ssh_quiet "Stop-Computer -Force" || true
    else
        sudo virsh shutdown "$VM_NAME"
    fi

    # Wait for shutdown
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ] && vm_running; do
        sleep 3
        elapsed=$((elapsed + 3))
    done

    if vm_running; then
        warn "Graceful shutdown timed out, forcing..."
        sudo virsh destroy "$VM_NAME"
    fi
    ok "VM stopped"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    echo ""
    local state
    state=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "not found")
    
    if [ "$state" = "running" ]; then
        echo -e "  VM:       ${GREEN}running${NC}"
    else
        echo -e "  VM:       ${RED}${state}${NC}"
        echo ""
        return
    fi

    echo -e "  IP:       $VM_IP"

    # SSH
    if ssh_ready; then
        echo -e "  SSH:      ${GREEN}reachable${NC}"
    else
        echo -e "  SSH:      ${RED}unreachable${NC}"
    fi

    # Astroneer port
    if nc -z -w2 "$VM_IP" "$ASTRO_PORT" 2>/dev/null; then
        echo -e "  Astroneer:${GREEN} listening on port $ASTRO_PORT${NC}"
    else
        echo -e "  Astroneer:${RED} port $ASTRO_PORT not responding${NC}"
    fi

    # Memory
    local mem
    mem=$(sudo virsh dominfo "$VM_NAME" 2>/dev/null | awk '/Used memory/{printf "%.0f MB", $3/1024}')
    echo -e "  Memory:   $mem / ${VM_RAM} MB"

    # Uptime (via SSH if available)
    if ssh_ready; then
        local uptime
        uptime=$(vm_ssh_quiet "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('g')" 2>/dev/null || echo "unknown")
        echo -e "  Boot:     $uptime"
    fi

    echo ""
    echo -e "  ${DIM}Public:    $ASTRO_PUBLIC_IP:$ASTRO_PORT (via playit.gg)${NC}"
    echo -e "  ${DIM}SSH:       ssh $WIN_USERNAME@$VM_IP${NC}"
    echo ""
}

cmd_ssh() {
    if ! vm_running; then
        fail "VM is not running. Start it with: ./manage.sh start"
    fi
    info "Connecting via SSH..."
    # Interactive SSH (no sshpass in interactive mode for cleaner experience)
    sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$WIN_USERNAME@$VM_IP"
}

cmd_provision() {
    if ! vm_running; then
        fail "VM is not running. Start it with: ./manage.sh start"
    fi
    if ! ssh_ready; then
        fail "SSH is not available yet. Wait and retry."
    fi

    info "Copying setup script to VM..."
    sshpass -p "$WIN_PASSWORD" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SCRIPT_DIR/setup-astroneer.ps1" \
        "$WIN_USERNAME@$VM_IP:C:/setup-astroneer.ps1"
    ok "Script copied"

    info "Running Astroneer installer (this takes a few minutes)..."
    vm_ssh "powershell.exe -ExecutionPolicy Bypass -File C:\\setup-astroneer.ps1 \
        -ServerPort $ASTRO_PORT \
        -ServerName '$ASTRO_SERVER_NAME' \
        -OwnerName '$ASTRO_OWNER_NAME' \
        -PublicIP '$ASTRO_PUBLIC_IP'"
    ok "Provisioning complete"
}

cmd_start_server() {
    if ! ssh_ready; then
        fail "SSH is not available. Is the VM running?"
    fi
    info "Starting Astroneer server..."
    vm_ssh "Start-Process -FilePath 'C:\start-astroneer.bat' -WindowStyle Hidden"
    ok "Astroneer server starting"
    echo "  Check status in ~30s with: ./manage.sh status"
}

cmd_stop_server() {
    if ! ssh_ready; then
        fail "SSH is not available. Is the VM running?"
    fi
    info "Stopping Astroneer server..."
    vm_ssh "Stop-Process -Name AstroServer -Force -ErrorAction SilentlyContinue" || true
    ok "Astroneer server stopped"
}

cmd_update() {
    if ! ssh_ready; then
        fail "SSH is not available. Is the VM running?"
    fi
    info "Updating Astroneer server via SteamCMD..."
    vm_ssh "C:\steamcmd\steamcmd.exe +force_install_dir C:\AstroneerServer +login anonymous +app_update 728470 +quit"
    ok "Update complete"
}

cmd_logs() {
    if ! ssh_ready; then
        # Fall back to libvirt logs
        sudo cat "/var/log/libvirt/qemu/${VM_NAME}.log" 2>/dev/null || echo "No logs found"
        return
    fi
    info "Astroneer server logs:"
    vm_ssh "Get-Content -Path 'C:\AstroneerServer\Astro\Saved\Logs\AstroServerLog.log' -Tail 50 -ErrorAction SilentlyContinue" 2>/dev/null || \
        warn "No Astroneer logs found yet"
}

cmd_autostart() {
    local mode="${1:-}"
    case "$mode" in
        on)  sudo virsh autostart "$VM_NAME"; ok "Autostart enabled" ;;
        off) sudo virsh autostart --disable "$VM_NAME"; ok "Autostart disabled" ;;
        *)   echo "Usage: ./manage.sh autostart [on|off]" ;;
    esac
}

cmd_vnc() {
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo "  VNC is available for emergency access (Server Core has limited GUI)."
    echo ""
    echo "  From your local machine:"
    echo "    ssh -L $VNC_PORT:localhost:$VNC_PORT $(whoami)@$host_ip"
    echo "    Then open VNC → localhost:$VNC_PORT"
    echo "    Password: $VNC_PASSWORD"
    echo ""
    echo "  Prefer SSH instead: ./manage.sh ssh"
    echo ""
}

cmd_destroy() {
    echo -e "${RED}This will permanently delete the VM and its disk.${NC}"
    read -rp "Are you sure? (type 'yes' to confirm) " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        return
    fi
    sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    ok "VM '$VM_NAME' destroyed"
}

cmd_copy_saves() {
    local src="${1:-}"
    if [ -z "$src" ]; then
        src="$HOME/services/astroneer/Saved/SaveGames"
    fi
    if [ ! -d "$src" ]; then
        echo "Usage: ./manage.sh copy-saves [/path/to/SaveGames/]"
        echo "Default: $HOME/services/astroneer/Saved/SaveGames"
        return 1
    fi
    if ! ssh_ready; then
        fail "SSH is not available. Is the VM running?"
    fi
    info "Copying save files from: $src"
    sshpass -p "$WIN_PASSWORD" scp -r \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$src"/* \
        "$WIN_USERNAME@$VM_IP:C:/AstroneerServer/Astro/Saved/SaveGames/"
    ok "Save files copied"
}

# =============================================================================
# Main
# =============================================================================
cmd="${1:-help}"
shift || true

case "$cmd" in
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    restart)      cmd_restart ;;
    status|st)    cmd_status ;;
    ssh)          cmd_ssh ;;
    provision)    cmd_provision ;;
    start-server) cmd_start_server ;;
    stop-server)  cmd_stop_server ;;
    update)       cmd_update ;;
    logs)         cmd_logs ;;
    autostart)    cmd_autostart "$@" ;;
    vnc)          cmd_vnc ;;
    destroy)      cmd_destroy ;;
    copy-saves)   cmd_copy_saves "$@" ;;
    help|--help|-h)
        echo ""
        echo "Usage: ./manage.sh <command>"
        echo ""
        echo "VM lifecycle:"
        echo "  start          Start the VM, wait for SSH"
        echo "  stop           Graceful shutdown"
        echo "  restart        Stop + start"
        echo "  status         VM state, SSH, Astroneer port, memory"
        echo "  destroy        Delete VM and disk (permanent!)"
        echo "  autostart      on|off — auto-start VM on host boot"
        echo ""
        echo "Server management (via SSH):"
        echo "  provision      Install/reinstall Astroneer server in VM"
        echo "  start-server   Start Astroneer inside the VM"
        echo "  stop-server    Stop Astroneer inside the VM"
        echo "  update         Update Astroneer via SteamCMD"
        echo "  logs           Tail Astroneer server logs"
        echo "  copy-saves     Copy saves from old Docker setup"
        echo ""
        echo "Access:"
        echo "  ssh            Interactive SSH session to the VM"
        echo "  vnc            Show VNC connection instructions"
        echo ""
        ;;
    *)
        echo "Unknown command: $cmd"
        echo "Run: ./manage.sh help"
        exit 1
        ;;
esac

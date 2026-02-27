#!/usr/bin/env bash
# =============================================================================
# manage.sh — Manage the Astroneer Windows VM
# Usage: ./manage.sh [--dry-run] <command> [args...]
# =============================================================================
set -euo pipefail

# ---------- load shared libraries ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for lib in common env ssh vm; do
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/lib/${lib}.sh"
done

# ---------- init ----------
init_env

# =============================================================================
# Commands
# =============================================================================

cmd_start() {
    if vm_running; then
        ok "VM is already running"
    else
        info "Starting VM: $VM_NAME"
        run sudo virsh start "$VM_NAME"
    fi

    info "Waiting for SSH..."
    if wait_ssh "$SSH_TIMEOUT_START"; then
        echo ""
        setup_port_forward
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
        run sudo virsh shutdown "$VM_NAME"
    fi

    # Wait for shutdown
    local elapsed=0
    while [[ "$elapsed" -lt "$SHUTDOWN_TIMEOUT" ]] && vm_running; do
        sleep 3
        elapsed=$((elapsed + 3))
    done

    if vm_running; then
        warn "Graceful shutdown timed out, forcing..."
        run sudo virsh destroy "$VM_NAME"
    fi
    teardown_port_forward
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

    if [[ "$state" == "running" ]]; then
        echo -e "  VM:        ${GREEN}running${NC}"
    else
        echo -e "  VM:        ${RED}${state}${NC}"
        echo ""
        return
    fi

    echo -e "  IP:        $VM_IP"

    # SSH
    if ssh_ready; then
        echo -e "  SSH:       ${GREEN}reachable${NC}"
    else
        echo -e "  SSH:       ${RED}unreachable${NC}"
    fi

    # AstroLauncher + Astroneer server processes (via SSH for reliability)
    if ssh_ready; then
        local launcher_pid
        launcher_pid=$(vm_ssh_quiet "Get-Process -Name AstroLauncher -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$launcher_pid" ]]; then
            echo -e "  Launcher:  ${GREEN}running (PID $launcher_pid)${NC}"
        else
            echo -e "  Launcher:  ${RED}not running${NC}"
        fi

        local astro_pid
        astro_pid=$(vm_ssh_quiet "Get-Process -Name AstroServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$astro_pid" ]]; then
            echo -e "  Astroneer: ${GREEN}running (PID $astro_pid, port $ASTRO_PORT)${NC}"
        else
            echo -e "  Astroneer: ${RED}not running${NC}"
        fi

        if [[ -n "$launcher_pid" ]]; then
            echo -e "  Web UI:    ${GREEN}http://$VM_IP:$ASTRO_LAUNCHER_PORT${NC}"
        fi
    else
        echo -e "  Launcher:  ${DIM}unknown (SSH unavailable)${NC}"
        echo -e "  Astroneer: ${DIM}unknown (SSH unavailable)${NC}"
    fi

    # Memory
    local mem
    mem=$(sudo virsh dominfo "$VM_NAME" 2>/dev/null | awk '/Used memory/{printf "%.0f MB", $3/1024}')
    echo -e "  Memory:    $mem / ${VM_RAM} MB"

    # Uptime (via SSH if available)
    if ssh_ready; then
        local uptime
        uptime=$(vm_ssh_quiet "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('g')" 2>/dev/null | tr -d '\r' || echo "unknown")
        echo -e "  Boot:      $uptime"
    fi

    echo ""
    echo -e "  ${DIM}Public:     $ASTRO_PUBLIC_IP:$ASTRO_PORT (via playit.gg)${NC}"
    echo -e "  ${DIM}SSH:        ssh $WIN_USERNAME@$VM_IP${NC}"
    echo ""
}

cmd_ssh() {
    require_running
    info "Connecting via SSH..."
    # Interactive SSH — uses SSHPASS env var (sshpass -e)
    SSHPASS="$WIN_PASSWORD" sshpass -e ssh \
        "${SSH_OPTS[@]}" \
        "$WIN_USERNAME@$VM_IP"
}

# ---------- port forwarding helpers ----------
# playit.gg forwards incoming traffic to localhost on the host.
# The Astroneer server runs inside the VM (192.168.122.x), so we need
# iptables DNAT to route host:ASTRO_PORT -> VM_IP:ASTRO_PORT (UDP).

_port_forward_rule() {
    # Prints the iptables args for the DNAT rule (without -A/-D/-C).
    echo "PREROUTING -t nat -p udp --dport $ASTRO_PORT -j DNAT --to-destination $VM_IP:$ASTRO_PORT"
}

setup_port_forward() {
    # Game port (UDP)
    local rule
    rule=$(_port_forward_rule)
    # shellcheck disable=SC2086
    if ! sudo iptables -C $rule 2>/dev/null; then
        # shellcheck disable=SC2086
        run sudo iptables -A $rule
        if ! sudo iptables -C FORWARD -p udp -d "$VM_IP" --dport "$ASTRO_PORT" -j ACCEPT 2>/dev/null; then
            run sudo iptables -A FORWARD -p udp -d "$VM_IP" --dport "$ASTRO_PORT" -j ACCEPT
        fi
        ok "Port forward: host:$ASTRO_PORT -> $VM_IP:$ASTRO_PORT (UDP)"
    fi

    # AstroLauncher web UI (TCP)
    if ! sudo iptables -C PREROUTING -t nat -p tcp --dport "$ASTRO_LAUNCHER_PORT" -j DNAT --to-destination "$VM_IP:$ASTRO_LAUNCHER_PORT" 2>/dev/null; then
        run sudo iptables -A PREROUTING -t nat -p tcp --dport "$ASTRO_LAUNCHER_PORT" -j DNAT --to-destination "$VM_IP:$ASTRO_LAUNCHER_PORT"
        if ! sudo iptables -C FORWARD -p tcp -d "$VM_IP" --dport "$ASTRO_LAUNCHER_PORT" -j ACCEPT 2>/dev/null; then
            run sudo iptables -A FORWARD -p tcp -d "$VM_IP" --dport "$ASTRO_LAUNCHER_PORT" -j ACCEPT
        fi
        ok "Port forward: host:$ASTRO_LAUNCHER_PORT -> $VM_IP:$ASTRO_LAUNCHER_PORT (TCP, web UI)"
    fi
}

teardown_port_forward() {
    # Game port (UDP)
    local rule
    rule=$(_port_forward_rule)
    # shellcheck disable=SC2086
    if sudo iptables -C $rule 2>/dev/null; then
        # shellcheck disable=SC2086
        run sudo iptables -D $rule
        sudo iptables -D FORWARD -p udp -d "$VM_IP" --dport "$ASTRO_PORT" -j ACCEPT 2>/dev/null || true
        ok "Port forward removed (UDP)"
    fi

    # AstroLauncher web UI (TCP)
    if sudo iptables -C PREROUTING -t nat -p tcp --dport "$ASTRO_LAUNCHER_PORT" -j DNAT --to-destination "$VM_IP:$ASTRO_LAUNCHER_PORT" 2>/dev/null; then
        run sudo iptables -D PREROUTING -t nat -p tcp --dport "$ASTRO_LAUNCHER_PORT" -j DNAT --to-destination "$VM_IP:$ASTRO_LAUNCHER_PORT"
        sudo iptables -D FORWARD -p tcp -d "$VM_IP" --dport "$ASTRO_LAUNCHER_PORT" -j ACCEPT 2>/dev/null || true
        ok "Port forward removed (TCP, web UI)"
    fi
}

cmd_install() {
    require_running
    require_ssh

    info "Copying setup script to VM..."
    # Convert LF→CRLF: Windows PowerShell 5.1 requires CRLF for here-strings
    local tmp_ps1
    tmp_ps1=$(mktemp)
    sed 's/\r*$/\r/' "$SCRIPT_DIR/setup-astroneer.ps1" > "$tmp_ps1"
    vm_scp "$tmp_ps1" \
        "$WIN_USERNAME@$VM_IP:C:/setup-astroneer.ps1"
    rm -f "$tmp_ps1"
    ok "Script copied"

    info "Running Astroneer + AstroLauncher installer (this takes a few minutes)..."
    vm_ssh "powershell.exe -ExecutionPolicy Bypass -File C:\\setup-astroneer.ps1 \
        -ServerPort $ASTRO_PORT \
        -LauncherPort $ASTRO_LAUNCHER_PORT"
    ok "Installation complete"

    # Seed host data/ with default configs from VM
    info "Seeding default configuration files..."
    sync_from_vm

    ok "Default configs saved to data/config/"
    echo ""
    echo "  Next steps:"
    echo "    1. Edit data/config/AstroServerSettings.ini (server name, owner, password)"
    echo "    2. Edit data/config/Launcher.ini (web UI, Discord, backups)"
    echo "    3. Drop saves into data/saves/ and mods into data/mods/ (optional)"
    echo "    4. Start: ./manage.sh start-server"
    echo ""
}

cmd_start_server() {
    require_ssh

    # Sync host data to VM
    sync_to_vm

    info "Starting AstroLauncher..."

    # Kill any existing instances first to avoid duplicates
    vm_ssh_quiet "Stop-Process -Name AstroLauncher -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
    vm_ssh_quiet "Stop-Process -Name AstroServer -Force -ErrorAction SilentlyContinue; Stop-Process -Name AstroServer-Win64-Shipping -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
    sleep 3

    # Start AstroLauncher.exe via WMI — this creates a process fully detached from
    # the SSH session so it survives disconnect. Start-Process doesn't reliably
    # outlive non-interactive SSH sessions on Windows.
    vm_ssh_quiet "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='C:\\AstroneerServer\\AstroLauncher.exe'; CurrentDirectory='C:\\AstroneerServer'} | Out-Null"

    setup_port_forward

    # Wait for AstroServer-Win64-Shipping to spawn (AstroLauncher starts it after
    # config validation, optional SteamCMD update, and PlayFab registration)
    info "Waiting for server to initialize..."
    local astro_pid=""
    local elapsed=0
    while [[ "$elapsed" -lt 90 ]]; do
        sleep 10
        elapsed=$((elapsed + 10))
        astro_pid=$(vm_ssh_quiet "Get-Process -Name AstroServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$astro_pid" ]]; then
            break
        fi
        printf "\r  Waiting... %ds" "$elapsed"
    done
    echo ""

    if [[ -n "$astro_pid" ]]; then
        ok "Astroneer server running (PID $astro_pid, port $ASTRO_PORT)"
        echo -e "  ${DIM}Web UI: http://$VM_IP:$ASTRO_LAUNCHER_PORT${NC}"
    else
        warn "Server process not detected yet — AstroLauncher may still be updating"
        warn "Check logs with: ./manage.sh logs"
    fi
}

cmd_stop_server() {
    require_ssh
    info "Stopping AstroLauncher and Astroneer server..."

    # Kill AstroLauncher first (it will attempt to cleanly stop AstroServer)
    vm_ssh_quiet "Stop-Process -Name AstroLauncher -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
    sleep 5

    # Kill AstroServer as cleanup in case AstroLauncher didn't stop it
    vm_ssh_quiet "Stop-Process -Name AstroServer -Force -ErrorAction SilentlyContinue; Stop-Process -Name AstroServer-Win64-Shipping -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
    sleep 2

    teardown_port_forward

    # Sync data back from VM
    sync_from_vm

    ok "Server stopped and data synced"
}

cmd_sync() {
    local direction="${1:-both}"
    require_ssh

    case "$direction" in
        to|push)
            sync_to_vm
            ok "Data pushed to VM"
            ;;
        from|pull)
            sync_from_vm
            ok "Data pulled from VM"
            ;;
        both)
            sync_from_vm
            sync_to_vm
            ok "Data synced (pull + push)"
            ;;
        *)
            echo "Usage: ./manage.sh sync [to|from|both]"
            echo ""
            echo "  to/push    Push host data/config, data/saves, data/mods to VM"
            echo "  from/pull  Pull config, saves, backups from VM to host"
            echo "  both       Pull first, then push (default)"
            return 1
            ;;
    esac
}

cmd_logs() {
    local lines="$LOG_TAIL_DEFAULT"
    local follow=false
    local source="launcher"
    for arg in "$@"; do
        # shellcheck disable=SC2249
        case "$arg" in
            --lines=*) lines="${arg#*=}" ;;
            --follow|-f) follow=true ;;
            --server) source="server" ;;
            --launcher) source="launcher" ;;
        esac
    done

    if ! ssh_ready; then
        # Fall back to libvirt logs
        sudo cat "/var/log/libvirt/qemu/${VM_NAME}.log" 2>/dev/null || echo "No logs found"
        return
    fi

    local log_path
    if [[ "$source" == "server" ]]; then
        log_path='C:\AstroneerServer\Astro\Saved\Logs\AstroServerLog.log'
        info "Astroneer server logs (last $lines lines):"
    else
        log_path='C:\AstroneerServer\logs\AstroLauncher.log'
        info "AstroLauncher logs (last $lines lines):"
    fi

    if [[ "$follow" == true ]]; then
        vm_ssh "Get-Content -Path '$log_path' -Tail $lines -Wait -ErrorAction SilentlyContinue" 2>/dev/null || \
            warn "No logs found at $log_path"
    else
        vm_ssh "Get-Content -Path '$log_path' -Tail $lines -ErrorAction SilentlyContinue" 2>/dev/null || \
            warn "No logs found at $log_path"
    fi
}

cmd_autostart() {
    local mode="${1:-}"
    case "$mode" in
        on)  run sudo virsh autostart "$VM_NAME"; ok "Autostart enabled" ;;
        off) run sudo virsh autostart --disable "$VM_NAME"; ok "Autostart disabled" ;;
        *)   echo "Usage: ./manage.sh autostart [on|off]" ;;
    esac
}

cmd_vnc() {
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<host-ip>")
    echo ""
    echo "  VNC is available for emergency/visual access to the VM."
    echo ""
    echo "  From your local machine:"
    echo "    ssh -L $VNC_PORT:localhost:$VNC_PORT $(whoami)@$host_ip"
    echo "    Then open VNC -> localhost:$VNC_PORT"
    echo "    Password: $VNC_PASSWORD"
    echo ""
    echo "  Prefer SSH instead: ./manage.sh ssh"
    echo ""
}

cmd_destroy() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${DIM}[dry-run] Would destroy VM '$VM_NAME' and remove all storage${NC}"
        return
    fi
    echo -e "${RED}This will permanently delete the VM and its disk.${NC}"
    read -rp "Are you sure? (type 'yes' to confirm) " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return
    fi
    teardown_port_forward
    run sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    # Only remove the VM disk image, not the Windows/VirtIO ISOs.
    run sudo virsh undefine "$VM_NAME" 2>/dev/null || true
    [[ -f "$IMAGES_DIR/${VM_NAME}.qcow2" ]] && run sudo rm -f "$IMAGES_DIR/${VM_NAME}.qcow2"
    ok "VM '$VM_NAME' destroyed"
}

# =============================================================================
# Main — parse global flags, then dispatch
# =============================================================================

# Extract global flags before the command
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --version) echo "astroneer-vps v${VERSION}"; exit 0 ;;
        --help|-h) set -- help ;; # trick: replace $1 with "help" and fall through
        *)         warn "Unknown flag: $1" ;;
    esac
    shift
done

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    restart)      cmd_restart ;;
    status|st)    cmd_status ;;
    ssh)          cmd_ssh ;;
    install)      cmd_install ;;
    start-server) cmd_start_server ;;
    stop-server)  cmd_stop_server ;;
    sync)         cmd_sync "$@" ;;
    logs)         cmd_logs "$@" ;;
    autostart)    cmd_autostart "$@" ;;
    vnc)          cmd_vnc ;;
    destroy)      cmd_destroy ;;
    help|--help|-h)
        echo ""
        echo "Usage: ./manage.sh [--dry-run] <command> [args...]"
        echo ""
        echo "Global flags:"
        echo "  --dry-run      Print destructive actions without executing"
        echo "  --version      Print version and exit"
        echo ""
        echo "VM lifecycle:"
        echo "  start          Start the VM, wait for SSH"
        echo "  stop           Graceful shutdown"
        echo "  restart        Stop + start"
        echo "  status         VM state, SSH, Astroneer, AstroLauncher status"
        echo "  destroy        Delete VM and disk (permanent!)"
        echo "  autostart      on|off — auto-start VM on host boot"
        echo ""
        echo "Server management:"
        echo "  install        One-time: install Astroneer + AstroLauncher in VM"
        echo "  start-server   Sync data, start AstroLauncher + Astroneer"
        echo "  stop-server    Stop server, sync data back to host"
        echo "  sync           Sync data [to|from|both] between host and VM"
        echo "  logs           Tail logs [--lines=N] [--follow] [--server|--launcher]"
        echo ""
        echo "Access:"
        echo "  ssh            Interactive SSH session to the VM"
        echo "  vnc            Show VNC connection instructions"
        echo ""
        echo "Data directories (docker-style):"
        echo "  data/config/   Server config files (.ini) — edit on host"
        echo "  data/saves/    Save files — drop in before start-server"
        echo "  data/mods/     Mod .pak files — drop in before start-server"
        echo "  data/backups/  AstroLauncher backups — pulled on stop-server"
        echo ""
        ;;
    *)
        echo "Unknown command: $cmd"
        echo "Run: ./manage.sh help"
        exit 1
        ;;
esac

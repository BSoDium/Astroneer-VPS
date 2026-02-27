#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time setup: install KVM, create VM, provision Astroneer
# Usage: ./setup.sh [--windows-iso=/path/to/iso] [--skip-provision] [--force]
#                    [--dry-run] [--version] [--help]
# =============================================================================
set -euo pipefail

# ---------- load shared libraries ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for lib in common env ssh vm; do
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/lib/${lib}.sh"
done

# ---------- parse arguments ----------
WIN_ISO=""
SKIP_PROVISION=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --windows-iso=*) WIN_ISO="${arg#*=}" ;;
        --skip-provision) SKIP_PROVISION=true ;;
        --force)          FORCE=true ;;
        --dry-run)        DRY_RUN=true ;;
        --version)        echo "astroneer-vps v${VERSION}"; exit 0 ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --windows-iso=PATH   Path to Windows Server 2022 ISO"
            echo "  --skip-provision     Skip Astroneer server installation"
            echo "  --force              Skip confirmation prompts"
            echo "  --dry-run            Print actions without executing"
            echo "  --version            Print version and exit"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *) warn "Unknown argument: $arg" ;;
    esac
done

# ---------- init ----------
init_env
acquire_lock

# Track background PID and temp directory for cleanup
VIRT_PID=""
STAGING=""
# shellcheck disable=SC2016 # Single quotes intentional — expanded at cleanup time via eval
register_cleanup '[[ -n "$STAGING" ]] && rm -rf "$STAGING"'
# shellcheck disable=SC2016
register_cleanup '[[ -n "$VIRT_PID" ]] && kill "$VIRT_PID" 2>/dev/null || true'

# =============================================================================
# Step 1: Check prerequisites
# =============================================================================
info "Checking prerequisites"

if ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
    fail "CPU virtualization (VT-x/AMD-V) not available. Enable in BIOS."
fi
ok "CPU virtualization supported"

# Disk space check (check parent dir if IMAGES_DIR doesn't exist yet)
REQUIRED_GB=$(( VM_DISK_SIZE + 5 ))
_disk_check_dir="$IMAGES_DIR"
[[ ! -d "$_disk_check_dir" ]] && _disk_check_dir="$(dirname "$IMAGES_DIR")"
if [[ -d "$_disk_check_dir" ]]; then
    AVAIL_GB=$(df --output=avail -BG "$_disk_check_dir" 2>/dev/null | tail -1 | tr -d ' G')
    if [[ -n "$AVAIL_GB" ]] && [[ "$AVAIL_GB" -lt "$REQUIRED_GB" ]]; then
        fail "Insufficient disk space in $IMAGES_DIR: ${AVAIL_GB}GB available, ${REQUIRED_GB}GB required"
    fi
    ok "Disk space: ${AVAIL_GB}GB available (need ${REQUIRED_GB}GB)"
fi

# =============================================================================
# Step 2: Install KVM packages
# =============================================================================
info "Installing KVM packages"
PACKAGES=(qemu-system-x86 libvirt-daemon-system libvirt-clients bridge-utils virtinst
          genisoimage sshpass netcat-openbsd)
NEEDED=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        NEEDED+=("$pkg")
    fi
done

if [[ ${#NEEDED[@]} -gt 0 ]]; then
    info "Installing: ${NEEDED[*]}"
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq "${NEEDED[@]}"
    ok "Installed: ${NEEDED[*]}"
else
    ok "All packages already installed"
fi

# Add user to libvirt group if needed
if ! groups | grep -q libvirt; then
    run sudo usermod -aG libvirt "$USER"
    warn "Added $USER to libvirt group — you may need to log out/in for full access"
fi

# Start libvirtd
run sudo systemctl enable --now libvirtd
ok "libvirtd running"

# Start default network
if ! sudo virsh net-info default &>/dev/null || \
   [[ "$(sudo virsh net-info default 2>/dev/null | awk '/Active:/{print $2}')" != "yes" ]]; then
    run sudo virsh net-start default 2>/dev/null || true
    run sudo virsh net-autostart default 2>/dev/null || true
fi
ok "Default NAT network active"

# =============================================================================
# Step 3: Download VirtIO drivers
# =============================================================================
info "Checking VirtIO drivers ISO"
run sudo mkdir -p "$IMAGES_DIR"
VIRTIO_ISO="$IMAGES_DIR/virtio-win.iso"
readonly VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

if [[ ! -f "$VIRTIO_ISO" ]]; then
    info "Downloading VirtIO drivers (~600MB)..."
    run sudo wget -q --show-progress -O "$VIRTIO_ISO" "$VIRTIO_URL"
    ok "VirtIO ISO downloaded"
else
    ok "VirtIO ISO already exists"
fi

# =============================================================================
# Step 4: Locate Windows Server ISO
# =============================================================================
info "Locating Windows Server 2022 ISO"
if [[ -z "$WIN_ISO" ]]; then
    # Check common locations (nullglob avoids iterating literal glob strings)
    shopt -s nullglob
    local_candidates=(
        "$IMAGES_DIR/Win2022.iso"
        "$IMAGES_DIR/windows-server-2022.iso"
        "$IMAGES_DIR/SERVER_EVAL"*.iso
        "$HOME/Win2022.iso"
        "$HOME/Downloads/"*SERVER*2022*.iso
    )
    shopt -u nullglob

    for candidate in "${local_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            WIN_ISO="$candidate"
            break
        fi
    done
fi

if [[ -z "$WIN_ISO" ]] || [[ ! -f "$WIN_ISO" ]]; then
    echo ""
    echo -e "${YELLOW}Windows Server 2022 ISO not found.${NC}"
    echo ""
    echo "Download the evaluation ISO (180-day trial) from:"
    echo "  https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022"
    echo ""
    echo "Select: ISO download → 64-bit edition"
    echo ""
    echo "Then either:"
    echo "  1. Place it at: $IMAGES_DIR/Win2022.iso"
    echo "  2. Re-run: $0 --windows-iso=/path/to/downloaded.iso"
    echo ""
    echo "To transfer from another machine:"
    echo "  scp /path/to/SERVER_EVAL*.iso $(whoami)@$(hostname):$IMAGES_DIR/Win2022.iso"
    echo ""
    exit 1
fi

# Copy to standard location if not already there
DEST_ISO="$IMAGES_DIR/Win2022.iso"
RESOLVED_WIN="$(readlink -f "$WIN_ISO")"
RESOLVED_DEST="$(readlink -f "$DEST_ISO" 2>/dev/null || echo "")"
if [[ "$RESOLVED_WIN" != "$RESOLVED_DEST" ]]; then
    run sudo cp "$WIN_ISO" "$DEST_ISO"
fi
ok "Windows ISO: $DEST_ISO"

# =============================================================================
# Step 5: Build autounattend ISO (from template)
# =============================================================================
info "Building autounattend ISO"
STAGING=$(mktemp -d)

# Substitute @@PLACEHOLDER@@ tokens with values from .env
sed -e "s|@@WIN_USERNAME@@|${WIN_USERNAME}|g" \
    -e "s|@@WIN_PASSWORD@@|${WIN_PASSWORD}|g" \
    "$SCRIPT_DIR/templates/autounattend.xml.tpl" \
    > "$STAGING/autounattend.xml"

cp "$SCRIPT_DIR/setup-astroneer.ps1" "$STAGING/"

genisoimage -quiet -o "$STAGING/autounattend.iso" \
    -joliet -rock \
    -volid "OEMDRV" \
    "$STAGING/"
run sudo mv "$STAGING/autounattend.iso" "$IMAGES_DIR/autounattend.iso"
AUTOUNATTEND_ISO="$IMAGES_DIR/autounattend.iso"
rm -rf "$STAGING"
STAGING=""  # clear so cleanup trap doesn't double-delete
ok "Autounattend ISO built (credentials from .env)"

# =============================================================================
# Step 6: Destroy existing VM if present
# =============================================================================
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    warn "VM '$VM_NAME' already exists"
    if [[ "$FORCE" != true ]]; then
        read -rp "Destroy and recreate? (y/n) " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
    run sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    # Only remove the VM disk image, not all attached storage.
    # --remove-all-storage would also delete the Windows and VirtIO ISOs.
    run sudo virsh undefine "$VM_NAME" 2>/dev/null || true
    [[ -f "$IMAGES_DIR/${VM_NAME}.qcow2" ]] && run sudo rm -f "$IMAGES_DIR/${VM_NAME}.qcow2"
    ok "Old VM removed"
fi

# =============================================================================
# Step 7: Create VM
# =============================================================================
info "Creating VM: $VM_NAME"
info "  RAM: ${VM_RAM}MB | CPUs: $VM_CPUS | Disk: ${VM_DISK_SIZE}GB"

# Generate a consistent MAC address from VM name
VM_MAC="52:54:00:$(echo -n "$VM_NAME" | md5sum | sed 's/\(..\)\(..\)\(..\).*/\1:\2:\3/')"

run sudo virt-install \
    --name "$VM_NAME" \
    --ram "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --os-variant win2k22 \
    --disk "path=$IMAGES_DIR/${VM_NAME}.qcow2,size=$VM_DISK_SIZE,bus=virtio,format=qcow2" \
    --cdrom "$DEST_ISO" \
    --disk "path=$VIRTIO_ISO,device=cdrom" \
    --disk "path=$AUTOUNATTEND_ISO,device=cdrom" \
    --network "network=default,model=virtio,mac=$VM_MAC" \
    --graphics "vnc,listen=127.0.0.1,port=$VNC_PORT,password=$VNC_PASSWORD" \
    --boot hd,cdrom \
    --noautoconsole \
    --wait -1 &

VIRT_PID=$!
ok "VM creation started (PID: $VIRT_PID)"

# =============================================================================
# Step 8: Configure static DHCP lease
# =============================================================================
info "Configuring static IP: $VM_IP"
run sudo virsh net-update default add ip-dhcp-host \
    "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" \
    --live --config 2>/dev/null || warn "DHCP lease may already exist"
ok "Static DHCP: $VM_MAC → $VM_IP"

# =============================================================================
# Step 9: Wait for Windows installation
# =============================================================================
echo ""
info "Windows Server 2022 is installing..."
info "This takes 20-45 minutes. You can monitor via VNC:"
echo ""
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<host-ip>")
echo "  From your local machine:"
echo "    ssh -L ${VNC_PORT}:localhost:${VNC_PORT} $(whoami)@${HOST_IP}"
echo "    Then open VNC client → localhost:${VNC_PORT}"
echo ""
info "Waiting for SSH to become available on $VM_IP:22..."

# Poll for SSH
ELAPSED=0
while [[ "$ELAPSED" -lt "$SETUP_SSH_TIMEOUT" ]]; do
    if ssh_ready; then
        break
    fi
    printf "\r  Waiting... %d/%ds" "$ELAPSED" "$SETUP_SSH_TIMEOUT"
    sleep "$SETUP_SSH_INTERVAL"
    ELAPSED=$((ELAPSED + SETUP_SSH_INTERVAL))
done
echo ""

if [[ "$ELAPSED" -ge "$SETUP_SSH_TIMEOUT" ]]; then
    warn "SSH did not become available within ${SETUP_SSH_TIMEOUT}s"
    warn "Connect via VNC to check status, then run: ./manage.sh provision"
    exit 1
fi

# Reap the background virt-install process
wait "$VIRT_PID" 2>/dev/null || true
VIRT_PID=""  # clear so cleanup trap doesn't try to kill

ok "SSH is up! Windows Server installed successfully."

# =============================================================================
# Step 10: Provision Astroneer server
# =============================================================================
if [[ "$SKIP_PROVISION" == true ]]; then
    info "Skipping installation (--skip-provision)"
    info "Run later with: ./manage.sh install"
else
    info "Installing Astroneer server + AstroLauncher via SSH..."
    "$SCRIPT_DIR/manage.sh" install
fi

# Ensure data directory structure exists
mkdir -p "$SCRIPT_DIR/data/"{config,saves,mods,backups}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  VM:     $VM_NAME ($VM_IP)"
echo "  SSH:    ssh $WIN_USERNAME@$VM_IP"
echo ""
echo "  Next steps:"
echo "    1. Edit data/config/AstroServerSettings.ini (server name, owner, password)"
echo "    2. Edit data/config/Launcher.ini (web UI, Discord, backups)"
echo "    3. Update playit.gg tunnel -> Local Address: $VM_IP:$ASTRO_PORT"
echo "    4. Start server: ./manage.sh start-server"
echo "    5. (Optional) Drop saves into data/saves/ and mods into data/mods/"
echo ""

#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time setup: install KVM, create VM, provision Astroneer
# Usage: ./setup.sh [--windows-iso /path/to/server2022.iso]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==> $*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
fail()  { echo -e "${RED}  ✗ $*${NC}"; exit 1; }

# Parse args
WIN_ISO=""
SKIP_PROVISION=false
for arg in "$@"; do
    case "$arg" in
        --windows-iso=*) WIN_ISO="${arg#*=}" ;;
        --skip-provision) SKIP_PROVISION=true ;;
        --help|-h) echo "Usage: $0 [--windows-iso=/path/to/iso] [--skip-provision]"; exit 0 ;;
    esac
done

# =============================================================================
# Step 1: Check prerequisites
# =============================================================================
info "Checking prerequisites"

# CPU virtualization
if ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
    fail "CPU virtualization (VT-x/AMD-V) not available. Enable in BIOS."
fi
ok "CPU virtualization supported"

# =============================================================================
# Step 2: Install KVM packages
# =============================================================================
info "Installing KVM packages"
PACKAGES=(qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst genisoimage sshpass)
NEEDED=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" &>/dev/null; then
        NEEDED+=("$pkg")
    fi
done

if [ ${#NEEDED[@]} -gt 0 ]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${NEEDED[@]}"
    ok "Installed: ${NEEDED[*]}"
else
    ok "All packages already installed"
fi

# Add user to libvirt group if needed
if ! groups | grep -q libvirt; then
    sudo usermod -aG libvirt "$USER"
    warn "Added $USER to libvirt group — you may need to log out/in for full access"
fi

# Start libvirtd
sudo systemctl enable --now libvirtd
ok "libvirtd running"

# Start default network
if ! sudo virsh net-info default &>/dev/null || \
   [ "$(sudo virsh net-info default 2>/dev/null | awk '/Active:/{print $2}')" != "yes" ]; then
    sudo virsh net-start default 2>/dev/null || true
    sudo virsh net-autostart default 2>/dev/null || true
fi
ok "Default NAT network active"

# =============================================================================
# Step 3: Download VirtIO drivers
# =============================================================================
info "Checking VirtIO drivers ISO"
VIRTIO_ISO="$IMAGES_DIR/virtio-win.iso"
if [ ! -f "$VIRTIO_ISO" ]; then
    info "Downloading VirtIO drivers (~600MB)..."
    sudo wget -q --show-progress -O "$VIRTIO_ISO" \
        "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    ok "VirtIO ISO downloaded"
else
    ok "VirtIO ISO already exists"
fi

# =============================================================================
# Step 4: Locate Windows Server ISO
# =============================================================================
info "Locating Windows Server 2022 ISO"
if [ -z "$WIN_ISO" ]; then
    # Check common locations
    for candidate in \
        "$IMAGES_DIR/Win2022.iso" \
        "$IMAGES_DIR/windows-server-2022.iso" \
        "$IMAGES_DIR/SERVER_EVAL"*.iso \
        "$HOME/Win2022.iso" \
        "$HOME/Downloads/"*SERVER*2022*.iso; do
        if [ -f "$candidate" ]; then
            WIN_ISO="$candidate"
            break
        fi
    done
fi

if [ -z "$WIN_ISO" ] || [ ! -f "$WIN_ISO" ]; then
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
if [ "$(realpath "$WIN_ISO")" != "$(realpath "$DEST_ISO" 2>/dev/null || echo "")" ]; then
    sudo cp "$WIN_ISO" "$DEST_ISO"
fi
ok "Windows ISO: $DEST_ISO"

# =============================================================================
# Step 5: Build autounattend ISO
# =============================================================================
info "Building autounattend ISO"
STAGING=$(mktemp -d)
cp "$SCRIPT_DIR/autounattend.xml" "$STAGING/"
cp "$SCRIPT_DIR/setup-astroneer.ps1" "$STAGING/"

AUTOUNATTEND_ISO="$IMAGES_DIR/autounattend.iso"
genisoimage -quiet -o "$AUTOUNATTEND_ISO" \
    -joliet -rock \
    -volid "OEMDRV" \
    "$STAGING/"
sudo mv "$AUTOUNATTEND_ISO" "$IMAGES_DIR/" 2>/dev/null || true
AUTOUNATTEND_ISO="$IMAGES_DIR/autounattend.iso"
rm -rf "$STAGING"
ok "Autounattend ISO built"

# =============================================================================
# Step 6: Destroy existing VM if present
# =============================================================================
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    warn "VM '$VM_NAME' already exists"
    read -rp "Destroy and recreate? (y/n) " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted."
        exit 0
    fi
    sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    ok "Old VM removed"
fi

# =============================================================================
# Step 7: Create VM
# =============================================================================
info "Creating VM: $VM_NAME"
info "  RAM: ${VM_RAM}MB | CPUs: $VM_CPUS | Disk: ${VM_DISK_SIZE}GB"

# Generate a consistent MAC address from VM name
VM_MAC="52:54:00:$(echo -n "$VM_NAME" | md5sum | sed 's/\(..\)\(..\)\(..\).*/\1:\2:\3/')"

sudo virt-install \
    --name "$VM_NAME" \
    --ram "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --os-variant win2k22 \
    --disk "path=$IMAGES_DIR/${VM_NAME}.qcow2,size=$VM_DISK_SIZE,bus=virtio,format=qcow2" \
    --cdrom "$DEST_ISO" \
    --disk "path=$VIRTIO_ISO,device=cdrom" \
    --disk "path=$AUTOUNATTEND_ISO,device=cdrom" \
    --network network=default,model=virtio,mac="$VM_MAC" \
    --graphics vnc,listen=127.0.0.1,port=$VNC_PORT,password="$VNC_PASSWORD" \
    --boot hd,cdrom \
    --noautoconsole \
    --wait -1 &

VIRT_PID=$!
ok "VM creation started (PID: $VIRT_PID)"

# =============================================================================
# Step 8: Configure static DHCP lease
# =============================================================================
info "Configuring static IP: $VM_IP"
sudo virsh net-update default add ip-dhcp-host \
    "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" \
    --live --config 2>/dev/null || warn "DHCP lease may already exist"
ok "Static DHCP: $VM_MAC → $VM_IP"

# =============================================================================
# Step 9: Wait for Windows installation
# =============================================================================
echo ""
info "Windows Server 2022 Core is installing..."
info "This takes 15-25 minutes. You can monitor via VNC:"
echo ""
echo "  From your local machine:"
echo "    ssh -L 5900:localhost:5900 $(whoami)@$(hostname -I | awk '{print $1}')"
echo "    Then open VNC client → localhost:5900 (password: $VNC_PASSWORD)"
echo ""
info "Waiting for SSH to become available on $VM_IP:22..."

# Poll for SSH
TIMEOUT=1800  # 30 minutes
ELAPSED=0
INTERVAL=15
while [ $ELAPSED -lt $TIMEOUT ]; do
    if sshpass -p "$WIN_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "$WIN_USERNAME@$VM_IP" "echo ready" &>/dev/null; then
        break
    fi
    printf "\r  Waiting... %d/%ds" $ELAPSED $TIMEOUT
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "SSH did not become available within ${TIMEOUT}s"
    warn "Connect via VNC to check status, then run: ./manage.sh provision"
    exit 1
fi

ok "SSH is up! Windows Server Core installed successfully."

# =============================================================================
# Step 10: Provision Astroneer server
# =============================================================================
if [ "$SKIP_PROVISION" = true ]; then
    info "Skipping provisioning (--skip-provision)"
    info "Run later with: ./manage.sh provision"
else
    info "Provisioning Astroneer server via SSH..."
    "$SCRIPT_DIR/manage.sh" provision
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  VM:     $VM_NAME ($VM_IP)"
echo "  SSH:    ssh $WIN_USERNAME@$VM_IP"
echo "  Server: $ASTRO_PUBLIC_IP:$ASTRO_PORT"
echo ""
echo "  Next steps:"
echo "    1. Update playit.gg tunnel → Local Address: $VM_IP:$ASTRO_PORT"
echo "    2. Start server: ./manage.sh start-server"
echo "    3. (Optional) Migrate saves from old Docker setup"
echo ""

# Astroneer Dedicated Server VM

Automated [Astroneer](https://astroneer.space/) dedicated server running on a **Windows Server 2022 Core** VM (KVM/QEMU), managed entirely over SSH from a Linux host.

## Why a VM?

The [DedicatedRenderDistance](https://github.com/GalaxyBrainGames/Astroneer-DedicatedServerMods/releases) mod contains native UE4 code that crashes under Wine/Proton. A native Windows environment is required. This project automates the entire setup to be nearly as convenient as Docker.

## Architecture

```
Internet → playit.gg (host) → 192.168.122.100:23787 → Windows VM → Astroneer
                                                        ↑
                                               Server Core (no GUI)
                                               Managed via SSH
```

## Prerequisites

- Debian/Ubuntu host with CPU virtualization (VT-x/AMD-V)
- ~6GB free RAM (3GB for VM + host)
- ~50GB free disk
- A [Windows Server 2022 evaluation ISO](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022) (180-day trial, free)

## Quick Start

```bash
# 1. Clone and configure
git clone <this-repo> && cd Astroneer-VPS
cp .env.example .env
nano .env  # Set your playit.gg IP/port, server name, passwords, etc.

# 2. Download Windows Server 2022 ISO and place it:
#    /var/lib/libvirt/images/Win2022.iso

# 3. Run setup (installs KVM, creates VM, waits for SSH, installs Astroneer)
chmod +x setup.sh manage.sh
./setup.sh

# 4. Update playit.gg tunnel
#    Local Address → 192.168.122.100:23787

# 5. Start the server
./manage.sh start-server
```

The entire setup takes ~25 minutes (mostly Windows installing itself).

## Usage

```bash
./manage.sh start          # Boot the VM, wait for SSH
./manage.sh stop           # Graceful shutdown
./manage.sh restart        # Stop + start
./manage.sh status         # VM state, SSH, Astroneer port check
./manage.sh ssh            # Interactive SSH into the VM

./manage.sh start-server   # Start Astroneer inside the VM
./manage.sh stop-server    # Stop Astroneer inside the VM
./manage.sh update         # Update Astroneer via SteamCMD
./manage.sh logs           # Tail server logs (--lines=N, --follow)
./manage.sh provision      # (Re)install Astroneer server

./manage.sh copy-saves     # Migrate saves from old Docker setup
./manage.sh autostart on   # Start VM on host boot
./manage.sh destroy        # Delete VM permanently

# Global flags
./manage.sh --dry-run destroy   # Preview destructive actions
./manage.sh --version           # Print version
```

## Files

| File | Purpose |
|---|---|
| `.env.example` | Configuration template (copy to `.env`) |
| `setup.sh` | One-time: install KVM, create VM, provision |
| `manage.sh` | Daily: start/stop/ssh/status |
| `setup-astroneer.ps1` | Installs SteamCMD, Astroneer, mod, firewall |
| `lib/common.sh` | Shared: logging, colors, traps, lockfile |
| `lib/env.sh` | Configuration loader and validator |
| `lib/ssh.sh` | SSH/SCP helpers for VM communication |
| `lib/vm.sh` | VM lifecycle helpers (virsh wrappers) |
| `templates/autounattend.xml.tpl` | Unattended Windows install template |

## How It Works

1. **`setup.sh`** installs KVM, downloads VirtIO drivers, creates a VM with three CD-ROMs (Windows ISO, VirtIO drivers, autounattend config)
2. **`templates/autounattend.xml.tpl`** is a template that gets credentials substituted from `.env` at build time, then installs Windows Server 2022 Core (headless) with VirtIO drivers, creates the admin account, and installs + starts OpenSSH — all without user interaction
3. **`setup.sh`** polls SSH until it's available, then runs the provisioning step
4. **`setup-astroneer.ps1`** is copied in via SCP and run over SSH — it installs SteamCMD, the Astroneer server, the render distance mod, and configures the firewall

After setup, everything is managed through `manage.sh` which communicates via SSH. Shared logic lives in `lib/` to avoid duplication.

## Port Matching

The Astroneer server registers itself with the backend using `PublicIP:Port` from its config. **These must match what's publicly reachable** (your playit.gg allocation), otherwise the server appears offline to clients. Both `.env` and the server's `Engine.ini` are set to port `23787` by default.

## Migrating Saves

```bash
# From old Docker/Wine setup
./manage.sh copy-saves ~/services/astroneer/Saved/SaveGames
```

## Troubleshooting

**VM won't start:** `sudo systemctl status libvirtd` and `sudo virsh net-list --all`

**SSH not reachable:** The VM may still be installing Windows (check via VNC: `./manage.sh vnc`). Server Core takes 15-25 minutes on first boot.

**Astroneer port not responding:** `./manage.sh ssh` then check if `AstroServer.exe` is running (`Get-Process AstroServer`)

**playit.gg can't reach VM:** Test from host: `nc -vz 192.168.122.100 23787`

## Notes

- Windows Server 2022 evaluation expires after 180 days (can be extended with `slmgr /rearm`)
- Windows Update and Defender real-time scanning are disabled for performance
- VNC is available as emergency access but SSH is the primary interface
- The server auto-starts when the VM boots (via startup folder)
- Logs are written to `~/.local/log/astroneer-vps/` (configurable via `LOG_DIR` in `.env`)

## Development

Lint the shell scripts:

```bash
shellcheck lib/*.sh manage.sh setup.sh
```

The project includes a `.shellcheckrc` for consistent linting configuration.

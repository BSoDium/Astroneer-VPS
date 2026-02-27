# Astroneer Dedicated Server VM

Automated [Astroneer](https://astroneer.space/) dedicated server running on a **Windows Server 2022 Desktop Experience** VM (KVM/QEMU), managed entirely over SSH from a Linux host. Uses [AstroLauncher](https://github.com/JoeJoeTV/AstroLauncher) for process supervision, auto-restart, web UI, and save management. Public access via a [playit.gg](https://playit.gg/) tunnel.

## Architecture

```
Internet
  +-- playit.gg tunnel (host Docker container, --network host)
       +-- 192.168.122.100:<ASTRO_PORT> (libvirt NAT bridge)
            +-- Windows Server 2022 Desktop Experience VM (KVM)
                 +-- AstroLauncher (process supervisor, web UI, RCON)
                      +-- Astroneer Dedicated Server (SteamCMD app 728470)

Host filesystem (docker-style volumes):
  data/config/    <--sync-->  VM config files (Launcher.ini, AstroServerSettings.ini, Engine.ini)
  data/saves/     <--sync-->  VM save files
  data/mods/      <--sync-->  VM mod .pak files
  data/backups/   <---pull--  VM AstroLauncher backups

Management: Linux host --SSH--> VM (OpenSSH Server on Windows)
```

## Prerequisites

- Debian 12+ / Ubuntu 22.04+ host with CPU virtualization (VT-x / AMD-V enabled in BIOS)
- ~8 GB free RAM (4 GB for the VM + host overhead)
- ~50 GB free disk space
- A [Windows Server 2022 evaluation ISO](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022) (180-day trial, free -- select "ISO download, 64-bit edition")
- A [playit.gg](https://playit.gg/) account with a UDP tunnel configured

## Quick Start

```bash
# 1. Clone and configure
git clone <this-repo> && cd Astroneer-VPS
cp .env.example .env
nano .env   # Set VM settings, playit.gg IP/port, passwords

# 2. Download the Windows Server 2022 evaluation ISO and place it:
#    /var/lib/libvirt/images/Win2022.iso
#    (or pass --windows-iso=/path/to/your.iso to setup.sh)

# 3. Run setup (installs KVM, creates VM, installs Windows + Astroneer + AstroLauncher)
chmod +x setup.sh manage.sh
./setup.sh

# 4. Edit server configuration (generated during setup)
nano data/config/AstroServerSettings.ini   # Server name, owner, password
nano data/config/Launcher.ini              # Web UI, Discord, backups

# 5. Configure playit.gg tunnel (see "playit.gg Setup" below)

# 6. Start the server
./manage.sh start-server
```

The full setup takes 30-50 minutes (mostly Windows installing itself).

## Configuration

Configuration is split into two layers:

### VM infrastructure (`.env`)

Controls the VM itself -- resources, networking, and Windows credentials. Edit before running `setup.sh`.

```bash
cp .env.example .env
nano .env
```

| Variable | Description | Default |
|---|---|---|
| `VM_NAME` | libvirt VM name | `astroneer-win` |
| `VM_RAM` | VM memory in MB | `4096` |
| `VM_CPUS` | VM CPU cores | `2` |
| `VM_DISK_SIZE` | VM disk size in GB | `40` |
| `VM_IP` | Static IP on libvirt NAT network | `192.168.122.100` |
| `VNC_PORT` | VNC port for emergency GUI access | `5900` |
| `VNC_PASSWORD` | VNC password | **change this** |
| `WIN_USERNAME` | Windows admin account | `astro` |
| `WIN_PASSWORD` | Windows admin password | **change this** |
| `ASTRO_PORT` | Astroneer server port (UDP) | `23787` |
| `ASTRO_PUBLIC_IP` | Your playit.gg allocated public IP | `0.0.0.0` |
| `ASTRO_LAUNCHER_PORT` | AstroLauncher web UI port (TCP) | `5000` |
| `IMAGES_DIR` | Where VM disk and ISOs are stored | `/var/lib/libvirt/images` |

### Server configuration (`data/config/`)

Controls the Astroneer server and AstroLauncher. Edit these files directly -- they are synced to the VM on `start-server` and pulled back on `stop-server`.

**`data/config/AstroServerSettings.ini`** -- Game server settings:
- Server name, owner, max players
- Server password
- Public IP, auto-save interval
- Player timeout, whitelist mode

**`data/config/Engine.ini`** -- UE4 engine settings:
- Server port (must match `ASTRO_PORT` in `.env`)
- Encryption settings

**`data/config/Launcher.ini`** -- AstroLauncher settings:
- Web UI port and password
- Auto-update behavior
- Discord webhook integration
- Backup retention
- Auto-restart schedule

These files are generated with defaults during `./manage.sh install` and seeded to `data/config/`. Edit them on the host, then `start-server` pushes changes to the VM.

## Data Directories

Server data is managed through host-side directories, similar to Docker volumes:

```
data/
+-- config/    # .ini config files (edit on host, synced to VM)
+-- saves/     # .savegame files (drop in before start-server)
+-- mods/      # .pak mod files (drop in before start-server)
+-- backups/   # AstroLauncher auto-backups (pulled on stop-server)
```

**Sync behavior:**
- `start-server` pushes `config/`, `saves/`, `mods/` to the VM
- `stop-server` pulls `config/`, `saves/`, `backups/` from the VM
- `sync` can be run manually for on-demand sync

### Uploading save files

Drop `.savegame` files into `data/saves/`, then start (or restart) the server:

```bash
cp ~/SaveGames/*.savegame data/saves/
./manage.sh start-server
```

Common save file locations:
- **Linux (Steam):** `~/.local/share/Steam/steamapps/common/ASTRONEER/Astro/Saved/SaveGames`
- **Windows:** `%LOCALAPPDATA%\Astro\Saved\SaveGames`

### Installing mods

Drop `.pak` files into `data/mods/`, then start (or restart) the server:

```bash
cp MyMod_P.pak data/mods/
./manage.sh start-server
```

## playit.gg Setup

[playit.gg](https://playit.gg/) provides a public IP and port that tunnels traffic to your server. This is required unless your host has a public IP with port forwarding.

1. Create a playit.gg account and set up a **UDP tunnel**
2. Note the **allocated public IP and port** (e.g., `69.9.185.17:1048`)
3. Set these in `.env`:
   ```
   ASTRO_PORT=1048              # Must match the playit.gg allocated port
   ASTRO_PUBLIC_IP=69.9.185.17  # Your playit.gg allocated IP
   ```
4. Set the tunnel's **Local Address** in the playit.gg dashboard to point at the VM:
   ```
   192.168.122.100:<ASTRO_PORT>
   ```
5. Also set `PublicIP` in `data/config/AstroServerSettings.ini` to match

**Important:** The `ASTRO_PORT` in `.env` must exactly match the port allocated by playit.gg *and* the port in `Engine.ini`. The server registers with the Astroneer backend using `PublicIP:Port` -- if they don't match, the server appears offline in the game's server browser.

### Running playit.gg as a Docker container

```bash
docker run -d --name playit --network host --restart unless-stopped \
  -v playit-data:/etc/playit \
  ghcr.io/playit-cloud/playit-agent
```

On first run, check logs for the claim URL: `docker logs playit`

## AstroLauncher Web UI

AstroLauncher provides a web-based management interface. After starting the server:

```
http://<VM_IP>:5000
```

Port forwarding is set up automatically so you can also access it from the host at `http://localhost:5000`.

On first access, you'll be prompted to set a password. Features include:
- Server status and player list
- Save game management
- Server restart controls
- Configuration editing
- Discord webhook setup

## Usage

```bash
# VM lifecycle
./manage.sh start          # Boot the VM, wait for SSH, set up port forwarding
./manage.sh stop           # Graceful shutdown
./manage.sh restart        # Stop + start
./manage.sh status         # VM state, SSH, Astroneer, AstroLauncher status
./manage.sh autostart on   # Auto-start VM on host boot

# Server management
./manage.sh install        # One-time: install Astroneer + AstroLauncher in VM
./manage.sh start-server   # Sync data to VM, start AstroLauncher + Astroneer
./manage.sh stop-server    # Stop server, sync data back to host
./manage.sh sync           # Manual sync [to|from|both]
./manage.sh logs           # Tail logs [--lines=N] [--follow] [--server|--launcher]

# Access
./manage.sh ssh            # Interactive SSH session to the VM
./manage.sh vnc            # Show VNC connection instructions

# Dangerous
./manage.sh destroy        # Delete VM and its disk (permanent!)

# Flags
./manage.sh --dry-run <cmd>  # Preview destructive actions
./manage.sh --version        # Print version
```

## Files

| File | Purpose |
|---|---|
| `.env.example` | Configuration template (copy to `.env`) |
| `setup.sh` | One-time: install KVM, create VM, install server |
| `manage.sh` | Daily: start/stop/status/ssh/sync/logs |
| `setup-astroneer.ps1` | PowerShell: SteamCMD, Astroneer, AstroLauncher, firewall |
| `lib/common.sh` | Shared: logging, colors, traps, constants |
| `lib/env.sh` | Configuration loader and validator |
| `lib/ssh.sh` | SSH/SCP helpers + data sync functions |
| `lib/vm.sh` | VM lifecycle helpers (virsh wrappers) |
| `templates/autounattend.xml.tpl` | Unattended Windows install template |
| `data/config/` | Server config files (synced to VM) |
| `data/saves/` | Save files (synced to VM) |
| `data/mods/` | Mod .pak files (synced to VM) |
| `data/backups/` | AstroLauncher backups (pulled from VM) |

## How It Works

1. **`setup.sh`** installs KVM packages, downloads VirtIO drivers, and creates a VM with three CD-ROMs (Windows ISO, VirtIO drivers, autounattend config)
2. **`autounattend.xml.tpl`** drives the unattended Windows install -- it installs Desktop Experience edition with VirtIO drivers, creates the admin account, installs OpenSSH Server, and disables Windows Update/Defender for performance
3. **`setup.sh`** polls SSH until Windows is ready (~30-45 min), then calls `manage.sh install`
4. **`setup-astroneer.ps1`** is copied via SCP and run over SSH -- installs SteamCMD, the Astroneer dedicated server, AstroLauncher, and configures the firewall
5. Default configuration files are pulled from the VM to `data/config/` for host-side editing
6. **`manage.sh start-server`** syncs data from `data/` to the VM, then launches AstroLauncher (which manages AstroServer.exe, handles updates, backups, and auto-restart)
7. **`manage.sh stop-server`** stops everything and syncs saves/config/backups back to the host
8. Port forwarding via iptables DNAT routes UDP game traffic and TCP web UI traffic from host to VM

## Troubleshooting

**VM won't start:** Check libvirtd and the default network:
```bash
sudo systemctl status libvirtd
sudo virsh net-list --all
```

**SSH not reachable:** Windows Desktop Experience takes 30-45 minutes to install. Check via VNC: `./manage.sh vnc`

**Server installed but not responding:** Check process status and launcher logs:
```bash
./manage.sh status
./manage.sh logs              # AstroLauncher logs (default)
./manage.sh logs --server     # Astroneer server logs
```

**Server visible in game but says "offline":** Ensure these all match:
- `ASTRO_PORT` and `ASTRO_PUBLIC_IP` in `.env`
- `PublicIP` in `data/config/AstroServerSettings.ini`
- Port in `data/config/Engine.ini`
- playit.gg tunnel allocation

Re-sync and restart:
```bash
./manage.sh stop-server
./manage.sh start-server
```

**playit.gg can't reach the VM:** Verify the tunnel's Local Address is set to `192.168.122.100:<ASTRO_PORT>` (not `127.0.0.1`).

**Config changes not taking effect:** Ensure you edit `data/config/` files on the host, then `start-server` or `sync to` to push changes:
```bash
./manage.sh sync to
```

**AstroLauncher web UI not accessible:** Check the port forward is active (`./manage.sh status`) and that `ASTRO_LAUNCHER_PORT` in `.env` matches `WebServerPort` in `data/config/Launcher.ini`.

## Notes

- Windows Server 2022 evaluation expires after 180 days -- extend with `slmgr /rearm` (up to 3 times)
- Windows Update and Defender real-time scanning are disabled for performance
- VNC is available as emergency GUI access but SSH is the primary interface
- AstroLauncher auto-updates both itself and the Astroneer server by default (configurable in Launcher.ini)
- The VM uses a static DHCP lease on the libvirt default NAT network (`192.168.122.x`)
- Astroneer uses **UDP** (not TCP) for game traffic
- Logs are written to `~/.local/log/astroneer-vps/` (configurable via `LOG_DIR` in `.env`)

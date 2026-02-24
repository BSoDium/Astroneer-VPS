# =============================================================================
# setup-astroneer.ps1 — Install Astroneer Dedicated Server + mods
# Run inside the Windows Server VM via SSH:
#   powershell.exe -ExecutionPolicy Bypass -File C:\setup\setup-astroneer.ps1
# =============================================================================

param(
    [string]$InstallPath = "C:\AstroneerServer",
    [int]$ServerPort = 23787,
    [string]$ServerName = "Vertex",
    [string]$OwnerName = "BSoDium",
    [string]$PublicIP = "147.185.221.181"
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }

# --- 1. SteamCMD ---
Write-Step "Installing SteamCMD"
$steamDir = "C:\steamcmd"
if (!(Test-Path "$steamDir\steamcmd.exe")) {
    New-Item -ItemType Directory -Path $steamDir -Force | Out-Null
    $zip = "$env:TEMP\steamcmd.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $steamDir -Force
    Remove-Item $zip
}
Write-Host "SteamCMD ready at $steamDir"

# --- 2. Install Astroneer Dedicated Server ---
Write-Step "Installing Astroneer Dedicated Server (app 728470)"
& "$steamDir\steamcmd.exe" +force_install_dir $InstallPath +login anonymous +app_update 728470 validate +quit
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 7) {
    Write-Warning "SteamCMD exited with code $LASTEXITCODE (may be OK)"
}

# --- 3. UE4 Prerequisites ---
Write-Step "Installing UE4 prerequisites"
$prereq = Get-ChildItem -Path $InstallPath -Recurse -Filter "UE4PrereqSetup_x64.exe" | Select-Object -First 1
if ($prereq) {
    Start-Process -FilePath $prereq.FullName -ArgumentList "/quiet /norestart" -Wait -NoNewWindow
    Write-Host "Prerequisites installed"
} else {
    Write-Warning "UE4PrereqSetup_x64.exe not found — may not be needed"
}

# --- 4. Generate default config ---
Write-Step "Generating default config files"
$serverExe = Join-Path $InstallPath "AstroServer.exe"
$savedDir = Join-Path $InstallPath "Astro\Saved"

if (!(Test-Path (Join-Path $savedDir "Config\WindowsServer\AstroServerSettings.ini"))) {
    Write-Host "Starting server briefly to generate configs..."
    $proc = Start-Process -FilePath $serverExe -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 20
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "Config files generated"
} else {
    Write-Host "Config files already exist"
}

# --- 5. Configure Engine.ini ---
Write-Step "Configuring Engine.ini"
$engineDir = Join-Path $savedDir "Config\WindowsServer"
$engineIni = Join-Path $engineDir "Engine.ini"
New-Item -ItemType Directory -Path $engineDir -Force | Out-Null

@"
[URL]
Port=$ServerPort

[SystemSettings]
net.AllowEncryption=True
"@ | Set-Content -Path $engineIni -Encoding UTF8
Write-Host "Engine.ini written (Port=$ServerPort)"

# --- 6. Configure AstroServerSettings.ini ---
Write-Step "Configuring AstroServerSettings.ini"
$settingsIni = Join-Path $engineDir "AstroServerSettings.ini"

@"
[/Script/Astro.AstroServerSettings]
bLoadAutoSave=True
MaxServerFramerate=30
MaxServerIdleFramerate=3
bWaitForPlayersBeforeShutdown=False
PublicIP=$PublicIP
ServerName=$ServerName
MaximumPlayerCount=8
OwnerName=$OwnerName
OwnerGuid=
PlayerActivityTimeout=0
ServerPassword=
bDisableServerTravel=False
DenyUnlistedPlayers=False
VerbosePlayerProperties=True
AutoSaveGameInterval=900
BackupSaveGamesInterval=7200
ServerGuid=
ActiveSaveFileDescriptiveName=YOURSERVERNAME
ServerAdvertisedAsLAN=False
ConsolePort=1234
"@ | Set-Content -Path $settingsIni -Encoding UTF8
Write-Host "Server settings written (Name=$ServerName, Owner=$OwnerName, IP=$PublicIP)"

# --- 7. Install DedicatedRenderDistance mod ---
Write-Step "Installing DedicatedRenderDistance mod"
$paksDir = Join-Path $InstallPath "Astro\Content\Paks"
New-Item -ItemType Directory -Path $paksDir -Force | Out-Null
$modUrl = "https://github.com/GalaxyBrainGames/Astroneer-DedicatedServerMods/releases/download/v2.0/DedicatedRenderDistance_P.pak"
$modPath = Join-Path $paksDir "DedicatedRenderDistance_P.pak"
Invoke-WebRequest -Uri $modUrl -OutFile $modPath
Write-Host "Mod installed: $modPath"

# --- 8. Firewall rules ---
Write-Step "Configuring Windows Firewall"
$rules = @(
    @{ Name = "Astroneer-TCP"; Protocol = "TCP" },
    @{ Name = "Astroneer-UDP"; Protocol = "UDP" }
)
foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($existing) { Remove-NetFirewallRule -Name $rule.Name }
    New-NetFirewallRule `
        -Name $rule.Name `
        -DisplayName "Astroneer Server ($($rule.Protocol))" `
        -Direction Inbound `
        -Protocol $rule.Protocol `
        -LocalPort $ServerPort `
        -Action Allow `
        -Enabled True | Out-Null
    Write-Host "Firewall: $($rule.Name) → port $ServerPort"
}

# --- 9. Create start script ---
Write-Step "Creating start script"
$startBat = "C:\start-astroneer.bat"
@"
@echo off
echo Updating Astroneer server...
C:\steamcmd\steamcmd.exe +force_install_dir $InstallPath +login anonymous +app_update 728470 +quit
echo Starting server...
cd /d $InstallPath
AstroServer.exe
"@ | Set-Content -Path $startBat -Encoding ASCII
Write-Host "Created $startBat"

# --- 10. Auto-start on login ---
Write-Step "Setting up auto-start"
$startupDir = "C:\Users\astro\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
Copy-Item -Path $startBat -Destination (Join-Path $startupDir "start-astroneer.bat") -Force
Write-Host "Server will auto-start on login"

# --- Done ---
Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Green
Write-Host " Astroneer server installed successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Server:  $ServerName"
Write-Host "  Port:    $ServerPort"
Write-Host "  Public:  ${PublicIP}:${ServerPort}"
Write-Host "  Mod:     DedicatedRenderDistance v2.0"
Write-Host ""
Write-Host "Start now with: C:\start-astroneer.bat"
Write-Host ""

Write-Host ""
Write-Host "Start the server with: C:\start-astroneer.bat"
Write-Host "Or from the host:      ./manage.sh start-server"
Write-Host ""

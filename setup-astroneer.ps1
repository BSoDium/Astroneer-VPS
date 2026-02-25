# =============================================================================
# setup-astroneer.ps1 — Install Astroneer Dedicated Server + mods
# Run inside the Windows Server VM via SSH:
#   powershell.exe -ExecutionPolicy Bypass -File C:\setup-astroneer.ps1
# =============================================================================

param(
    [string]$InstallPath = "C:\AstroneerServer",
    [int]$ServerPort = 23787,
    [int]$ConsolePort = 1234,
    [string]$ServerName = "My Server",
    [string]$OwnerName = "YourName",
    [string]$PublicIP = "0.0.0.0"
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }

# Retry wrapper for network operations
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            & $Action
            return
        } catch {
            if ($i -eq $MaxAttempts) { throw }
            Write-Warning "Attempt $i/$MaxAttempts failed: $_. Retrying in ${DelaySeconds}s..."
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds *= 2
        }
    }
}

# --- 1. SteamCMD ---
Write-Step "Installing SteamCMD"
$steamDir = "C:\steamcmd"
if (!(Test-Path "$steamDir\steamcmd.exe")) {
    New-Item -ItemType Directory -Path $steamDir -Force | Out-Null
    $zip = "$env:TEMP\steamcmd.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WithRetry { Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $zip }
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
ActiveSaveFileDescriptiveName=$ServerName
ServerAdvertisedAsLAN=False
ConsolePort=$ConsolePort
"@ | Set-Content -Path $settingsIni -Encoding UTF8
Write-Host "Server settings written (Name=$ServerName, Owner=$OwnerName, IP=$PublicIP)"

# --- 7. Install DedicatedRenderDistance mod ---
Write-Step "Installing DedicatedRenderDistance mod"
$paksDir = Join-Path $InstallPath "Astro\Content\Paks"
New-Item -ItemType Directory -Path $paksDir -Force | Out-Null
$modUrl = "https://github.com/GalaxyBrainGames/Astroneer-DedicatedServerMods/releases/download/v2.0/DedicatedRenderDistance_P.pak"
$modPath = Join-Path $paksDir "DedicatedRenderDistance_P.pak"
if (!(Test-Path $modPath)) {
    Invoke-WithRetry { Invoke-WebRequest -Uri $modUrl -OutFile $modPath }
} else {
    Write-Host "Mod already installed"
}
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
$startupDir = [Environment]::GetFolderPath('Startup')
if ([string]::IsNullOrEmpty($startupDir)) {
    $startupDir = "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
}
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
Write-Host "  Start:   C:\start-astroneer.bat (or ./manage.sh start-server from host)"
Write-Host ""

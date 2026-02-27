# =============================================================================
# setup-astroneer.ps1 - Install Astroneer Dedicated Server + AstroLauncher
# Run inside the Windows Server VM via SSH:
#   powershell.exe -ExecutionPolicy Bypass -File C:\setup-astroneer.ps1
# =============================================================================

param(
    [string]$InstallPath = "C:\AstroneerServer",
    [int]$ServerPort = 23787,
    [int]$LauncherPort = 5000
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
# SteamCMD has a multi-stage self-update: the first run downloads an update,
# then the second run may download yet another update. Each restart loses any
# +app_update arguments. Loop +quit until it stabilises, then install the game.
Write-Host "Warming up SteamCMD (may self-update several times)..."
for ($warmup = 1; $warmup -le 5; $warmup++) {
    Write-Host "  SteamCMD warm-up pass $warmup..."
    & "$steamDir\steamcmd.exe" +quit
    # If exit code is 0, SteamCMD is stable (no more updates)
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
}

# Retry the actual install -- SteamCMD occasionally still fails on the first
# real invocation after updates with "Missing configuration".
$installed = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "Install attempt $attempt/3..."
    & "$steamDir\steamcmd.exe" +force_install_dir $InstallPath +login anonymous +app_update 728470 validate +quit
    if (Test-Path (Join-Path $InstallPath "AstroServer.exe")) {
        $installed = $true
        break
    }
    Write-Warning "AstroServer.exe not found after attempt $attempt, retrying..."
    Start-Sleep -Seconds 5
}
if (-not $installed) {
    throw "AstroServer.exe not found after 3 install attempts - SteamCMD may have failed"
}

# --- 3. UE4 Prerequisites ---
Write-Step "Installing UE4 prerequisites"
$prereq = Get-ChildItem -Path $InstallPath -Recurse -Filter "UE4PrereqSetup_x64.exe" | Select-Object -First 1
if ($prereq) {
    Start-Process -FilePath $prereq.FullName -ArgumentList "/quiet /norestart" -Wait -NoNewWindow
    Write-Host "Prerequisites installed"
} else {
    Write-Warning "UE4PrereqSetup_x64.exe not found - may not be needed"
}

# --- 4. Generate default config files ---
Write-Step "Generating default config files"
$serverExe = Join-Path $InstallPath "AstroServer.exe"
$settingsIni = Join-Path $InstallPath "Astro\Saved\Config\WindowsServer\AstroServerSettings.ini"

if (!(Test-Path $settingsIni)) {
    Write-Host "Starting server briefly to generate configs..."
    $proc = Start-Process -FilePath $serverExe -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 20
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "Config files generated"
} else {
    Write-Host "Config files already exist"
}

# --- 5. Download AstroLauncher ---
Write-Step "Downloading AstroLauncher"
$launcherUrl = "https://github.com/JoeJoeTV/AstroLauncher/releases/download/1.8.5.1/AstroLauncher.exe"
$launcherExe = Join-Path $InstallPath "AstroLauncher.exe"
if (!(Test-Path $launcherExe)) {
    Invoke-WithRetry { Invoke-WebRequest -Uri $launcherUrl -OutFile $launcherExe }
    Write-Host "AstroLauncher downloaded"
} else {
    Write-Host "AstroLauncher already installed"
}

# --- 6. Write seed Launcher.ini ---
Write-Step "Writing default Launcher.ini"
$launcherIni = Join-Path $InstallPath "Launcher.ini"
if (!(Test-Path $launcherIni)) {
    @"
[AstroLauncher]
AutoUpdateLauncherSoftware = True
AutoUpdateServerSoftware = True
DisableNetworkCheck = False
DisableBackupRetention = False
BackupRetentionPeriodHours = 72
OverwritePublicIP = False
ShowServerFPSInConsole = True
AdminAutoConfigureFirewall = True
DisableWebServer = False
WebServerPort = $LauncherPort
EnableAutoRestart = False
AutoRestartEveryHours = 24
LogRetentionDays = 7
"@ | Set-Content -Path $launcherIni -Encoding UTF8
    Write-Host "Launcher.ini written (WebServerPort=$LauncherPort)"
} else {
    Write-Host "Launcher.ini already exists"
}

# --- 7. Firewall rules ---
Write-Step "Configuring Windows Firewall"
$rules = @(
    @{ Name = "Astroneer-TCP"; Protocol = "TCP"; Port = $ServerPort },
    @{ Name = "Astroneer-UDP"; Protocol = "UDP"; Port = $ServerPort },
    @{ Name = "AstroLauncher-WebUI"; Protocol = "TCP"; Port = $LauncherPort }
)
foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($existing) { Remove-NetFirewallRule -Name $rule.Name }
    New-NetFirewallRule `
        -Name $rule.Name `
        -DisplayName "Astroneer Server ($($rule.Protocol) $($rule.Port))" `
        -Direction Inbound `
        -Protocol $rule.Protocol `
        -LocalPort $rule.Port `
        -Action Allow `
        -Enabled True | Out-Null
    Write-Host "Firewall: $($rule.Name) -> port $($rule.Port)"
}

# --- 8. Create start script ---
Write-Step "Creating start script"
$startBat = "C:\start-astroneer.bat"
@"
@echo off
echo Starting AstroLauncher (manages server updates + startup)...
cd /d $InstallPath
AstroLauncher.exe
"@ | Set-Content -Path $startBat -Encoding ASCII
Write-Host "Created $startBat"

# --- 9. Auto-start on login ---
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
Write-Host " Astroneer + AstroLauncher installed!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Port:     $ServerPort (UDP)"
Write-Host "  Web UI:   http://localhost:$LauncherPort"
Write-Host ""
Write-Host "  Config files will be synced from host data/ directory."
Write-Host "  Start with: ./manage.sh start-server (from host)"
Write-Host ""

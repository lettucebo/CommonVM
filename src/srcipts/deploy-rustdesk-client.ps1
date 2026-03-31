<#
.SYNOPSIS
    Deploy and configure RustDesk client (portable) with self-hosted server settings.

.DESCRIPTION
    Downloads RustDesk portable EXE, places it in a local folder,
    writes the server configuration, and launches it. No installation required.

.PARAMETER ServerIP
    The public IP or domain of your RustDesk self-hosted server (hbbs/hbbr).

.PARAMETER Key
    The public key from your RustDesk server (id_ed25519.pub).

.PARAMETER RelayServer
    The relay server address. Defaults to the same as ServerIP.

.PARAMETER Version
    RustDesk version to download. Defaults to 'latest' (auto-resolved from GitHub).

.PARAMETER Architecture
    EXE architecture. Defaults to x86_64.

.PARAMETER InstallDir
    Directory to place the portable EXE. Defaults to C:\RustDesk.

.EXAMPLE
    .\deploy-rustdesk-client.ps1 -ServerIP "203.0.113.10" -Key "ITsuw4tzu39v..."

.EXAMPLE
    .\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "abc123..." -Version "1.3.9"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Public IP or domain of your RustDesk server")]
    [string]$ServerIP,

    [Parameter(Mandatory = $true, HelpMessage = "Public key from server (id_ed25519.pub)")]
    [string]$Key,

    [Parameter(Mandatory = $false, HelpMessage = "Relay server address (defaults to ServerIP)")]
    [string]$RelayServer,

    [Parameter(Mandatory = $false, HelpMessage = "RustDesk version to download (e.g. 1.3.9 or 'latest')")]
    [string]$Version = "latest",

    [Parameter(Mandatory = $false, HelpMessage = "EXE architecture")]
    [ValidateSet("x86_64", "x86")]
    [string]$Architecture = "x86_64",

    [Parameter(Mandatory = $false, HelpMessage = "Directory to place the portable EXE")]
    [string]$InstallDir = "C:\RustDesk"
)

$ErrorActionPreference = "Stop"

if (-not $RelayServer) {
    $RelayServer = $ServerIP
}

# Disable progress bar to speed up Invoke-WebRequest
$ProgressPreference = 'SilentlyContinue'

# Resolve "latest" to actual version number
if ($Version -eq "latest") {
    Write-Host "Resolving latest RustDesk version..." -ForegroundColor Cyan
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" -UseBasicParsing
    $Version = $release.tag_name
    Write-Host "      Latest version: $Version" -ForegroundColor Green
}

$exeUrl = "https://github.com/rustdesk/rustdesk/releases/download/$Version/rustdesk-$Version-$Architecture.exe"
$rustdesk = Join-Path $InstallDir "rustdesk.exe"

# 1. Download
Write-Host "[1/3] Downloading RustDesk $Version ($Architecture)..." -ForegroundColor Cyan
Write-Host "      URL: $exeUrl"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Invoke-WebRequest -Uri $exeUrl -OutFile $rustdesk -UseBasicParsing

if (-not (Test-Path $rustdesk)) {
    Write-Error "Download failed: $rustdesk not found"
    exit 1
}

Write-Host "      Saved to: $rustdesk" -ForegroundColor Green

# 2. Write config
Write-Host "[2/3] Writing server configuration..." -ForegroundColor Cyan
Write-Host "      ID Server:    $ServerIP"
Write-Host "      Relay Server: $RelayServer"
Write-Host "      Key:          $($Key.Substring(0, [Math]::Min(8, $Key.Length)))..."

$configContent = @"
rendezvous_server = '$($ServerIP):21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
custom-rendezvous-server = '$ServerIP'
relay-server = '$RelayServer'
key = '$Key'
"@

# Write to %APPDATA% (normal mode)
$appDataConfigDir = Join-Path $env:APPDATA "RustDesk\config"
New-Item -ItemType Directory -Force -Path $appDataConfigDir | Out-Null
Set-Content -Path (Join-Path $appDataConfigDir "RustDesk2.toml") -Value $configContent -Encoding UTF8
Write-Host "      Config written to: $appDataConfigDir" -ForegroundColor Green

# 3. Launch
Write-Host "[3/3] Launching RustDesk..." -ForegroundColor Cyan
Start-Process -FilePath $rustdesk
Write-Host "      RustDesk started" -ForegroundColor Green

Write-Host ""
Write-Host "RustDesk deployment complete!" -ForegroundColor Green
Write-Host "EXE:    $rustdesk" -ForegroundColor Yellow
Write-Host "Config: $appDataConfigDir\RustDesk2.toml" -ForegroundColor Yellow

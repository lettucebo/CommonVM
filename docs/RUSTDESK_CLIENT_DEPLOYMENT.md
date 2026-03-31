# RustDesk Client Deployment Guide

Automated scripts to deploy and configure the RustDesk client to connect to your self-hosted RustDesk server.

## Prerequisites

Before running the deployment scripts, you need:

1. **Server public key** — Obtain from the VM:
   ```bash
   cat /mnt/data/rustdesk/data/id_ed25519.pub
   ```
2. **Server address** — Your VM's public IP or DNS name (e.g., `rustdesk.example.com`)

## Windows

### Requirements

- PowerShell 5.1+
- Internet access (to download RustDesk EXE from GitHub)

### Usage

```powershell
# Allow script execution (current session only)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Run deployment
.\deploy-rustdesk-client.ps1 -ServerIP "<SERVER_ADDRESS>" -Key "<PUBLIC_KEY>"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ServerIP` | Yes | — | Public IP or domain of your RustDesk server |
| `-Key` | Yes | — | Public key from server (`id_ed25519.pub`) |
| `-RelayServer` | No | Same as ServerIP | Relay server address |
| `-Version` | No | `latest` | RustDesk version (e.g., `1.3.9` or `latest`) |
| `-Architecture` | No | `x86_64` | EXE architecture (`x86_64` or `x86`) |
| `-InstallDir` | No | `C:\RustDesk` | Directory to place the EXE |

### Examples

```powershell
# Auto-detect latest version
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..."

# Specific version
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..." -Version "1.3.9"

# Custom install directory
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..." -InstallDir "D:\Tools\RustDesk"
```

### What it does

1. Resolves the latest RustDesk version from GitHub (if `latest`)
2. Downloads the EXE to `C:\RustDesk\`
3. Writes server config to `%APPDATA%\RustDesk\config\RustDesk2.toml`
4. Launches RustDesk

---

## macOS

### Requirements

- [Homebrew](https://brew.sh) installed
- Internet access

### Usage

```bash
chmod +x deploy-rustdesk-client.sh
./deploy-rustdesk-client.sh -s "<SERVER_ADDRESS>" -k "<PUBLIC_KEY>"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-s` | Yes | — | Public IP or domain of your RustDesk server |
| `-k` | Yes | — | Public key from server (`id_ed25519.pub`) |
| `-r` | No | Same as `-s` | Relay server address |

### Examples

```bash
# Basic usage
./deploy-rustdesk-client.sh -s "rustdesk.example.com" -k "ITsuw4tzu39v..."

# With separate relay server
./deploy-rustdesk-client.sh -s "rustdesk.example.com" -k "ITsuw4tzu39v..." -r "relay.example.com"
```

### What it does

1. Checks Homebrew is installed
2. Installs RustDesk via `brew install --cask rustdesk`
3. Writes server config to `~/Library/Preferences/RustDesk/config/RustDesk2.toml`

### macOS Permissions (Manual Step)

On first launch, macOS requires you to manually grant permissions:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**
2. Enable **RustDesk**
3. Go to **Screen Recording** and enable **RustDesk**

> These permissions cannot be automated due to macOS security restrictions.

---

## Verify Connection

After deployment, open RustDesk and check:

1. The ID number is displayed (top-left)
2. Status shows **Ready** (not "Not ready, please check your connection")
3. Settings > Network > ID/Relay Server shows the correct server address and key

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Not ready" on Windows | Close and reopen RustDesk (double-click the EXE, don't use `--portable`) |
| "Not ready" on macOS | Run `open /Applications/RustDesk.app` after granting permissions |
| Download slow (Windows) | The script already disables the PowerShell progress bar to fix this |
| Connection timeout | Verify Azure NSG has TCP 21114-21119 and UDP 21116 open |

# RustDesk 用戶端部署指南

自動化腳本，用於部署和設定 RustDesk 用戶端，連線到自架的 RustDesk 伺服器。

## 前置需求

執行部署腳本前，你需要：

1. **伺服器公鑰** — 從 VM 上取得：
   ```bash
   cat /mnt/data/rustdesk/data/id_ed25519.pub
   ```
2. **伺服器位址** — VM 的 Public IP 或 DNS 名稱（例如 `rustdesk.example.com`）

## Windows

### 系統需求

- PowerShell 5.1+
- 網路連線（從 GitHub 下載 RustDesk EXE）

### 使用方式

```powershell
# 允許執行腳本（僅限當前 session）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 執行部署
.\deploy-rustdesk-client.ps1 -ServerIP "<伺服器位址>" -Key "<公鑰>"
```

### 參數

| 參數 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `-ServerIP` | 是 | — | RustDesk 伺服器的 Public IP 或網域 |
| `-Key` | 是 | — | 伺服器公鑰（`id_ed25519.pub`） |
| `-RelayServer` | 否 | 同 ServerIP | Relay 伺服器位址 |
| `-Version` | 否 | `latest` | RustDesk 版本（例如 `1.3.9` 或 `latest`） |
| `-Architecture` | 否 | `x86_64` | EXE 架構（`x86_64` 或 `x86`） |
| `-InstallDir` | 否 | `C:\RustDesk` | EXE 存放目錄 |

### 範例

```powershell
# 自動偵測最新版本
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..."

# 指定版本
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..." -Version "1.3.9"

# 自訂安裝目錄
.\deploy-rustdesk-client.ps1 -ServerIP "rustdesk.example.com" -Key "ITsuw4tzu39v..." -InstallDir "D:\Tools\RustDesk"
```

### 腳本執行內容

1. 從 GitHub 解析最新 RustDesk 版本（如使用 `latest`）
2. 下載 EXE 到 `C:\RustDesk\`
3. 寫入伺服器設定到 `%APPDATA%\RustDesk\config\RustDesk2.toml`
4. 啟動 RustDesk

---

## macOS

### 系統需求

- 已安裝 [Homebrew](https://brew.sh)
- 網路連線

### 使用方式

```bash
chmod +x deploy-rustdesk-client.sh
./deploy-rustdesk-client.sh -s "<伺服器位址>" -k "<公鑰>"
```

### 參數

| 參數 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `-s` | 是 | — | RustDesk 伺服器的 Public IP 或網域 |
| `-k` | 是 | — | 伺服器公鑰（`id_ed25519.pub`） |
| `-r` | 否 | 同 `-s` | Relay 伺服器位址 |

### 範例

```bash
# 基本使用
./deploy-rustdesk-client.sh -s "rustdesk.example.com" -k "ITsuw4tzu39v..."

# 指定不同的 Relay 伺服器
./deploy-rustdesk-client.sh -s "rustdesk.example.com" -k "ITsuw4tzu39v..." -r "relay.example.com"
```

### 腳本執行內容

1. 確認 Homebrew 已安裝
2. 透過 `brew install --cask rustdesk` 安裝 RustDesk
3. 寫入伺服器設定到 `~/Library/Preferences/RustDesk/config/RustDesk2.toml`

### macOS 權限設定（需手動操作）

首次啟動時，macOS 需要手動授權：

1. 開啟**系統設定** > **隱私與安全性** > **輔助使用**
2. 啟用 **RustDesk**
3. 前往**螢幕錄製**，啟用 **RustDesk**

> 由於 macOS 安全限制，這些權限無法自動化授權。

---

## 驗證連線

部署完成後，開啟 RustDesk 確認：

1. 左上角顯示 **ID 號碼**
2. 狀態顯示 **Ready**（不是「Not ready, please check your connection」）
3. 設定 > Network > ID/Relay Server 顯示正確的伺服器位址和公鑰

## 疑難排解

| 問題 | 解決方式 |
|------|----------|
| Windows 顯示「Not ready」 | 關閉 RustDesk 後重新雙擊 EXE 開啟（不要使用 `--portable`） |
| macOS 顯示「Not ready」 | 授權權限後執行 `open /Applications/RustDesk.app` |
| Windows 下載速度慢 | 腳本已自動關閉 PowerShell 進度條來解決此問題 |
| 連線逾時 | 確認 Azure NSG 已開放 TCP 21114-21119 和 UDP 21116 |

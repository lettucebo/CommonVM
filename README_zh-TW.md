# CodiMD、Outline、n8n、Open WebUI 與 RustDesk 合併服務

此設定使用 Docker Compose，將 CodiMD、Outline、n8n、Open WebUI 與 RustDesk 合併到單一 VM 上。Caddy 負責 CodiMD、n8n、Outline 與 Open WebUI 的反向代理。

> **說明**：此專案合併了多個部署：
> - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter) - n8n 工作流程自動化
> - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc) - 協作式 Markdown 編輯器
> - [Outline](https://github.com/outline/outline) - 團隊知識庫，導入中，未來取代 CodiMD
> - [Open WebUI](https://github.com/open-webui/open-webui) - 自架聊天與 RAG 介面，經 Caddy 發布並以來源 IP 允許清單限制存取
> - [RustDesk Server](https://github.com/rustdesk/rustdesk-server) - 自架遠端桌面中繼伺服器

> **Open WebUI 對外發布模式**：Open WebUI 經由 Caddy 發布，採用三層模型：Cloudflare proxied DNS → 依 hostname 限制的 Caddy 來源 IP 允許清單 → Open WebUI Microsoft Entra OAuth。Open WebUI 的 Microsoft Entra ID 登入才是身分邊界，IP 允許清單並非身分邊界。僅有 `{$OPENWEBUI_DOMAIN}` 受允許清單限制，既有站點路由維持不變。

## 前置需求

- Azure VM (推薦使用 Ubuntu)
- 已安裝 Docker 和 Docker Compose
- 給 Caddy 與 RustDesk 使用的公用 IP 位址
- 指向 VM IP 的 DNS 紀錄，每個由 Caddy 代理的服務各一筆 (詳見 `.env`)：
  - CodiMD (`CODIMD_DOMAIN`)
  - n8n (`N8N_DOMAIN`)
  - Outline (`OUTLINE_DOMAIN`)
  - Open WebUI (`OPENWEBUI_DOMAIN`)
- 為 Open WebUI hostname (`OPENWEBUI_DOMAIN`) 啟用 Proxy (橘色雲朵) 的 Cloudflare 代管 zone
- 用於 **專屬** Open WebUI app registration 的 Microsoft Entra tenant
- 可透過 OpenAI 相容 `/openai/v1` base URL 存取的 Microsoft Foundry chat 與 embedding deployment
- 給 Open WebUI uploads 使用的專屬 Azure Storage Account 與 private Blob container
- Azure 網路安全性群組 (NSG) 已開啟以下 Port：
  - **80, 443** (HTTP/HTTPS，供 Caddy 使用)
  - **21114-21119 TCP** (RustDesk)
  - **21116 UDP** (RustDesk)

> **Cloudflare upload 限制**：Cloudflare 文件目前列出 Free 與 Pro 方案的 proxied request body 上限為 **100 MB**。啟用大型上傳前請先確認最新限制：<https://developers.cloudflare.com/workers/platform/limits/>

## 安裝 Docker (Ubuntu 24.04 LTS)

如果您尚未安裝 Docker，請執行以下指令來安裝 Docker Engine 和 Docker Compose：

```bash
# 1. 安裝必要的相依套件 (包含 git, curl, gnupg)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git

# 2. 設定 Docker 的 apt repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# 3. 安裝 Docker packages (包含 docker-compose-plugin)
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. 將使用者加入 docker 群組 (避免每次都要 sudo)
sudo usermod -aG docker $USER
newgrp docker
```

## 安裝步驟

1. **掛載資料磁碟**：
   根據您的 `lsblk` 輸出，`sdc` (32G) 是您的資料磁碟，但尚未掛載。`sdb` (16G) 是 Azure 的暫存磁碟，**請勿**將資料存放在 `sdb`，因為重開機後資料會消失。

   請執行以下指令來格式化並掛載 `sdc` 到 `/mnt/data`：

   ```bash
   # 1. 格式化磁碟 (使用 XFS 或 ext4)
   sudo mkfs.xfs /dev/sdc

   # 2. 建立掛載點
   sudo mkdir -p /mnt/data

   # 3. 掛載磁碟
   sudo mount /dev/sdc /mnt/data

   # 4. 設定開機自動掛載
   # 取得 UUID
   sudo blkid /dev/sdc
   # 將 UUID 加入 /etc/fstab (請將 <UUID> 替換為實際輸出的 UUID)
   # echo "UUID=<UUID> /mnt/data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
   ```

   > **提示**：您可以使用 `df -h` 或 `lsblk` 來確認掛載結果。
2. **複製檔案**：將此目錄 (`src`) 傳輸到您的 VM。
3. **設定環境變數**：
   - 將 `.env.example` 複製為 `.env`，再替換所有佔位值。
   - `ACME_EMAIL` 為必填；空值會讓 Caddy 拒絕載入設定，導致所有反向代理
     服務無法使用。
   - 明確設定 `CADDY_TLS`：使用自動 Let's Encrypt 時留空；只有上游代理
     接受自簽 origin 憑證時才使用 `tls internal`。
   - 啟動 Outline 前設定所有 `OUTLINE_*` 值，並分別使用
     `openssl rand -hex 32` 產生 `OUTLINE_SECRET_KEY` 與
     `OUTLINE_UTILS_SECRET`。
   - Outline v1.10.0 首次建立的工作區名稱固定為 `Outline`；登入後可從
     **Settings → Details** 重新命名。
   - 本設定的 `OUTLINE_FILE_STORAGE_UPLOAD_MAX_SIZE` 預設為 10 MiB；
     只有在評估 VM 記憶體與磁碟容量後才提高。
   - Open WebUI 第一次啟動前，先完成所有 `OPENWEBUI_*` 佔位值設定
     (包含 `OPENWEBUI_ALLOWED_IPS`)。
   - **重要**：修改 `.env` 中的 `DATA_ROOT` 變數，將其指向您的掛載路徑 (預設：`/mnt/data`)。
4. **設定資料夾權限**：
   由於容器內的使用者 ID (UID) 可能與主機不同，請執行以下指令修正資料夾權限，以避免 `Permission denied` 錯誤：

   ```bash
   # 修正 n8n 資料夾權限 (UID 1000)
   sudo chown -R 1000:1000 /mnt/data/n8n

   # 修正 CodiMD 資料夾權限 (UID 1500)
   sudo chown -R 1500:1500 /mnt/data/codimd

   # 修正 Outline 資料夾權限 (UID 1001，即映像檔內的 "nodejs" 使用者)
   sudo mkdir -p /mnt/data/outline/data /mnt/data/outline/db /mnt/data/outline/redis
   sudo chown -R 1001:1001 /mnt/data/outline/data
   ```
5. **建立 RustDesk 資料目錄**：
   ```bash
   sudo mkdir -p /mnt/data/rustdesk/data
   ```
6. **啟動服務**：
   ```bash
   docker compose up -d
   ```
7. **驗證 (DNS 切換前)**：
   如果您尚未將 DNS 指向此 VM，請依照以下步驟進行本機驗證：

   **A. 修改本機 Hosts 檔案**
   在您的電腦 (不是 Azure VM) 上修改 hosts 檔案，將網域指向 VM 的公用 IP：
   - **Windows**: `C:\Windows\System32\drivers\etc\hosts` (需管理員權限)
   - **Mac/Linux**: `/etc/hosts` (需用 sudo)

   新增以下內容：
   ```text
   <VM_PUBLIC_IP> <CODIMD_DOMAIN>
   <VM_PUBLIC_IP> <N8N_DOMAIN>
   <VM_PUBLIC_IP> <OUTLINE_DOMAIN>
   <VM_PUBLIC_IP> <OPENWEBUI_DOMAIN>
   ```

   **B. 暫時使用自簽憑證**
   在 `.env` 設定 `CADDY_TLS=tls internal`，再執行
   `docker compose up -d caddy`。這會讓 Caddy 在 DNS 尚未設定時使用自簽憑證。

   **C. 測試連線**
   1. 重新啟動 Caddy：`docker compose up -d caddy`
   2. 在瀏覽器開啟 `https://<CODIMD_DOMAIN>`、`https://<N8N_DOMAIN>`、
      `https://<OUTLINE_DOMAIN>` 與 `https://<OPENWEBUI_DOMAIN>`。
   3. 瀏覽器會警告「連線不安全」(因為是自簽憑證)，請點擊「進階」並選擇「繼續前往」。
   4. 確認 CodiMD、n8n、Outline 與 Open WebUI 功能正常。

   **D. 準備正式上線**
   確認一切正常後：
   1. 移除本機 hosts 檔案中的設定。
   2. 在 DNS 供應商處將網域指向 VM IP。
   3. 清空 `.env` 中的 `CADDY_TLS`。
   4. 執行 `docker compose up -d caddy`，讓 Caddy 申請正式的
      Let's Encrypt 憑證。

8. **正式驗證**：

   - 檢查日誌：`docker compose logs -f`
   - 存取 `https://<CODIMD_DOMAIN>`
   - 存取 `https://<N8N_DOMAIN>`
   - 存取 `https://<OUTLINE_DOMAIN>`
   - 存取 `https://<OPENWEBUI_DOMAIN>`

## Open WebUI 部署 (Caddy allowlist + Microsoft Entra ID)

本節所有指令都從 `src/` 執行。

### 啟用前的容量檢查

啟用 Open WebUI 前，先檢查實際剩餘資源：

```bash
cd src
free -h
df -h
docker stats --no-stream
```

`src/.env.example` 內的 `OPENWEBUI_MEM_LIMIT` 預設是 `1024m`，Compose 會套用 `mem_limit: ${OPENWEBUI_MEM_LIMIT:-1024m}`。請把它視為 **安全上限**，不是 VM 一定夠用的證明。**不要**為了硬塞 Open WebUI 而調降既有服務的 limit。如果 VM 無法同時保留作業系統 headroom 與現有工作負載，請先停止，改成擴容或重新討論部署，而不是強行上線。

### Azure Storage 佈建 (Azure PowerShell)

Open WebUI uploads 請使用專屬 Storage Account。account key 屬於機密；不要不必要地把它印在終端輸出裡，更不要 commit 到 Git。

```powershell
$SubscriptionName = '<approved-subscription-name>'
$Location = '<same-region-as-vm-or-approved-region>'
$ResourceGroupName = '<approved-resource-group>'
$StorageAccountName = '<globally-unique-lowercase-name>'
$ContainerName = 'openwebui'

Get-AzSubscription -SubscriptionName $SubscriptionName
Set-AzContext -SubscriptionName $SubscriptionName
Get-AzContext

$StorageAccount = New-AzStorageAccount `
  -ResourceGroupName $ResourceGroupName `
  -Name $StorageAccountName `
  -Location $Location `
  -SkuName Standard_LRS `
  -Kind StorageV2 `
  -AccessTier Hot `
  -AllowBlobPublicAccess $false

$Context = $StorageAccount.Context
New-AzStorageContainer -Name $ContainerName -Context $Context -Permission Off

$StorageEndpoint = $StorageAccount.PrimaryEndpoints.Blob.ToString().TrimEnd('/')
$StorageKey = Get-AzStorageAccountKey `
  -ResourceGroupName $ResourceGroupName `
  -Name $StorageAccountName `
  | Select-Object -First 1 -ExpandProperty Value

# 請私下填入 src/.env，然後從 shell 清掉 key。
# OPENWEBUI_AZURE_STORAGE_ENDPOINT=$StorageEndpoint
# OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME=$ContainerName
# OPENWEBUI_AZURE_STORAGE_KEY=$StorageKey
Remove-Variable StorageKey
```

只能使用已核准的 subscription 或 resource group；**不要**把這段流程指向任何暫時性的 lab subscription。`OPENWEBUI_AZURE_STORAGE_ENDPOINT` 必須維持 Azure Blob endpoint 格式 `https://<storage-account>.blob.core.windows.net`，`OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME` 必須是 `openwebui`，而 `OPENWEBUI_AZURE_STORAGE_KEY` 必須當成 secret，只能放在 `.env` 或核准的 secret manager。

### 專屬 Entra app registration

Open WebUI 必須使用 **專屬** app registration；不要重用 CodiMD/Outline 共用的那組。

1. 到 [Microsoft Entra admin center](https://entra.microsoft.com)，進入 **Entra ID** → **App registrations** → **New registration**。
2. 設定專屬 display name，例如 `Open WebUI - Production`。
3. 在 **Supported account types** 選 **Single tenant only - <your tenant>**。
4. 新增 **Web** redirect URI：`https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`。
5. 完成註冊後，記錄：
   - **Application (client) ID** → `OPENWEBUI_MICROSOFT_CLIENT_ID`
   - **Directory (tenant) ID** → `OPENWEBUI_MICROSOFT_CLIENT_TENANT_ID`
6. 到 **Certificates & secrets** → **New client secret**，立刻複製 **Value**，只存到 `src/.env` 的 `OPENWEBUI_MICROSOFT_CLIENT_SECRET` 或核准的 secret manager。之後您將無法再次讀到這個 secret value。
7. 再次確認 **Authentication** 畫面中的 redirect URI 仍是精確的 `https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`。
8. 確認 tenant 內已存在對應的 enterprise application (service principal)。若租戶沒有自動建立，可用已驗證的 Az PowerShell 補建一次：

   ```powershell
   New-AzADServicePrincipal -ApplicationId '<OPENWEBUI_MICROSOFT_CLIENT_ID>'
   ```

若只是基本 OpenID `openid profile email` 登入，**不需要** Microsoft Graph **application** permissions。不要為了基本登入就授與寬鬆的 directory permissions。

### Microsoft Foundry

Open WebUI 在此設定中使用 OpenAI 相容的 v1 endpoint。可接受的 base URL 格式如下：

- `https://<resource>.openai.azure.com/openai/v1`
- `https://<resource>.services.ai.azure.com/openai/v1`

請 **不要** 把 `/models` 加進 `.env` 的 base URL。base URL 應該只到 `/openai/v1`；只有單次測試要求可以再附加 `/models` 之類的 request path，但環境變數本身不能包含它。

將 chat 與 embedding deployment 對應到 Task 1 的精確變數：

- `OPENWEBUI_FOUNDRY_BASE_URL` → chat model endpoint 的 v1 base URL
- `OPENWEBUI_FOUNDRY_API_KEY` → 該 endpoint 的 API key
- `OPENWEBUI_FOUNDRY_CHAT_MODEL` → 已部署的 chat model 名稱
- `OPENWEBUI_RAG_OPENAI_BASE_URL` → embeddings 的 v1 base URL
- `OPENWEBUI_RAG_OPENAI_API_KEY` → embeddings 的 API key
- `OPENWEBUI_RAG_EMBEDDING_MODEL` → 已部署的 embedding model 名稱

若 chat 與 embeddings 共用同一個 Foundry resource 與 key，也請刻意把值各自填進兩組變數，讓 Compose 設定保持明確。

以下是可手動執行、且不會把 key 寫進 shell history 的驗證範本：

```bash
read -rsp "Foundry API key: " FOUNDRY_KEY && echo
BASE_URL="https://<resource>.services.ai.azure.com/openai/v1"
curl -fsS "${BASE_URL}/models" \
  -H "api-key: ${FOUNDRY_KEY}" \
  | python -m json.tool | sed -n '1,40p'
unset FOUNDRY_KEY BASE_URL
```

這只是驗證範本；**不代表**此儲存庫已替您的 live endpoint 做過測試。

### 存取控制與 DNS

Open WebUI 經由 Caddy 發布，並透過來源 IP 允許清單進行存取控制：

1. **DNS 設定**：
   在 Cloudflare 管理介面中，為 Open WebUI 子網域 (例如 `openweb` 或與 `OPENWEBUI_DOMAIN` 相符的名稱) 新增一筆指向 VM 公用 IP 的 **A** 紀錄。Proxy 狀態必須設為 **Proxied** (橘色雲朵)，與既有的 CodiMD、n8n 及 Outline DNS 紀錄相同。

2. **允許清單設定 (`OPENWEBUI_ALLOWED_IPS`)**：
   - 在 `src/.env` 中，將 `OPENWEBUI_ALLOWED_IPS` 設定為以空格分隔的 IPv4/IPv6 位址或 CIDR 範圍 (例如 `203.0.113.10/32` 或 `203.0.113.10/32 198.51.100.0/24`)。
   - 至 `https://cloudflare.com/cdn-cgi/trace` 查詢目前的來源 IP (`ip=` 欄位)。若您的網路環境使用 IPv6，且流量經由 IPv6 傳送，請一併加入相應的 IPv6 位址或前綴。
   - **Fail-closed 風險**：`OPENWEBUI_ALLOWED_IPS` 為 **必填**。展開後的值若為空或未定義，設定仍可通過驗證，但不含任何允許範圍，因此所有 Open WebUI 請求都會收到 `403 Forbidden`。格式錯誤的 IP/CIDR 會使 Caddy 驗證失敗，並可能阻止 Caddy 啟動或重新載入，影響 **所有** 反向代理站點 (CodiMD、n8n、Outline 與 Open WebUI)。
   - 每次修改 `.env` 或 `Caddyfile` 後，皆應執行驗證：
     ```bash
     cd src
     docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
     ```

3. **套用設定變更**：
   修改 `.env` 中的 `OPENWEBUI_ALLOWED_IPS` 或任何其他變數後，必須執行：
   ```bash
   cd src
   docker compose up -d caddy
   ```
   > **重要**：**不要** 使用 `docker compose restart caddy`。`restart` 指令會沿用現有容器的環境變數，**不會** 載入 `.env` 的最新設定。

4. **連線驗證**：
   - **允許的來源 IP**：連線至 `https://<OPENWEBUI_DOMAIN>` 會順利進入 Open WebUI 並顯示 Microsoft Entra ID 登入按鈕。
   - **被拒絕的來源 IP**：非允許清單內的 IP 存取時，Caddy 會立即回應 `403 Forbidden`。
   - **直連 Origin**：略過 Cloudflare 直接連向 VM IP 的請求，因缺乏受信任 proxy 的 `CF-Connecting-IP` 標頭，Caddy 會依 socket peer address 比對，非允許 IP 同樣會收到 `403 Forbidden`。

5. **Cloudflare Zone 設定注意事項**：
   - **Remove visitor IP headers**：必須維持 **Off** (關閉，預設值)。若開啟，Cloudflare 會移除 `CF-Connecting-IP` 標頭，使 Caddy 無法取得真實訪客 IP。
   - **Pseudo IPv4**：**不可** 設為 "Overwrite Headers"。若覆寫標頭，Cloudflare 會將 `CF-Connecting-IP` 置換為 64:ff9b:: 映射位址，破壞 IPv4 CIDR 比對。

6. **IP 變動被鎖在外面時的復原方式 (Azure Run Command)**：
   若外網 IP 變更而收到 403 被阻擋，可透過已登入 Azure CLI 的機器執行 Run Command 更新 `.env`，無需依賴 SSH 或 Web 存取：
   ```powershell
   $newIp = '<新公網 IP>/32'   # 至 https://cloudflare.com/cdn-cgi/trace 查看 ip=
   $script = @"
   set -eu
   cd /path/to/CommonVM/src
   OWNER=`$(stat -c '%U:%G' .env)
   cp -a .env "`$HOME/env-backup-`$(date +%Y%m%d%H%M%S).env"
   sed -i 's|^OPENWEBUI_ALLOWED_IPS=.*|OPENWEBUI_ALLOWED_IPS=$newIp|' .env
   chown "`$OWNER" .env
   chmod 600 .env
   docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   docker compose up -d caddy
   grep -n '^OPENWEBUI_ALLOWED_IPS=' .env
"@
   $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
   az vm run-command invoke --subscription '<subscription-id>' `
     --resource-group '<resource-group>' --name '<vm-name>' --command-id RunShellScript `
     --scripts "printf '%s' '$payload' | base64 -d | bash" --query "value[0].message" -o tsv
   ```
   注意：`sed -i` 會重建檔案，需執行 `chown "$OWNER" .env` 與 `chmod 600 .env` 以保持原有擁有者與權限。

7. **退役舊版 Cloudflare Tunnel (僅適用既有部署)**：
   在下列所有 Caddy 路徑驗證完成前，請保持舊 tunnel 持續運作。

   **在拉取檔案／映像或套用任何 Compose 變更之前**，先於 VM 的既有部署中，在同一個 shell 執行下列指令。此流程不假設容器名稱、要求只能找到一個結果，並驗證該容器 ID 具有預期的 Compose project 與 service labels：

   ```bash
   set -eu
   cd /path/to/CommonVM/src
   mapfile -t LEGACY_CLOUDFLARED_IDS < <(
     docker ps -aq \
       --filter 'label=com.docker.compose.project=src' \
       --filter 'label=com.docker.compose.service=cloudflared'
   )
   test "${#LEGACY_CLOUDFLARED_IDS[@]}" -eq 1
   LEGACY_CLOUDFLARED_ID="${LEGACY_CLOUDFLARED_IDS[0]}"
   test "$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$LEGACY_CLOUDFLARED_ID")" = 'src'
   test "$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$LEGACY_CLOUDFLARED_ID")" = 'cloudflared'
   printf 'Verified legacy container ID: %s\n' "$LEGACY_CLOUDFLARED_ID"
   ```

   保持此 shell 開啟，使 `LEGACY_CLOUDFLARED_ID` 持續指向已驗證的容器。接著拉取／套用新的 Compose 設定，**不要停止舊 tunnel**：

   ```bash
   docker compose pull
   docker compose up -d open-webui caddy
   docker compose ps open-webui caddy
   docker compose logs --tail=100 open-webui caddy
   ```

   請先完成下列所有檢查：

   - Caddy 狀態正常、Cloudflare proxied A record 已解析至 VM，且 Azure NSG／主機 firewall 允許 Caddy 使用 80 與 443 連接埠。
   - 允許的來源可進入 Open WebUI Microsoft Entra 登入流程。
   - Microsoft Entra 登入成功，且 Open WebUI 核心功能正常。
   - 被拒絕的來源與未列入允許清單的 direct-origin 請求皆收到 `403 Forbidden`。

   **只有在每項檢查都成功後**，才依先前保存的容器 ID 停止並移除已驗證的容器：

   ```bash
   docker stop "$LEGACY_CLOUDFLARED_ID"
   docker rm "$LEGACY_CLOUDFLARED_ID"
   unset LEGACY_CLOUDFLARED_ID LEGACY_CLOUDFLARED_IDS
   ```

   從 production `src/.env` 移除已退役的 token；流程不會顯示 token，並會保留檔案原本的 numeric owner、group 與 mode：

   ```bash
   set -euo pipefail
   ENV_FILE=.env
   ENV_DIR=$(dirname -- "$ENV_FILE")
   ENV_BASE=$(basename -- "$ENV_FILE")
   ENV_OWNER=$(stat -c '%u:%g' "$ENV_FILE")
   ENV_MODE=$(stat -c '%a' "$ENV_FILE")
   ENV_BACKUP="$HOME/env-backup-$(date +%Y%m%d%H%M%S).env"
   ENV_TMP=$(mktemp --tmpdir="$ENV_DIR" ".${ENV_BASE}.XXXXXX")
   trap 'rm -f -- "$ENV_TMP"' EXIT
   if ! sudo grep -q '^CLOUDFLARED_TUNNEL_TOKEN=' "$ENV_FILE"; then
     printf '%s\n' 'CLOUDFLARED_TUNNEL_TOKEN was not found; refusing to replace .env.' >&2
     exit 1
   fi
   sudo cp -a -- "$ENV_FILE" "$ENV_BACKUP"
   sudo awk '!/^CLOUDFLARED_TUNNEL_TOKEN=/' "$ENV_FILE" > "$ENV_TMP"
   test -s "$ENV_TMP"
   if grep -q '^CLOUDFLARED_TUNNEL_TOKEN=' "$ENV_TMP"; then
     printf '%s\n' 'Token removal check failed; original .env is unchanged.' >&2
     exit 1
   fi
   sudo chown "$ENV_OWNER" "$ENV_TMP"
   sudo chmod "$ENV_MODE" "$ENV_TMP"
   sudo mv -- "$ENV_TMP" "$ENV_FILE"
   trap - EXIT
   test "$(stat -c '%u:%g' "$ENV_FILE")" = "$ENV_OWNER"
   test "$(stat -c '%a' "$ENV_FILE")" = "$ENV_MODE"
   if sudo grep -q '^CLOUDFLARED_TUNNEL_TOKEN=' "$ENV_FILE"; then
     printf '%s\n' 'Token remains in .env; restore the backup before continuing.' >&2
     exit 1
   fi
   printf 'Backup retained at %s\n' "$ENV_BACKUP"
   unset ENV_FILE ENV_DIR ENV_BASE ENV_OWNER ENV_MODE ENV_BACKUP ENV_TMP
   ```

   最後，使用正確的 Cloudflare 帳戶完成 Wrangler 驗證、列出 remote named tunnels，並明確選擇要退役的 tunnel。Tunnel 名稱在帳戶內唯一，但刪除時仍應使用 `tunnel info` 顯示的 UUID，並在執行前確認名稱：

   ```bash
   export npm_config_registry='https://packagefeedproxy.microsoft.io/npm/'
   npx --yes wrangler@latest tunnel list
   read -r -p 'Exact legacy tunnel name from the list: ' LEGACY_TUNNEL_NAME
   test -n "$LEGACY_TUNNEL_NAME"
   TUNNEL_INFO=$(npx --yes wrangler@latest tunnel info "$LEGACY_TUNNEL_NAME")
   printf '%s\n' "$TUNNEL_INFO"
   RESOLVED_TUNNEL_NAME=$(printf '%s\n' "$TUNNEL_INFO" | sed -n 's/^[[:space:]]*Name:[[:space:]]*//p')
   LEGACY_TUNNEL_ID=$(printf '%s\n' "$TUNNEL_INFO" | sed -n 's/^[[:space:]]*ID:[[:space:]]*//p')
   test "$RESOLVED_TUNNEL_NAME" = "$LEGACY_TUNNEL_NAME"
   test -n "$LEGACY_TUNNEL_ID"
   npx --yes wrangler@latest tunnel info "$LEGACY_TUNNEL_ID"
   read -r -p "Type DELETE $RESOLVED_TUNNEL_NAME to confirm: " CONFIRM
   test "$CONFIRM" = "DELETE $RESOLVED_TUNNEL_NAME"
   npx --yes wrangler@latest tunnel delete "$LEGACY_TUNNEL_ID"
   unset LEGACY_TUNNEL_NAME TUNNEL_INFO RESOLVED_TUNNEL_NAME LEGACY_TUNNEL_ID CONFIRM npm_config_registry
   ```

8. **選配硬化**：
   - **Cloudflare WAF 邊緣 IP 規則**：可新增 WAF 自訂規則 `(http.host eq "openweb.example.com" and not ip.src in {<your-ips>})` → Block，在 Cloudflare 邊緣阻斷非允許流量，不消耗 VM 運算資源。
   - **Cloudflare Cache Bypass**：建立 Cache Rule，針對 `http.host eq "openweb.example.com"` 設定 Bypass Cache，避免靜態資源在邊緣節點被未授權 IP 取得。
   - **Tailscale / WireGuard**：若 IP 經常變動，可搭配 Mesh VPN (Tailscale/WireGuard) 以固定私有 IP 存取 Open WebUI，徹底免去頻繁維護公網 IP 清單的困擾。

Compose 會將 Open WebUI HTTP 與 Socket.IO 的 CORS 限制為 `https://${OPENWEBUI_DOMAIN}`。Open WebUI v0.11.3 仍可能顯示誤導性警告，聲稱 Microsoft logout 必須設定 `OPENID_PROVIDER_URL` 或 `OPENID_END_SESSION_ENDPOINT`；內建 Microsoft provider 實際上已使用 tenant-specific OpenID discovery，logout route 也會解析該 provider metadata。不要只為了消除警告而新增自訂 logout endpoint，因為那條路徑會略過正常的 `id_token_hint` 處理。調整 OAuth 設定前，應先透過真實的 Microsoft 登入流程驗證 logout。

### 第一次啟動與驗證

第一次啟動前，先在 Azure data disk 建立 Open WebUI 資料目錄：

```bash
sudo install -d -m 0750 /mnt/data/open-webui/data
```

`ghcr.io/open-webui/open-webui:v0.11.3` 預設以 UID/GID `0` 執行，因此這裡不需要額外做 service-specific `chown`。但目錄仍不應該設成 world-writable。

接著準備第一次啟動：

1. 若尚未建立，請先在 `src/` 內把 `.env.example` 複製成 `.env`。
2. 啟動前先填完所有 Open WebUI 與 Caddy 相關欄位：
   - `OPENWEBUI_DOMAIN`
   - `OPENWEBUI_ALLOWED_IPS`
   - `OPENWEBUI_MEM_LIMIT`
   - `OPENWEBUI_SECRET_KEY`
   - `OPENWEBUI_ENABLE_OAUTH_SIGNUP`
   - `OPENWEBUI_MICROSOFT_CLIENT_ID`
   - `OPENWEBUI_MICROSOFT_CLIENT_SECRET`
   - `OPENWEBUI_MICROSOFT_CLIENT_TENANT_ID`
   - `OPENWEBUI_FOUNDRY_BASE_URL`
   - `OPENWEBUI_FOUNDRY_API_KEY`
   - `OPENWEBUI_FOUNDRY_CHAT_MODEL`
   - `OPENWEBUI_AZURE_STORAGE_ENDPOINT`
   - `OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME`
   - `OPENWEBUI_AZURE_STORAGE_KEY`
   - `OPENWEBUI_RAG_OPENAI_BASE_URL`
   - `OPENWEBUI_RAG_OPENAI_API_KEY`
   - `OPENWEBUI_RAG_EMBEDDING_MODEL`
3. 保持 `ENABLE_PERSISTENT_CONFIG=false`。在這個模式下，環境變數會維持 authoritative；Admin UI 裡的設定看起來可能能編輯，但重啟後不會保留。
4. 初次建立授權 OAuth 使用者時，先保持 `OPENWEBUI_ENABLE_OAUTH_SIGNUP=true`。在目標帳號建立完成後，把它改成 `false`，然後只重建 **Open WebUI**：

   ```bash
   cd src
   docker compose up -d --no-deps open-webui
   ```

   這一步 **不要** 重啟或重建 Caddy。
5. 只啟動新服務：

   ```bash
   cd src
   docker compose up -d open-webui caddy
   ```

建議驗證順序如下：

```bash
cd src
docker compose ps open-webui caddy
docker compose logs --tail=100 open-webui caddy
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose exec open-webui curl -fsS http://127.0.0.1:8080/health
```

之後再手動驗證：

- 允許清單內的用戶端 IP 可以存取 `https://<OPENWEBUI_DOMAIN>` 並看到 Entra ID 登入選項
- 非允許清單內的用戶端 IP 會收到 `403 Forbidden`
- 未經允許的直連 origin 請求會收到 `403 Forbidden`
- 既有 `https://<CODIMD_DOMAIN>`、`https://<N8N_DOMAIN>` 與 `https://<OUTLINE_DOMAIN>` 行為維持不變
- RustDesk 的 logs 與連線仍正常
- chat requests 能成功打到設定好的 Foundry model
- file upload 成功
- 之後的 file re-read / RAG lookup 可成功使用 embedding model
- `openwebui` container 中可看到預期的 Blob objects
- 重建 `open-webui` 後，`${DATA_ROOT}/open-webui/data` 內的 chats、accounts 與 configuration 仍能保留

這裡的 Azure Blob **不是**完整儲存層。Open WebUI v0.11.3 的 Azure storage provider 會先把每個 upload 寫到 `/app/backend/data/uploads`，再上傳到 Blob storage。成功上傳後，本機副本不會自動移除，因此 `${DATA_ROOT}` 仍必須預留 Open WebUI 本機成長所需的容量。

## RustDesk 設定

首次啟動後，RustDesk 會自動產生用於加密連線的金鑰對。

1. **取得公鑰**：
   ```bash
   cat /mnt/data/rustdesk/data/id_ed25519.pub
   ```
2. **設定 RustDesk 用戶端**：
   - 開啟 RustDesk 用戶端 → Settings → Network → ID/Relay Server
   - **ID Server**：`<VM_PUBLIC_IP>`
   - **Relay Server**：`<VM_PUBLIC_IP>`
   - **Key**：貼上步驟 1 取得的公鑰
3. **驗證連線**：
   ```bash
   # 檢查容器是否正常運行
   docker compose ps rustdesk-hbbs rustdesk-hbbr

   # 檢查日誌
   docker compose logs rustdesk-hbbs rustdesk-hbbr

   # 從外部機器測試 port
   nc -zv <VM_PUBLIC_IP> 21116
   ```

> **注意**：預設已設定 `ENCRYPTED_ONLY=1`，強制所有用戶端使用公鑰連線，防止未經授權的連線。

## 資料庫遷移

如果您需要從舊的 VM 遷移資料，請依照以下步驟操作。

### 1. 備份舊資料庫

**在舊的 CodiMD VM 上：**
```bash
# 備份 CodiMD DB
docker exec -t codimd_database_1 pg_dump -U codimd codimd > codimd_backup.sql
```

**在舊的 n8n VM 上：**
```bash
# 尋找您的 postgres 容器名稱 (例如：src_postgres_1)
docker ps

# 備份 n8n DB (請替換 CONTAINER_NAME)
docker exec -t CONTAINER_NAME pg_dump -U n8n n8n > n8n_backup.sql
```

### 2. 在不覆蓋正式資料庫的前提下驗證備份

**在新 VM 上 (啟動服務後)：**
```bash
# 建立新的獨立資料庫，禁止刪除或覆蓋正式資料庫。
docker exec src-codimd-db-1 createdb -U codimd codimd_restore_check
docker exec src-n8n-db-1 createdb -U n8n n8n_restore_check

# 只還原到新資料庫。
cat codimd_backup.sql | docker exec -i src-codimd-db-1 psql -U codimd -d codimd_restore_check
cat n8n_backup.sql | docker exec -i src-n8n-db-1 psql -U n8n -d n8n_restore_check

# 將資料筆數與正式資料庫比對。驗證資料庫應保留到取得明確刪除許可為止。
```

## 成本估算 💰

此儲存庫 **不會** 宣稱目前實際的 VM SKU 或每月價格。若要為 Open WebUI 擴容，請先確認您訂用帳戶中的真實 VM 規格、磁碟與定價。

Open WebUI 主要新增三類成本：

- 現有主機上的額外 VM 記憶體與 data disk 使用量
- uploads 對應的 Azure Blob 容量與交易費用
- chat 與 embeddings 的 Microsoft Foundry 模型用量

此儲存庫沒有改用 Azure Container Apps，主因是 Open WebUI 仍依賴可靠的本機檔案系統來保存 SQLite 與本機 upload/cache 資料，而既有 VM 若已存在，通常幾乎沒有額外基礎設施成本。當然，在某些環境中 ACA 仍可能更合適；只是當您需要 durable storage 與資料庫之後，它通常會增加更多元件，也可能比把此工作負載留在目前 VM 上更貴。

_如果本來就有足夠 headroom，可能還是比您的咖啡癮便宜。☕_

## 維護

### 更新

`src/docker-compose.yml` 內的 image version 都是 pinned。單獨執行 `docker compose pull` 只能刷新目前已設定的 tag，**不會**把 pinned service 升到新的 tag。

升級 Open WebUI 時：

1. 先閱讀上游 release notes。
2. 先建立下方 **備份** 章節中的升級前備份。
3. 編輯 `src/docker-compose.yml` 內的精確 image tag。
4. 驗證 Compose 檔：

   ```bash
   cd src
   docker compose config --quiet
   ```

5. 只拉取有變動的 service image：

   ```bash
   cd src
   docker compose pull open-webui
   ```

6. 只重建該 service：

   ```bash
   cd src
   docker compose up -d --no-deps open-webui
   ```

7. 檢查 health 與 logs：

   ```bash
   cd src
   docker compose ps open-webui
   docker compose logs --tail=100 open-webui
   ```

schema migration 之後，盲目回退舊 image tag 可能不安全。若升級後失敗，請改用已驗證的升級前備份還原，不要假設前一版 image 一定能安全讀取新資料。

### 監控

1. 檢查容器狀態：
```bash
docker compose ps
```

2. 查看日誌：
```bash
docker compose logs -f
```

3. 監控系統資源：
```bash
htop
```

### 備份

備份三套 PostgreSQL、Outline 本機附件，以及 Open WebUI 本機資料。以下指令會建立帶時間戳記的新檔，不會覆蓋既有備份。

```bash
# 先切到 Compose 專案目錄，讓 docker compose 能找到 docker-compose.yml。
cd /path/to/CommonVM/src
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "/mnt/data/backup/${STAMP}"

docker exec src-codimd-db-1 pg_dump -U codimd -d codimd -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/codimd.dump"
docker exec src-n8n-db-1 pg_dump -U n8n -d n8n -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/n8n.dump"
docker exec src-outline-db-1 pg_dump -U outline -d outline -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/outline.dump"

# 部分私密附件為 mode 0600，且由 Outline UID 1001 擁有。
sudo tar czf "/mnt/data/backup/${STAMP}/outline-data.tar.gz" \
  -C /mnt/data/outline data
sudo chown "$(id -u):$(id -g)" "/mnt/data/backup/${STAMP}/outline-data.tar.gz"

# Open WebUI 的 SQLite 位於 /mnt/data/open-webui/data。複製前只停止此
# service，完成後立刻拉回來。
docker compose stop open-webui
sudo tar czf "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz" \
  -C /mnt/data/open-webui data
docker compose up -d open-webui
sudo chown "$(id -u):$(id -g)" "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz"

# 非破壞性備份驗證
cat "/mnt/data/backup/${STAMP}/outline.dump" \
  | docker exec -i src-outline-db-1 pg_restore --list > /dev/null
tar tzf "/mnt/data/backup/${STAMP}/outline-data.tar.gz" > /dev/null
tar tzf "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz" > /dev/null
```

Azure Blob 內容 **不能** 取代 SQLite/data 備份。聊天紀錄、帳號、設定與其他本機 Open WebUI 狀態仍放在 `${DATA_ROOT}/open-webui/data`，所以這份備份仍然是必要的。

若要以非破壞方式驗證 Open WebUI 還原，請解壓到 **全新** 目錄，再在那裡檢查 SQLite。還原驗證時絕對不要覆蓋 live 目錄，也不要在未取得明確許可前刪除驗證目錄。

```bash
STAMP=<same-backup-stamp>
VERIFY_ROOT="/mnt/data/restore-check/${STAMP}"
mkdir -p "${VERIFY_ROOT}/open-webui"
tar xzf "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz" -C "${VERIFY_ROOT}/open-webui"

if [ -f "${VERIFY_ROOT}/open-webui/data/webui.db" ]; then
  docker run --rm \
    -v "${VERIFY_ROOT}/open-webui/data:/restore:ro" \
    ghcr.io/open-webui/open-webui:v0.11.3 \
    python -c "import sqlite3; conn=sqlite3.connect('/restore/webui.db'); print(conn.execute('PRAGMA integrity_check;').fetchone()[0]); conn.close()"
fi
```

請另外把 secrets 備份到核准的 secret manager：`OPENWEBUI_SECRET_KEY`、`OPENWEBUI_MICROSOFT_CLIENT_SECRET`、`OPENWEBUI_FOUNDRY_API_KEY` 與 `OPENWEBUI_RAG_OPENAI_API_KEY` **不得** 存在 tar 檔裡，也 **不得** 放進 Git。

## 安全性考量 🔒

1. **防火牆規則**：
   - Azure NSG 允許 80/443 (HTTP/HTTPS) 與 21114-21119 TCP + 21116 UDP (RustDesk)
   - Open WebUI 經由既有的 Caddy 80/443 port 提供服務；不需要額外開放 inbound NSG port
   - 建議在初始設定後停用 SSH port 22 (改用 Azure Bastion)

2. **SSH 存取**：
   - 僅使用 SSH 金鑰驗證
   - 應停用密碼驗證

3. **應用程式安全性**：
   - CodiMD、n8n、Outline 與 Open WebUI 由 Caddy 強制使用 HTTPS
   - Open WebUI 採用三層存取模型：Cloudflare proxied DNS → 依 hostname 限制的 Caddy 來源 IP 允許清單 → Open WebUI Microsoft Entra ID OAuth
   - Microsoft Entra ID OAuth 才是身分邊界，IP 允許清單並非身分邊界，僅作為縮小暴露面的深層防禦手段
   - CodiMD 使用 Microsoft Entra ID (OAuth2) 進行驗證
   - Outline 透過通用 OIDC 沿用 **同一個** Entra app registration
   - Open WebUI 應使用 **自己的** 專屬 Entra app registration
   - n8n 支援內建驗證和雙因素驗證 (2FA)

4. **為什麼無法靠 NSG allowlist 保護單一網站**：
   - CodiMD、n8n、Outline 與 Open WebUI 都共用 Caddy 後面的同一個 inbound port `443`
   - 由於 Cloudflare edge IP 位址屬於跨網域的共用基礎設施，Azure NSG 無法在傳輸層區分不同的 hostname，亦無法在 Cloudflare proxy 背後依訪客 IP 進行過濾
   - Caddy 在應用層依據受信任 Cloudflare proxy 傳遞的 `CF-Connecting-IP` 標頭執行個別 hostname 的 IP 允許清單比對，其他站台不受影響

5. **CodiMD 與 Outline 共用 Entra app registration** ⚠️：

   CodiMD 與 Outline 刻意共用同一個 app registration，因此：

   - 兩者共用同一組 client secret。**輪替時會同時中斷兩個服務**，
     必須同步更新 `CODIMD_OAUTH2_CLIENT_SECRET` 與 `OUTLINE_OIDC_CLIENT_SECRET`。
   - 該 app 必須同時包含兩組 redirect URI：
     `https://<CODIMD_DOMAIN>/auth/oauth2/callback` 與
     `https://<OUTLINE_DOMAIN>/auth/oidc.callback`
   - **未來移除 CodiMD 時不可刪除此 app registration** — Outline 仍靠它驗證。

   Outline 刻意採用通用 OIDC plugin 而非其 Azure plugin：Azure plugin 會呼叫
   Microsoft Graph `/v1.0/organization`，缺少 `Organization.Read.All`（通常需
   管理員同意）就會直接失敗。OIDC 只需要 `openid profile email`。

## 疑難排解

### 無法連線到服務
- 檢查 Azure Portal 中的 VM 狀態
- 驗證由 Caddy 代理的站點，其 DNS 設定是否指向 VM IP
- 檢查容器：`docker compose ps`
- 查看日誌：`docker compose logs -f`

### Open WebUI 回應 403
- **確認您的訪客 IP**：前往 `https://cloudflare.com/cdn-cgi/trace` 查看 `ip=` 欄位，確認連線是使用 IPv4 還是 IPv6。
- **檢查 `OPENWEBUI_ALLOWED_IPS`**：確認 `src/.env` 中的 `OPENWEBUI_ALLOWED_IPS` 包含您目前的 IP 位址或 CIDR 網段。多個網段以空白分隔。
- **是否正確套用環境變數？**：修改 `.env` 後必須執行 `docker compose up -d caddy`。使用 `docker compose restart caddy` 不會重新讀取 `.env` 的環境變數。
- **Cloudflare 標頭設定**：
  - 在 Cloudflare 控制台確認「Remove visitor IP headers」為 **Off**。
  - 確認「Pseudo IPv4」**未** 設定為「Overwrite Headers」。
- **允許清單與 Caddy 驗證**：展開後的 `OPENWEBUI_ALLOWED_IPS` 若為空或未定義，所有 Open WebUI 請求都會收到 403。格式錯誤的 IP/CIDR 會使 Caddy 驗證失敗，並可能阻止啟動或重新載入，影響所有反向代理站點。請使用以下指令驗證：
  ```bash
  docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  ```
- **直連 Origin 存取**：略過 Cloudflare 直連 VM 公用 IP 的連線，若訪客 socket IP 不在允許清單內，一律會收到 403。
- **被鎖在外面時的復原**：若 IP 變更導致被 403 阻擋，請透過 Azure Run Command 更新 `.env` (參考「存取控制與 DNS」章節的指令範本)。

### Microsoft OAuth redirect mismatch
- 確認 `OPENWEBUI_DOMAIN` 與公開 hostname 完全一致
- 確認 Entra app 的 redirect URI 精確為 `https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`
- 確認 `.env` 變數對應正確：
  - `OPENWEBUI_MICROSOFT_CLIENT_ID`
  - `OPENWEBUI_MICROSOFT_CLIENT_SECRET`
  - `OPENWEBUI_MICROSOFT_CLIENT_TENANT_ID`
- 確認 app 為 single-tenant，且對應的 service principal 已存在

### Foundry URL 或 model 設定問題
- `OPENWEBUI_FOUNDRY_BASE_URL` 與 `OPENWEBUI_RAG_OPENAI_BASE_URL` 都必須以 `/openai/v1` 結尾
- **不要**把 `/models` 寫進任一環境變數
- 確認 `OPENWEBUI_FOUNDRY_CHAT_MODEL` 是已部署的 chat model 名稱
- 確認 `OPENWEBUI_RAG_EMBEDDING_MODEL` 是已部署的 embedding model 名稱

### Azure Blob 403 或 upload 失敗
- 確認 `OPENWEBUI_AZURE_STORAGE_ENDPOINT` 格式為 `https://<storage-account>.blob.core.windows.net`
- 確認 `OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME=openwebui`
- 確認 container 存在且仍為 private (`-Permission Off`)
- 若 account key 已輪替，請更新 `.env` 中的 `OPENWEBUI_AZURE_STORAGE_KEY`，然後只重建 `open-webui`

### 本機磁碟成長
- Open WebUI 仍會把本機檔案寫到 `${DATA_ROOT}/open-webui/data`
- uploads 會先寫到本機，再複製到 Azure Blob
- 磁碟寫滿前先檢查成長情況：
  ```bash
  du -sh /mnt/data/open-webui/data/*
  ```

### 記憶體壓力或 OOM
- `OPENWEBUI_MEM_LIMIT=1024m` 是 guardrail，不是 sizing 保證
- 檢查 `free -h` 與 `docker stats --no-stream`
- 查看 `docker compose logs open-webui` 是否有 restart loop 或 OOM 徵象
- 若主機無法保留系統 headroom，請擴 VM，不要調降既有服務的 limit

### 資料庫連線問題
- 檢查 PostgreSQL 日誌：`docker compose logs codimd-db` 或 `docker compose logs n8n-db`
- 驗證 `.env` 中的環境變數
- 確保資料庫容器正在運行

### SSL/HTTPS 問題
- 檢查 Caddy 日誌：`docker compose logs caddy`
- 驗證網域是否指向正確的 IP
- 確保 Azure NSG 中的 80 和 443 port 已開啟
- 本機測試時，在 `.env` 設定 `CADDY_TLS=tls internal`，再重新啟動 Caddy

### RustDesk 連線問題
- 確認 NSG 規則包含 TCP 21114-21119 和 UDP 21116
- 檢查容器：`docker compose logs rustdesk-hbbs rustdesk-hbbr`
- 確保已設定 `network_mode: "host"` (port 不能與主機上其他服務衝突)
- 確認用戶端已填入正確的公鑰：`cat /mnt/data/rustdesk/data/id_ed25519.pub`
- 如果金鑰遺失，重啟 hbbs 容器：`docker compose restart rustdesk-hbbs`

### n8n 雙因素驗證/登入問題
如果您從舊的 n8n 實例遷移後無法使用 2FA 登入：
1. 從舊實例取得加密金鑰：
   ```bash
   docker exec -t <old_container> cat /home/node/.n8n/config
   ```
2. 加入到 `.env`：
   ```bash
   N8N_ENCRYPTION_KEY=your_old_key
   ```
3. 刪除自動產生的設定檔並重啟：
   ```bash
   docker compose stop n8n
   sudo rm /mnt/data/n8n/data/config
   docker compose up -d
   ```

## 支援

如有問題：
1. 查看 [n8n 文件](https://docs.n8n.io/)
2. 查看 [CodiMD 文件](https://hackmd.io/c/codimd-documentation)
3. 查看 [Outline 文件](https://docs.getoutline.com/)
4. 查看 [Open WebUI 文件](https://docs.openwebui.com/)
5. 查看 [RustDesk 文件](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/)
6. 在原始專案中開啟 issue：
   - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter)
   - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc)
   - [Open WebUI](https://github.com/open-webui/open-webui)
7. 造訪 [n8n 社群論壇](https://community.n8n.io/)

## 授權

此部署範本採用 MIT 授權。n8n、CodiMD、Open WebUI 與 RustDesk 各自採用其各自的授權條款。

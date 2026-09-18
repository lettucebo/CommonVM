# CodiMD、Outline、n8n、Open WebUI 與 RustDesk 合併服務

此設定使用 Docker Compose，將 CodiMD、Outline、n8n、Open WebUI、Cloudflare Tunnel 與 RustDesk 合併到單一 VM 上。Caddy 仍只負責 CodiMD、n8n 與 Outline 的反向代理。

> **說明**：此專案合併了多個部署：
> - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter) - n8n 工作流程自動化
> - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc) - 協作式 Markdown 編輯器
> - [Outline](https://github.com/outline/outline) - 團隊知識庫，導入中，未來取代 CodiMD
> - [Open WebUI](https://github.com/open-webui/open-webui) - 自架聊天與 RAG 介面，透過專屬 Cloudflare Tunnel 對外發布
> - [RustDesk Server](https://github.com/rustdesk/rustdesk-server) - 自架遠端桌面中繼伺服器

> **Open WebUI 對外發布模式**：Open WebUI **不是**走 Caddy。它透過專屬 Cloudflare Tunnel 發布，並由 Cloudflare Access 保護，因此不需要額外開放 inbound NSG port，也不會改動既有的 Caddy 路由。

## 前置需求

- Azure VM (推薦使用 Ubuntu)
- 已安裝 Docker 和 Docker Compose
- 給 Caddy 與 RustDesk 使用的公用 IP 位址
- 指向 VM IP 的 DNS 紀錄，每個由 Caddy 代理的服務各一筆 (詳見 `.env`)：
  - CodiMD (`CODIMD_DOMAIN`)
  - n8n (`N8N_DOMAIN`)
  - Outline (`OUTLINE_DOMAIN`)
- 給專屬 Open WebUI 網域 (`OPENWEBUI_DOMAIN`) 使用的 Cloudflare Zero Trust 帳戶與作用中的 zone
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
   - Open WebUI 第一次啟動前，先完成所有 `OPENWEBUI_*` 與
     `CLOUDFLARED_*` 佔位值設定。
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
   ```

   **B. 暫時使用自簽憑證**
   在 `.env` 設定 `CADDY_TLS=tls internal`，再執行
   `docker compose restart caddy`。這會讓 Caddy 在 DNS 尚未設定時使用自簽憑證。

   **C. 測試連線**
   1. 重新啟動 Caddy：`docker compose restart caddy`
   2. 在瀏覽器開啟 `https://<CODIMD_DOMAIN>`、`https://<N8N_DOMAIN>` 與
      `https://<OUTLINE_DOMAIN>`。
   3. 瀏覽器會警告「連線不安全」(因為是自簽憑證)，請點擊「進階」並選擇「繼續前往」。
   4. 確認 CodiMD、n8n 與 Outline 功能正常。

   **D. 準備正式上線**
   確認一切正常後：
   1. 移除本機 hosts 檔案中的設定。
   2. 在 DNS 供應商處將網域指向 VM IP。
   3. 清空 `.env` 中的 `CADDY_TLS`。
   4. 執行 `docker compose restart caddy`，讓 Caddy 申請正式的
      Let's Encrypt 憑證。

8. **正式驗證**：

   - 檢查日誌：`docker compose logs -f`
   - 存取 `https://<CODIMD_DOMAIN>`
   - 存取 `https://<N8N_DOMAIN>`
   - 存取 `https://<OUTLINE_DOMAIN>`

## Open WebUI 部署 (Cloudflare Tunnel + Microsoft Entra ID)

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

### Cloudflare Tunnel 與 Access

請在 Cloudflare Zero Trust dashboard 建立 **remotely managed** tunnel。

1. 在 Zero Trust 建立 tunnel。
2. 新增 public hostname，hostname 欄位只填 `<OPENWEBUI_DOMAIN>`（例如 `openweb.yu.money`），再另外把 service target 設成 `http://open-webui:8080`。如果介面另外要求選 protocol，請在那裡選 `HTTP`，不要在 hostname 欄位輸入 `https://`。
3. 只複製一次 tunnel token，填入 `src/.env` 的 `CLOUDFLARED_TUNNEL_TOKEN`。這個 token 是 secret。
4. DNS 必須維持 tunnel-managed **CNAME**，**不要**把此 hostname 建成指向 VM public IP 的 `A` record。
5. 針對同一個 hostname 建立 **self-hosted** 的 Cloudflare Access application，並新增只允許目標 Entra 使用者或群組的 **Allow** policy。

Tunnel 從 VM 發出的是 outbound-only 連線。`open-webui` 與 `cloudflared` 都不會對 host 發布 port，這可避免此 hostname 被 direct-origin bypass，也不會干擾既有由 Caddy 發布的站點。目前這個 hostname 依賴單一 tunnel connector；`restart: always` 可協助 `cloudflared` 行程自動復原，而 `docker compose logs cloudflared` 是路由失效時的第一個檢查點。

權威文件：

- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>

### 第一次啟動與驗證

第一次啟動前，先在 Azure data disk 建立 Open WebUI 資料目錄：

```bash
sudo install -d -m 0750 /mnt/data/open-webui/data
```

`ghcr.io/open-webui/open-webui:v0.11.3` 預設以 UID/GID `0` 執行，因此這裡不需要額外做 service-specific `chown`。但目錄仍不應該設成 world-writable。

接著準備第一次啟動：

1. 若尚未建立，請先在 `src/` 內把 `.env.example` 複製成 `.env`。
2. 啟動前先填完所有 Open WebUI 與 Cloudflare 相關欄位：
   - `OPENWEBUI_DOMAIN`
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
   - `CLOUDFLARED_TUNNEL_TOKEN`
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
   docker compose up -d open-webui cloudflared
   ```

建議驗證順序如下：

```bash
cd src
docker compose ps open-webui cloudflared
docker compose logs --tail=100 open-webui cloudflared
docker compose exec open-webui curl -fsS http://127.0.0.1:8080/health
```

之後再手動驗證：

- 有權限的 Cloudflare Access 使用者可以進入 `https://<OPENWEBUI_DOMAIN>`
- 未授權使用者會被 Access 擋下
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

Open WebUI 主要新增四類成本：

- 現有主機上的額外 VM 記憶體與 data disk 使用量
- uploads 對應的 Azure Blob 容量與交易費用
- chat 與 embeddings 的 Microsoft Foundry 模型用量
- 當使用量超過 Free tier 時，Cloudflare Zero Trust / Access 的功能成本

此儲存庫沒有改用 Azure Container Apps，主因是 Open WebUI 仍依賴可靠的本機檔案系統來保存 SQLite 與本機 upload/cache 資料，而既有 VM 若已存在，通常幾乎沒有額外基礎設施成本。當然，在某些環境中 ACA 仍可能更合適；只是當您需要 durable storage 與資料庫之後，它通常會增加更多元件，也可能比把此工作負載留在目前 VM 上更貴。

_如果本來就有足夠 headroom，可能還是比您的咖啡癮便宜。☕_

## 維護

### 更新

`src/docker-compose.yml` 內的 image version 都是 pinned。單獨執行 `docker compose pull` 只能刷新目前已設定的 tag，**不會**把 pinned service 升到新的 tag。

升級 Open WebUI 或 cloudflared 時：

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

請另外把 secrets 備份到核准的 secret manager：`OPENWEBUI_SECRET_KEY`、`OPENWEBUI_MICROSOFT_CLIENT_SECRET`、`OPENWEBUI_FOUNDRY_API_KEY`、`OPENWEBUI_RAG_OPENAI_API_KEY` 與 `CLOUDFLARED_TUNNEL_TOKEN` **不得** 存在 tar 檔裡，也 **不得** 放進 Git。

## 安全性考量 🔒

1. **防火牆規則**：
   - Azure NSG 允許 80/443 (HTTP/HTTPS) 與 21114-21119 TCP + 21116 UDP (RustDesk)
   - Open WebUI 不需要額外 inbound NSG port，因為 `cloudflared` 使用 outbound-only tunnel 連線
   - 建議在初始設定後停用 SSH port 22 (改用 Azure Bastion)

2. **SSH 存取**：
   - 僅使用 SSH 金鑰驗證
   - 應停用密碼驗證

3. **應用程式安全性**：
   - CodiMD、n8n 與 Outline 由 Caddy 強制使用 HTTPS
   - Open WebUI 預期放在專屬 hostname 的 Cloudflare Access 後方
   - CodiMD 使用 Microsoft Entra ID (OAuth2) 進行驗證
   - Outline 透過通用 OIDC 沿用 **同一個** Entra app registration
   - Open WebUI 應使用 **自己的** 專屬 Entra app registration
   - n8n 支援內建驗證和雙因素驗證 (2FA)

4. **為什麼無法靠 NSG allowlist 保護單一網站**：
   - CodiMD、n8n 與 Outline 都共用 Caddy 後面的同一個 inbound port `443`
   - Open WebUI 是透過 Cloudflare edge 發布，而 Cloudflare source address 屬於共用基礎設施，無法在 Azure NSG 層精確表示成「單一站台專用 allowlist」
   - 因此 NSG 規則只能處理傳輸層的 allow/deny，無法對這些 HTTPS 站台有效表達「只允許某一個 hostname」

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

### Cloudflare Tunnel / Open WebUI 路由問題
- 檢查 `docker compose logs cloudflared`
- 確認 public hostname 指向的是 `http://open-webui:8080`
- 確認 DNS 是 tunnel-managed CNAME，而不是指向 VM public IP 的 `A` record
- 確認 `open-webui` 與 `cloudflared` 沒有發布 host port

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

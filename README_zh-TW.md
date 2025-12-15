# CodiMD 與 n8n 合併服務

此設定使用 Docker Compose 和 Caddy 作為反向代理，將 CodiMD 和 n8n 合併到單一 VM 上。

> **說明**：此專案合併了兩個獨立的 Docker 部署：
> - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter) - n8n 工作流程自動化
> - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc) - 協作式 Markdown 編輯器

## 前置需求

- Azure VM (推薦使用 Ubuntu)
- 已安裝 Docker 和 Docker Compose
- 公用 IP 位址
- 指向 VM IP 的 DNS 紀錄：
  - `doc.yu.money`
  - `n8n.yu.money`
- Azure 網路安全性群組 (NSG) 已開啟 Port 80 和 443

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
   echo "UUID=fd1a2678-231e-4a99-925d-d73498e488fa /mnt/data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
   ```

   > **提示**：您可以使用指令 `df -h` 或 `lsblk` 來確認掛載結果。
2. **複製檔案**：將此目錄 (`merged-services`) 傳輸到您的 VM。
3. **設定環境變數**：
   - 檢查 `.env` 檔案並確保所有密鑰 (Secrets) 正確無誤。
   - **重要**：修改 `.env` 中的 `DATA_ROOT` 變數，將其指向您的掛載路徑 (預設：`/mnt/data`)。
4. **設定資料夾權限**：
   由於容器內的使用者 ID (UID) 可能與主機不同，請執行以下指令修正資料夾權限，以避免 `Permission denied` 錯誤：

   ```bash
   # 修正 n8n 資料夾權限 (UID 1000)
   sudo chown -R 1000:1000 /mnt/data/n8n

   # 修正 CodiMD 上傳資料夾權限 (UID 1500)
   sudo chown -R 1500:1500 /mnt/data/codimd
   ```
5. **啟動服務**：
   ```bash
   docker compose up -d
   ```
6. **驗證 (DNS 切換前)**：
   如果您尚未將 DNS 指向此 VM，請依照以下步驟進行本機驗證：

   **A. 修改本機 Hosts 檔案**
   在您的電腦 (不是 Azure VM) 上修改 hosts 檔案，將網域指向 VM 的公用 IP：
   - **Windows**: `C:\Windows\System32\drivers\etc\hosts` (需用管理員權限開啟記事本)
   - **Mac/Linux**: `/etc/hosts` (需用 sudo)

   新增以下內容：
   ```text
   <VM_PUBLIC_IP> doc.yu.money
   <VM_PUBLIC_IP> n8n.yu.money
   ```

   **B. 暫時使用自簽憑證 (選用)**
   若要在沒有 DNS 的情況下進行本機測試，可以暫時在 `src/Caddyfile` 的網站區塊中加入 `tls internal`：
   ```
   {$CODIMD_DOMAIN} {
       tls internal
       # ... 其他設定
   }
   ```
   這會讓 Caddy 發自簽憑證，讓您可以在沒有 DNS 的情況下啟動 HTTPS 服務。
   
   **C. 測試連線**
   1. 重新啟動 Docker 服務：`docker compose restart`
   2. 在瀏覽器開啟 `https://doc.yu.money` 和 `https://n8n.yu.money`。
   3. 如果使用自簽憑證，瀏覽器會警告「連線不安全」，請點擊「進階」並選擇「繼續前往」。
   4. 確認 CodiMD 和 n8n 功能正常 (登入、建立筆記、建立 Workflow)。

   **D. 準備正式上線**
   確認一切正常後：
   1. 移除本機 hosts 檔案中的設定。
   2. 在 DNS 供應商處將網域指向 VM IP。
   3. 如果您有加入 `tls internal` 進行測試，請從 `src/Caddyfile` 中移除。
   4. 執行 `docker compose restart` 讓 Caddy 申請正式的 Let's Encrypt 憑證。

7. **正式驗證**：
   - 檢查日誌：`docker compose logs -f`
   - 存取 `https://doc.yu.money`
   - 存取 `https://n8n.yu.money`

## 資料庫遷移

如果您需要從舊的 VM 遷移資料，請依照以下步驟操作。

### 1. 備份舊資料庫

**在舊的 CodiMD VM 上：**
```bash
# 備份 CodiMD 資料庫
docker exec -t codimd_database_1 pg_dump -U codimd codimd > codimd_backup.sql
```

**在舊的 n8n VM 上：**
```bash
# 尋找您的 postgres 容器名稱 (例如：src_postgres_1)
docker ps 

# 備份 n8n 資料庫 (請替換 CONTAINER_NAME)
docker exec -t src-postgres-1 pg_dump -U n8n n8n > n8n_backup.sql
```

### 2. 還原至新 VM

**在新 VM 上 (啟動服務後)：**
```bash
# 停止應用程式容器以防止寫入
docker compose stop codimd n8n

# 1. 還原 CodiMD 資料庫
# 注意：必須先刪除自動初始化的資料庫，否則會發生衝突
docker exec -i src-codimd-db-1 psql -U codimd -d postgres -c "DROP DATABASE codimd;"
docker exec -i src-codimd-db-1 psql -U codimd -d postgres -c "CREATE DATABASE codimd;"
cat codimd_backup.sql | docker exec -i src-codimd-db-1 psql -U codimd -d codimd

# 2. 還原 n8n 資料庫
# 注意：必須先刪除自動初始化的資料庫，否則會發生衝突
docker exec -i src-n8n-db-1 psql -U n8n -d postgres -c "DROP DATABASE n8n;"
docker exec -i src-n8n-db-1 psql -U n8n -d postgres -c "CREATE DATABASE n8n;"
cat n8n_backup.sql | docker exec -i src-n8n-db-1 psql -U n8n -d n8n

# 重新啟動服務
docker compose start codimd n8n
```

## 成本估算 💰

每月成本明細 (Azure B2s VM)：
- VM (B2s)：約 $29.20
- 儲存空間 (兩個 30GB Standard SSD 磁碟)：約 $5.00
- **總計：約 $34.20/月**

_比您的咖啡癮還便宜！☕_

## 維護

### 更新

更新服務到最新版本：
```bash
docker compose pull
docker compose up -d
```

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

可使用 cron 設定自動備份：
```bash
# 加入 crontab，每天午夜執行備份
(crontab -l 2>/dev/null; echo "0 0 * * * /path/to/backup.sh") | crontab -
```

## 安全性考量 🔒

1. **防火牆規則**：
   - Azure NSG 僅允許 80 (HTTP) 和 443 (HTTPS) 埠
   - 建議在初始設定後停用 SSH 埠 22 (改用 Azure Bastion)

2. **SSH 存取**：
   - 僅使用 SSH 金鑰驗證
   - 應停用密碼驗證

3. **應用程式安全性**：
   - 透過 Caddy 強制使用 HTTPS
   - 建議定期進行安全性更新
   - CodiMD 使用 Microsoft Entra ID (OAuth2) 進行驗證
   - n8n 支援內建驗證和雙因素驗證 (2FA)

## 疑難排解

### 無法連線到服務
- 檢查 Azure Portal 中的 VM 狀態
- 驗證 DNS 設定是否指向 VM IP
- 檢查容器：`docker compose ps`
- 查看日誌：`docker compose logs -f`

### 資料庫連線問題
- 檢查 PostgreSQL 日誌：`docker compose logs codimd-db` 或 `docker compose logs n8n-db`
- 驗證 `.env` 中的環境變數
- 確保資料庫容器正在運行

### SSL/HTTPS 問題
- 檢查 Caddy 日誌：`docker compose logs caddy`
- 驗證網域是否指向正確的 IP
- 確保 Azure NSG 中的 80 和 443 埠已開啟
- 本機測試時，可以暫時在 Caddyfile 的網站區塊中加入 `tls internal`

### n8n 雙因素驗證/登入問題
如果您從舊的 n8n 實例遷移後無法使用 2FA 登入：
1. 從舊實例取得加密金鑰：
   ```bash
   docker exec -t <舊容器名稱> cat /home/node/.n8n/config
   ```
2. 加入到 `.env`：
   ```bash
   N8N_ENCRYPTION_KEY=您的舊金鑰
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
3. 在原始專案中開啟 issue：
   - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter)
   - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc)
4. 造訪 [n8n 社群論壇](https://community.n8n.io/)

## 授權

此部署範本採用 MIT 授權。n8n 和 CodiMD 各自採用其各自的授權條款。


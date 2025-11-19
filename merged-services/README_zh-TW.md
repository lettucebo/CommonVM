# CodiMD 與 n8n 合併服務

此設定使用 Docker Compose 和 Caddy 作為反向代理，將 CodiMD 和 n8n 合併到單一 VM 上。

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
4. **啟動服務**：
   ```bash
   docker compose up -d
   ```
4. **驗證**：
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

# 還原 CodiMD 資料庫
cat codimd_backup.sql | docker exec -i merged-services-codimd-db-1 psql -U codimd -d codimd

# 還原 n8n 資料庫
cat n8n_backup.sql | docker exec -i merged-services-n8n-db-1 psql -U n8n -d n8n

# 重新啟動服務
docker compose start codimd n8n
```

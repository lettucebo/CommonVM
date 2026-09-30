# CodiMD 至 HedgeDoc v1 遷移

本手冊讓 CodiMD 2.6.1 與其 PostgreSQL 11 資料庫**持續運作**；HedgeDoc
1.12.0 使用獨立的 PostgreSQL 18.6 副本。不可把 HedgeDoc 連上
`codimd-db`，也不可未經另外核准就刪除 CodiMD、資料、備份、驗證資料庫或
snapshot。官方不保證 CodiMD 2.x 直接遷移成功：
<https://docs.hedgedoc.org/setup/getting-started/#migrating-from-codimd-hackmd>。
因此資料庫副本與全量連結比對是必要條件。

**完成 DB 備份與 Azure OS/data disk snapshot 之前，不修改 VM 或
DNS/Entra。** 建立 snapshot、變更 DNS／Entra、重啟 Caddy 與正式切換皆
先取得明確核准。密碼不可進 Git 或 log。VM 上在 Compose `src/` 目錄
執行 shell 指令；VM Run Command 可能沒有 `HOME`。每個 shell session
都應重新設定 `B`（含時間戳記的備份目錄）。每次 `docker exec` 前先以
`docker compose ps` 確認真正的容器名稱。可用 `az vm list -d -o table`
唯讀查出 Azure VM 與 Resource Group。

## 1. 容量與備份

```sh
free -h
df -h /mnt/data /
docker stats --no-stream
docker compose ps
```

`MemAvailable` 少於 900 MiB，或磁碟容不下第二套 Postgres、uploads 與
兩份 dump 時，停止並回報，不自行調整 VM 規格。以下以 `codimd`、`n8n`、
`outline` 為資料庫使用者及名稱；若 `.env` 不同，應依實際值替換。
執行者須有 Docker 與 `/mnt/data/backup` 寫入權限。

```sh
set -eu
STAMP=$(date -u +%Y%m%d-%H%M%S)
B="/mnt/data/backup/hedgedoc-mig-$STAMP"
mkdir -p "$B"
date -u +%FT%TZ > "$B/dump_started_at"
docker exec src-codimd-db-1 pg_dump -U codimd -d codimd -Fc --no-owner --no-privileges > "$B/codimd.dump"
docker exec src-n8n-db-1 pg_dump -U n8n -d n8n -Fc --no-owner --no-privileges > "$B/n8n.dump"
docker exec src-outline-db-1 pg_dump -U outline -d outline -Fc --no-owner --no-privileges > "$B/outline.dump"
sudo tar czf "$B/codimd-uploads.tar.gz" -C /mnt/data/codimd uploads
docker exec -i src-codimd-db-1 pg_restore --list < "$B/codimd.dump" > /dev/null
docker exec -i src-n8n-db-1 pg_restore --list < "$B/n8n.dump" > /dev/null
docker exec -i src-outline-db-1 pg_restore --list < "$B/outline.dump" > /dev/null
tar tzf "$B/codimd-uploads.tar.gz" > /dev/null
test -s "$B/codimd.dump" && test -s "$B/n8n.dump" && test -s "$B/outline.dump"
sha256sum "$B"/*.dump "$B"/*.gz > "$B/SHA256SUMS"
```

即使執行時網站仍可寫入，`pg_dump` 是一致時間點的資料；snapshot 為
**crash-consistent**，不能取代已驗證的 dump。工作站上確認後，使用
實際 VM/Resource Group 執行（同時保存 snapshot ID）：

```powershell
$rg = '<VM_RESOURCE_GROUP>'; $vm = '<VM_NAME>'; $stamp = Get-Date -Format yyyyMMdd-HHmmss
$os = az vm show -g $rg -n $vm --query storageProfile.osDisk.managedDisk.id -o tsv
$data = az vm show -g $rg -n $vm --query "storageProfile.dataDisks[].managedDisk.id" -o tsv
foreach ($id in @($os) + @($data)) {
    $name = ($id -split '/')[-1]
    az snapshot create -g $rg -n "$name-pre-hedgedoc-$stamp" --source $id --incremental true `
        --tags purpose=pre-hedgedoc-migration created=$stamp -o table
    if ($LASTEXITCODE -ne 0) { throw "Snapshot failed: $name" }
}
az snapshot list -g $rg --query "[?tags.purpose=='pre-hedgedoc-migration'].{name:name,state:provisioningState}" -o table
```

OS disk 與**每一顆** data disk 都要有成功的 snapshot；未取得核准前
全部保留。

## 2. 只還原到新資料庫

下列初次還原只適用**空資料庫**。若既有 staging 副本已存在，
不得還原到舊 DB；改用本節後面的 `hedgedoc_clean` 獨立修復流程。

在 `src/.env` 新增 `HEDGEDOC_STAGING_DOMAIN=hedgedoc.yu.money`、
`HEDGEDOC_STAGING_ALLOWED_IPS=<測試者 IP/CIDR>`、
`HEDGEDOC_DOMAIN=hedgedoc.yu.money`、`CODIMD_UPSTREAM=codimd:3000`、
`HEDGEDOC_DB_*` 及新的 `HEDGEDOC_SESSION_SECRET`。切換 app 所用
資料庫時，`HEDGEDOC_DB_INIT_NAME=hedgedoc` 不變；PostgreSQL 初始
資料庫不一定是 HedgeDoc 實際使用的資料庫，備份必須依
`HEDGEDOC_DB_NAME`。Entra username
欄位與 Azure Blob 設定沿用 CodiMD。首次重建 Caddy 前確認
staging 網域及 allowlist 正確：未設定網域會使用
`hedgedoc.localhost`，空白 allowlist 則拒絕所有 staging 請求。
副本中的筆記日後可能已在正式 CodiMD 被刪除或改為 private；
`CMD_ALLOW_ANONYMOUS=false` 並不限制公開筆記的讀取。
**不要**設定 `CMD_OAUTH2_USER_PROFILE_ID_ATTR`：現有的
`profileid` 就是 username。

```sh
cd /path/to/CommonVM/src
docker compose config --quiet
sudo mkdir -p /mnt/data/hedgedoc/db /mnt/data/hedgedoc/uploads /mnt/data/hedgedoc/empty-docs
sudo chown 70:70 /mnt/data/hedgedoc/db
sudo chown -R 10000:10000 /mnt/data/hedgedoc/uploads
test -z "$(find /mnt/data/hedgedoc/empty-docs -mindepth 1 -print -quit)" || {
  echo "HedgeDoc empty-docs directory is not empty" >&2; exit 1;
}
HD_DB=$(sed -n 's/^HEDGEDOC_DB_NAME=//p' .env)
case "$HD_DB" in ''|*[!A-Za-z0-9_]*) echo "Invalid HEDGEDOC_DB_NAME" >&2; exit 1 ;; esac
docker compose up -d hedgedoc-db
docker compose ps
# 等待 healthy；實際名稱以 docker compose ps 為準。
tables=$(docker compose exec -T hedgedoc-db psql -qX -tA -v ON_ERROR_STOP=1 \
  -U hedgedoc -d "$HD_DB" -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'") || exit 1
test "$tables" = 0 || { echo "Refusing to restore over an existing database" >&2; exit 1; }
docker exec -i src-hedgedoc-db-1 pg_restore -U hedgedoc -d "$HD_DB" \
  --no-owner --no-privileges --exit-on-error --single-transaction < "$B/codimd.dump" || exit 1
sudo cp -a /mnt/data/codimd/uploads/. /mnt/data/hedgedoc/uploads/
sudo chown -R 10000:10000 /mnt/data/hedgedoc/uploads
```

設定 `S="$PWD/srcipts/hedgedoc-migration"`；只對**副本**跑檢查 SQL
（若角色／資料庫名稱不同應替換）。`preflight-orphans.sql` 的四個值
必須全部為 0：HedgeDoc 的 `fix-account-deletion` migration 會刪除
孤兒筆記與 revisions。有非零值即**停止**、列出受影響 ID，先討論保留
方式，不得修改 CodiMD 正式資料庫。

```sh
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/preflight-orphans.sql"
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/preflight-pending-revisions.sql" > "$B/pending-revisions.txt"
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/note-fingerprint.sql" > "$B/before.fingerprint"
docker exec -i src-codimd-db-1 psql -qX -v ON_ERROR_STOP=1 -U codimd -d codimd < "$S/note-fingerprint.sql" > "$B/live.fingerprint"
```

對 `live` 與 `before` 做 `diff -u`；只容許 dump 以後有更新的筆記
出現差異，並列出 ID。比較兩邊 uploads 的檔案數與大小；唯讀查詢
`SELECT name FROM "SequelizeMeta" ORDER BY name`、
`SELECT to_regclass('"Temp"')`，記錄 migration 狀態。
HedgeDoc 1.12.0 的 alias GET 可能以較新的內建
`public/docs/<alias>.md` 覆寫資料庫筆記，因此唯讀的空 docs mount
不可在切換資料庫時移除。若先前副本已被覆寫，應保存原副本與其
dump，從原始 CodiMD dump **另建新資料庫**，不可刪除或覆寫舊副本。
針對這次已覆寫的 staging：只停止 `hedgedoc` app，確認
`hedgedoc-drift.dump` 已驗證後，在 `src/` 執行下列指令，`B`
指向原始已驗證備份；既有 `hedgedoc` 資料庫不動：

```sh
test -s "$B/codimd.dump" && test -s "$B/hedgedoc-drift.dump" || exit 1
docker compose ps hedgedoc hedgedoc-db codimd codimd-db
exists=$(docker compose exec -T hedgedoc-db psql -qX -tA -v ON_ERROR_STOP=1 \
  -U hedgedoc -d postgres -c "SELECT 1 FROM pg_database WHERE datname='hedgedoc_clean'") || exit 1
test -z "$exists" || { echo "hedgedoc_clean already exists" >&2; exit 1; }
docker compose exec -T hedgedoc-db createdb -U hedgedoc hedgedoc_clean || exit 1
docker compose exec -T hedgedoc-db pg_restore -U hedgedoc -d hedgedoc_clean \
  --no-owner --no-privileges --exit-on-error --single-transaction < "$B/codimd.dump" || exit 1
# 新副本通過上述 preflight 和 fingerprint 檢查後，才切換 app。
HD_DB=hedgedoc_clean
```

檢查通過後，`.env` 只改 `HEDGEDOC_DB_NAME=hedgedoc_clean`；
`HEDGEDOC_DB_INIT_NAME=hedgedoc` 保持不變。舊副本及其 dump
保留供稽核；第 3 節只啟 app，不重建 DB service。

## 3. 啟動 staging

另行核准後，新增 **Proxied** 的 `hedgedoc.yu.money` DNS record，並在
現有 Entra app registration 增加
`https://hedgedoc.yu.money/auth/oauth2/callback`；不要移除既有
redirect URI（Outline 也使用此 app）。拜訪任何副本筆記前，從允許的
測試者 IP 與**不在清單內**的 IP 分別驗證 staging allowlist。

```sh
HD_DB=$(sed -n 's/^HEDGEDOC_DB_NAME=//p' .env)
case "$HD_DB" in ''|*[!A-Za-z0-9_]*) echo "Invalid HEDGEDOC_DB_NAME" >&2; exit 1 ;; esac
docker compose --profile hedgedoc up -d --no-deps hedgedoc
docker compose ps
docker compose logs --tail=200 hedgedoc
# Caddy 的 environment 改了；須先核准 recreate。
docker compose up -d caddy
docker compose logs --tail=100 caddy
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/note-fingerprint.sql" > "$B/after.fingerprint"
free -h; docker stats --no-stream
```

任何 migration error 都應停止。既有 Notes/Users/Authors/Revisions
必須與啟動前副本指紋相同，但 pending revision save 可對
`pending-revisions.txt` 中的筆記新增 Revisions 並清空其前一筆
revision 的 `content`；**既有 Notes.content 不得改動**。
其他任何異動都須調查。確認 CodiMD、n8n、Outline、
Open WebUI 仍可正常存取。
啟動健康後先保存 post-start 指紋；對與 image `public/docs` 同名
的所有 alias 做 GET 後，再保存 post-GET 指紋，兩者須逐位元相同。
只在啟動尚未完成前取第一次指紋，無法證明 GET 不會覆寫筆記。
對受保護備份中的 `changed-aliases.txt` 所列 4 個 alias 從
`src_web` 內網逐條 GET，然後執行：

```sh
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "${HD_DB:?Set HD_DB from .env}" < "$S/note-fingerprint.sql" > "$B/post-get.fingerprint"
diff -u "$B/after.fingerprint" "$B/post-get.fingerprint" || exit 1
```

## 4. 全量比對既有短網址與筆記連結

從 AkaMoney D1 `akamoney-clicks` **唯讀**取得清單；Wrangler 未安裝時
使用指定的 proxy registry，不自動改用官方 registry。
在 `C:\Source\Repos\AkaMoney\src\backend`：

```powershell
npx wrangler d1 execute akamoney-clicks --remote --json --command `
  "SELECT short_code, original_url, is_active, expires_at FROM urls WHERE original_url LIKE '%<CODIMD_DOMAIN>%' ORDER BY short_code"
```

短碼、完整目標 path 與 query（排除 URL fragment）存於受保護的備份
目錄；不得把筆記內容／憑證提交到 Git。從副本產生所有 note ID、
alias、published、slide、action 與 revision path：

```sh
HD_DB=$(sed -n 's/^HEDGEDOC_DB_NAME=//p' .env)
case "$HD_DB" in ''|*[!A-Za-z0-9_]*) echo "Invalid HEDGEDOC_DB_NAME" >&2; exit 1 ;; esac
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/build-link-inventory.sql" > "$B/db-paths.txt"
# 將 db-paths.txt 與 AkaMoney 的原始 paths 合併至 paths.txt；
# 保留 query string；確認 AkaMoney 筆數與 SELECT 結果相同。
sort -u "$B/db-paths.txt" "$B/aka-paths.txt" > "$B/paths.txt"
docker run --rm -i --network src_web --entrypoint sh \
  -e A_HOST="<CODIMD_DOMAIN>" -e B_HOST="hedgedoc.yu.money" \
  -v "$S:/work:ro" \
  curlimages/curl:latest /work/compare-note-links.sh /dev/stdin \
  < "$B/paths.txt" > "$B/links.tsv"
```

`ERROR` 必須為零；逐一調查 `DIFF`。`title-brand` 表示筆記標題相同，
僅瀏覽器標題的 ` - CodiMD`／` - HedgeDoc` 後綴不同；真正的標題異動
仍判失敗。AkaMoney 的連結 **100% OK**。
HedgeDoc 沒有 `/pdf`、`/pandoc`：切換前逐條列出並向使用者取得
明確決定，即使該連結不在 AkaMoney。dump 後的新異動需要在切換時
重新同步資料並比對；也要經 Cloudflare/Caddy 測試每條 AkaMoney
短網址的最終重導。

Agent 必須親自以 Playwright 測試真實 staging 網站並由使用者互動完成
Entra 登入。抽查 10–15 篇：private、limited、alias、shortid、CJK、
Mermaid、表格、Azure Blob 圖片、revisions 與 history。測試未登入的
私密短網址 → 登入 → 回到同篇筆記；檢查 user ID、筆記擁有者及
Users 筆數（不可新增重複帳號）。markmap 與部分 CodiMD fence 的
渲染不同，但 Markdown 原文不得改變。新 session secret 會要求
所有使用者重新登入。

## 5. 另行核准後才切換

1. 取得明確核准，含每條不相容連結的決定。將**兩個** Caddy site
   block 暫時改成 `respond "Maintenance" 503`；
   `docker compose restart caddy`（bind-mounted Caddyfile 不會因
   `up -d` 自動重載）；驗證兩個公開網域回 503，正式資料庫
   Notes 修改時間連續五分鐘無變動。CodiMD **容器持續運作**。
2. 重做第 1 節備份，使用新時間戳記；只在 `src-hedgedoc-db-1`
   建立 `hedgedoc_prod`，還原新 dump，重跑 orphan/pending-revision
   預檢；複製新增 uploads 至獨立 HedgeDoc uploads 目錄。不要
   覆蓋或刪除 staging DB。
3. `.env` 改 `HEDGEDOC_DB_NAME=hedgedoc_prod`、
   `HEDGEDOC_DOMAIN=<CODIMD_DOMAIN>`，然後
   `docker compose --profile hedgedoc up -d --no-deps hedgedoc`。完整重跑
   fingerprint 與連結比對（`B_HOST=<CODIMD_DOMAIN>`），不能有
   非預期差異。保存 `cutover-baseline.fingerprint`。
4. **開放流量前**記錄 `CUTOVER_AT`。設定
   `CODIMD_UPSTREAM=hedgedoc:3000`、恢復原網域 Caddy reverse proxy，
   但 staging block **繼續 503**；`docker compose up -d caddy`
   重建後驗證 upstream env、公開短網址、登入及其他站點。

**回退不能只改 upstream；需要核准與對帳。** 兩個公開網域先回
503，等待 HedgeDoc 寫入停止，備份並驗證 `hedgedoc_prod`；與
`cutover-baseline.fingerprint` 完整比對，包括內容、標題、權限、
alias、owner、刪除、authorship 與 revisions。匯出新增／變更的筆記，
逐筆確認處置方式，尤其是隱私設定與刪除。完成後才將
`CODIMD_UPSTREAM` 改回 `codimd:3000` 並重建 Caddy。所有資料庫、
uploads 與 snapshot 保留到使用者另外明確核准為止。

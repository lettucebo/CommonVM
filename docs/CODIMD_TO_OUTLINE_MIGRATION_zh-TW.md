# CodiMD 至 Outline 遷移

本操作手冊會在 CodiMD 持續運作的情況下遷移筆記內容，不會刪除任何
資料庫或檔案。

## 範圍與基準

- 來源：CodiMD 共 230 篇，其中遷移 218 篇非空白筆記。
- 不遷移：CodiMD 使用者、每篇權限與 5,725 筆 revision。
- 目的端可見性：私密。匯入期間不得啟用 **Publish to web**。
- 遷移完成後 CodiMD 仍保持運作。

匯入前，先依根目錄 README 建立並驗證 PostgreSQL 備份。

## 重建 Redis 前先啟用 AOF

若執行中的 Redis 原本只使用 RDB，不可直接以 `appendonly yes` 重建。
Redis 可能優先尋找尚不存在的 AOF、略過既有 RDB，並以空白 queue 啟動。

套用新版 Compose 前，先確認沒有排隊中的 import，再針對執行中的資料集
啟用 AOF：

```bash
docker exec src-outline-db-1 psql -U outline -d outline -Atc \
  'SELECT count(*) FROM imports;'
# 第一次遷移前預期為：0

docker exec src-outline-redis-1 redis-cli CONFIG SET appendonly yes
docker exec src-outline-redis-1 redis-cli INFO persistence \
  | grep -E 'aof_enabled|aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status'
docker exec src-outline-redis-1 ls /data/appendonlydir
```

只有在 `aof_enabled:1`、`aof_rewrite_in_progress:0` 且
`aof_rewrite_scheduled:0`、`aof_last_bgrewrite_status:ok`，且
`appendonlydir` 列目錄成功時才能繼續。接著套用 Compose、等待 Outline stack
全部 healthy，最後才開始匯入。

## 匯出驗證

將 `Notes.content` 匯出為 UTF-8 Markdown，並保留含 CodiMD note ID、
檔名、年份與字元數的 manifest。

只有下列數字全部與來源資料庫一致時，匯出才算有效：

```text
筆記：          218
字元：          1,659,018
空白檔案：      0
無效 UTF-8：    0
```

不可只相信檔案數。PostgreSQL `encode(..., 'base64')` 每 76 字元會加入
MIME 換行；若使用逐行匯出格式，必須先移除這些換行。

## 已知 Markdown 降級

預掃描結果：

| 語法 | 筆記數 | Outline 行為 |
|---|---:|---|
| `:::` containers | 49 | 不會渲染 |
| `markmap` fences | 14 | 不會渲染 |
| Mermaid | 2 | 支援 |
| 表格 | 23 | 支援 |
| 其他 CodiMD 特殊 fence／embed | 各 1 | 不會渲染 |

必須保留原始 Markdown 匯出，作為可回復來源。

## 圖片基準

100 篇筆記引用 Azure Blob URL。來源共出現 9 個 storage account，其中
5 個已無法解析，屬於 CodiMD 現存的既有缺陷。所有 URL 原樣保留，
避免遷移造成額外破圖。不可移除任何仍存活的 Azure storage account。

## 匯入

在匯入與 privacy 驗證完成前，不允許其他使用者登入。匯入前立即記錄
資源基準：

```bash
free -h
docker stats --no-stream
```

1. 建立一個 ZIP，根目錄剛好包含 218 個 Markdown 檔。
   檔名前綴來源年份，不建立年份資料夾；Outline 可能把資料夾轉成額外
   的父文件。
2. 在 Outline 開啟 **Settings → Import → Markdown**。
3. 選擇 ZIP，將 **Permission** 從預設的 **Can edit** 改成
   **No access**（最嚴格選項），並保持 Collection 未公開。
4. 匯入只執行一次；重跑同一 ZIP 可能建立重複文件。
5. 匯入進入終態前，持續檢查 `free -h`、`docker stats --no-stream`
   與 Outline logs。

## 非破壞性驗證

執行唯讀查詢：

```bash
docker exec src-outline-db-1 psql -U outline -d outline -c \
'SELECT c.name, c.permission, count(d.id)
 FROM documents d
 JOIN collections c ON c.id = d."collectionId"
 WHERE d."deletedAt" IS NULL
 GROUP BY c.name, c.permission
 ORDER BY c.name;'
```

匯入 Collection 必須剛好有 218 篇文件，且 `permission` 必須是 `NULL`
（私密）。

若 `permission` 不是 `NULL`，不得邀請或允許其他使用者進入 workspace。
先在 Outline 修正 Collection permission 後才能恢復存取；不得刪除文件
再重新匯入。

確認未建立公開分享：

```bash
docker exec src-outline-db-1 psql -U outline -d outline -c \
'SELECT count(*) AS published_shares
 FROM shares
 WHERE published = true AND "revokedAt" IS NULL;'
```

另外驗證：

- 抽查 10–15 篇，涵蓋 CJK、Mermaid、表格、Blob 圖片、`:::` container
  與 markmap。
- CodiMD 與 n8n 仍回傳 HTTP 200。
- Outline 保持 healthy，且 import job 沒有失敗。

驗收後仍保留 CodiMD。未來移除屬於另一個必須另外明確核准的階段。

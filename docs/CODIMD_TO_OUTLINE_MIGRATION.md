# CodiMD to Outline Migration

This runbook migrates note content while keeping CodiMD running. It never
deletes a database or file.

## Scope and baseline

- Source: 230 CodiMD notes; 218 non-empty notes are migrated.
- Not migrated: CodiMD users, per-note permissions, or 5,725 revisions.
- Destination visibility: private. Do not enable **Publish to web** during
  import.
- CodiMD remains available after migration.

Before importing, create and verify PostgreSQL backups as described in the
root README.

## Enable Redis AOF before recreating Redis

If the running Redis container previously used RDB only, do not recreate it
with `appendonly yes` immediately. Redis may prefer a missing AOF over the
existing RDB and start with an empty queue.

Before applying the new Compose configuration, confirm no import is queued,
then enable AOF against the running dataset:

```bash
docker exec src-outline-db-1 psql -U outline -d outline -Atc \
  'SELECT count(*) FROM imports;'
# Expected before the first migration: 0

docker exec src-outline-redis-1 redis-cli CONFIG SET appendonly yes
docker exec src-outline-redis-1 redis-cli INFO persistence \
  | grep -E 'aof_enabled|aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status'
docker exec src-outline-redis-1 ls /data/appendonlydir
```

Continue only when `aof_enabled:1`, `aof_rewrite_in_progress:0`, and
`aof_rewrite_scheduled:0`, `aof_last_bgrewrite_status:ok`, and the
`appendonlydir` listing succeeds. Then apply Compose, wait for the Outline
stack to become healthy, and only afterward start the import.

## Export verification

Export `Notes.content` as UTF-8 Markdown and retain a manifest containing the
CodiMD note ID, filename, year, and character count.

The export is acceptable only when all checks match the source database:

```text
notes:       218
characters:  1,659,018
empty files: 0
invalid UTF-8 files: 0
```

Do not trust file count alone. PostgreSQL `encode(..., 'base64')` inserts MIME
line breaks every 76 characters; strip those line breaks before using a
line-oriented export format.

## Known Markdown degradation

The pre-scan found:

| Syntax | Notes | Outline behavior |
|---|---:|---|
| `:::` containers | 49 | not rendered |
| `markmap` fences | 14 | not rendered |
| Mermaid | 2 | supported |
| tables | 23 | supported |
| other CodiMD-specific fences/embeds | 1 each | not rendered |

Preserve the original Markdown export as the recovery source.

## Image baseline

100 notes reference Azure Blob URLs. Nine storage accounts appear in the
source; five no longer resolve, which is a pre-existing CodiMD defect. Keep
all URLs unchanged so migration does not introduce additional breakage.
Do not remove any surviving Azure storage account.

## Import

Do not allow other users to sign in until import and privacy verification are
complete. Immediately before importing, record the resource baseline:

```bash
free -h
docker stats --no-stream
```

1. Build one ZIP containing exactly 218 Markdown files at the ZIP root.
   Prefix filenames with the source year instead of creating year directories;
   Outline may turn directories into additional parent documents.
2. In Outline, open **Settings → Import → Markdown**.
3. Select the ZIP. Change **Permission** from the default **Can edit** to
   **No access** (the most restrictive option), and leave the collection
   unpublished.
4. Start the import once. Re-running the same ZIP can create duplicates.
5. Keep monitoring `free -h`, `docker stats --no-stream`, and Outline logs
   until the import reaches a terminal state.

## Non-destructive verification

Run read-only queries:

```bash
docker exec src-outline-db-1 psql -U outline -d outline -c \
'SELECT c.name, c.permission, count(d.id)
 FROM documents d
 JOIN collections c ON c.id = d."collectionId"
 WHERE d."deletedAt" IS NULL
 GROUP BY c.name, c.permission
 ORDER BY c.name;'
```

The imported collection must contain exactly 218 documents and its
`permission` must be `NULL` (private).

If `permission` is not `NULL`, do not invite or allow any other user into the
workspace. Correct the collection permission through Outline before resuming
access; do not delete and re-import the documents.

Confirm no public shares were created:

```bash
docker exec src-outline-db-1 psql -U outline -d outline -c \
'SELECT count(*) AS published_shares
 FROM shares
 WHERE published = true AND "revokedAt" IS NULL;'
```

Also verify:

- 10–15 representative notes, including CJK, Mermaid, tables, Blob images,
  `:::` containers, and markmap.
- CodiMD and n8n still return HTTP 200.
- Outline remains healthy and no import job failed.

Keep CodiMD running after acceptance. Any future retirement is a separate,
explicitly approved phase.

# CodiMD to HedgeDoc 1.x migration

This runbook keeps CodiMD 2.6.1 **and its PostgreSQL 11 database** running.
HedgeDoc 1.12.0 runs against an independent copy in PostgreSQL 18.6.
Do not connect HedgeDoc to `codimd-db`, remove CodiMD, or delete any data,
backup, verification database, or snapshot without separate approval.
HedgeDoc does not officially guarantee migration from CodiMD 2.x:
<https://docs.hedgedoc.org/setup/getting-started/#migrating-from-codimd-hackmd>.
The independent database and full link comparison are mandatory, not optional.

**No VM changes or DNS/Entra edits before the database backup and both Azure
disk snapshots succeed.** Get explicit approval before snapshots, DNS/Entra
changes, Caddy restart, and the final cutover. Keep passwords out of logs and Git.
Run shell commands on the VM from its Compose `src/` directory; VM Run Command
may not set `HOME`. Set `B` to the timestamped backup directory in every session.
Use `docker compose ps` to confirm actual container names before each `docker exec`.
An initial Azure VM/VM resource group lookup is read-only (`az vm list -d -o table`).

## 1. Establish capacity and backups

```sh
free -h
df -h /mnt/data /
docker stats --no-stream
docker compose ps
```

Stop if `MemAvailable` is below 900 MiB, or disk space cannot hold a second
Postgres cluster, uploaded files and two dumps. Do not change the VM size
implicitly. For the initial baseline, export all three databases using the
server's own `pg_dump`. Replace `codimd`, `n8n`, `outline` below with the actual
database names/users from `.env` when different. Run as a user who can access
Docker and `/mnt/data/backup`.

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

The dump may be consistent at a point in time while the app is live; snapshot
is **crash-consistent**, not a replacement for the verified dumps. On the
workstation, after approval, use the actual VM and resource group:

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

Confirm one successful snapshot for the OS disk **and each data disk**; keep
their IDs with the dump manifest. Do not delete them automatically.

## 2. Restore only to the new database

The initial restore below is only for an empty database. If a previous
staging copy already exists, do **not** restore into it; follow the separate
`hedgedoc_clean` recovery procedure later in this section instead.

Update `src/.env` with `HEDGEDOC_STAGING_DOMAIN=hedgedoc.yu.money`,
`HEDGEDOC_STAGING_ALLOWED_IPS=<tester IP/CIDRs>`,
`HEDGEDOC_DOMAIN=hedgedoc.yu.money`, `CODIMD_UPSTREAM=codimd:3000`,
`HEDGEDOC_DB_*` and a fresh `HEDGEDOC_SESSION_SECRET`. Keep
`HEDGEDOC_DB_INIT_NAME=hedgedoc` when switching the application to another
restored database: PostgreSQL's initialization database is not necessarily
the one HedgeDoc uses. Backups must target `HEDGEDOC_DB_NAME`. Keep the Entra profile
username attribute and Azure Blob settings identical to CodiMD. Before the
first Caddy recreation, ensure the staging domain and the IP allowlist
are correct: an unset hostname falls back to `hedgedoc.localhost`, and an
empty allowlist denies all staging requests. Restrict access because a
copied note may subsequently be deleted or made private in live CodiMD;
HedgeDoc's `CMD_ALLOW_ANONYMOUS=false` does not restrict public note reads.
Do not set
`CMD_OAUTH2_USER_PROFILE_ID_ATTR`: the username is the existing profile ID.

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
# Wait for healthy; use the actual name printed by docker compose ps.
tables=$(docker compose exec -T hedgedoc-db psql -qX -tA -v ON_ERROR_STOP=1 \
  -U hedgedoc -d "$HD_DB" -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'") || exit 1
test "$tables" = 0 || { echo "Refusing to restore over an existing database" >&2; exit 1; }
docker exec -i src-hedgedoc-db-1 pg_restore -U hedgedoc -d "$HD_DB" \
  --no-owner --no-privileges --exit-on-error --single-transaction < "$B/codimd.dump" || exit 1
sudo cp -a /mnt/data/codimd/uploads/. /mnt/data/hedgedoc/uploads/
sudo chown -R 10000:10000 /mnt/data/hedgedoc/uploads
```

Set `S="$PWD/srcipts/hedgedoc-migration"`. Run the SQL on the **copy**
(replace role/database names if customized). All four orphan counts must be
zero: HedgeDoc's `fix-account-deletion` migration deletes orphaned notes and
revisions. A nonzero count is a **stop**; report the affected IDs and decide
how to preserve them before proceeding, without modifying CodiMD.

```sh
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/preflight-orphans.sql"
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/preflight-pending-revisions.sql" > "$B/pending-revisions.txt"
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/note-fingerprint.sql" > "$B/before.fingerprint"
docker exec -i src-codimd-db-1 psql -qX -v ON_ERROR_STOP=1 -U codimd -d codimd < "$S/note-fingerprint.sql" > "$B/live.fingerprint"
```

Compare live vs copy (`diff -u`): only notes changed **since the dump** can
differ; inventory them. Check upload count and sizes in both directories.
Read-only `SELECT name FROM "SequelizeMeta" ORDER BY name` and
`SELECT to_regclass('"Temp"')` on the copy document the migration state.
HedgeDoc 1.12.0 can overwrite DB notes on an alias GET if a newer bundled
`public/docs/<alias>.md` exists. The empty, read-only docs mount is required:
do not remove it when switching databases. If an older staging copy was
already overwritten, preserve it and its dump; restore the original CodiMD
dump into a **new** database instead of deleting or repairing the old copy.
For the affected staging instance, after stopping only `hedgedoc` and
verifying `hedgedoc-drift.dump`, run the following from `src/` with `B`
pointing to the original verified backup. The original `hedgedoc` database
remains untouched:

```sh
test -s "$B/codimd.dump" && test -s "$B/hedgedoc-drift.dump" || exit 1
docker compose ps hedgedoc hedgedoc-db codimd codimd-db
exists=$(docker compose exec -T hedgedoc-db psql -qX -tA -v ON_ERROR_STOP=1 \
  -U hedgedoc -d postgres -c "SELECT 1 FROM pg_database WHERE datname='hedgedoc_clean'") || exit 1
test -z "$exists" || { echo "hedgedoc_clean already exists" >&2; exit 1; }
docker compose exec -T hedgedoc-db createdb -U hedgedoc hedgedoc_clean || exit 1
docker compose exec -T hedgedoc-db pg_restore -U hedgedoc -d hedgedoc_clean \
  --no-owner --no-privileges --exit-on-error --single-transaction < "$B/codimd.dump" || exit 1
# Only switch the app after the new copy passes the preflight and fingerprint checks above.
HD_DB=hedgedoc_clean
```

After the checks pass, change only `HEDGEDOC_DB_NAME=hedgedoc_clean` in
`.env`; leave `HEDGEDOC_DB_INIT_NAME=hedgedoc`. The earlier restored database
and its verified dump remain available for audit. The app-only start in
section 3 must not recreate the database service.

## 3. Bring up staging

After separate approval, add the proxied `hedgedoc.yu.money` DNS record and
`https://hedgedoc.yu.money/auth/oauth2/callback` to the **existing** Entra
app registration (Outline also uses it). Keep existing redirect URIs. Verify
the staging allowlist permits **only** tester IPs, including a negative test
from outside the list, before visiting any copied note.

```sh
HD_DB=$(sed -n 's/^HEDGEDOC_DB_NAME=//p' .env)
case "$HD_DB" in ''|*[!A-Za-z0-9_]*) echo "Invalid HEDGEDOC_DB_NAME" >&2; exit 1 ;; esac
docker compose --profile hedgedoc up -d --no-deps hedgedoc
docker compose ps
docker compose logs --tail=200 hedgedoc
# The Caddy environment changed; approve this recreation first.
docker compose up -d caddy
docker compose logs --tail=100 caddy
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/note-fingerprint.sql" > "$B/after.fingerprint"
free -h; docker stats --no-stream
```

Stop if migration errors occur. Existing Notes/Users/Authors/Revisions must
match the pre-start copy fingerprint except for pending revision saves:
HedgeDoc may create **new** Revisions and clear the prior revision's
`content` only for note IDs in `pending-revisions.txt`; no existing
`Notes.content` may change. Investigate all other changes.
After startup is healthy, save a post-start fingerprint. GET every alias
whose name exists in the image's `public/docs` directory, then save a
post-GET fingerprint: they must match byte-for-byte. A first fingerprint
taken before startup fully completes cannot certify that alias GETs are safe.
For the four affected aliases listed in the protected backup's
`changed-aliases.txt`, access each on the internal `src_web` network, then
run the following:

```sh
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "${HD_DB:?Set HD_DB from .env}" < "$S/note-fingerprint.sql" > "$B/post-get.fingerprint"
diff -u "$B/after.fingerprint" "$B/post-get.fingerprint" || exit 1
```
Confirm CodiMD, n8n, Outline and Open WebUI still work.

## 4. Check every existing short URL and note URL

Fetch AkaMoney's URL list **read-only** from its D1 `akamoney-clicks` database;
use the configured proxy registry when Wrangler is not already installed.
In `C:\Source\Repos\AkaMoney\src\backend`:

```powershell
npx wrangler d1 execute akamoney-clicks --remote --json --command `
  "SELECT short_code, original_url, is_active, expires_at FROM urls WHERE original_url LIKE '%<CODIMD_DOMAIN>%' ORDER BY short_code"
```

Store the short-code inventory and exact destination path + query (omit URL
fragment) in the protected backup directory; no note data or credentials
into Git. From the copy, generate all note ID / alias / published / slide /
action / revision paths:

```sh
HD_DB=$(sed -n 's/^HEDGEDOC_DB_NAME=//p' .env)
case "$HD_DB" in ''|*[!A-Za-z0-9_]*) echo "Invalid HEDGEDOC_DB_NAME" >&2; exit 1 ;; esac
docker exec -i src-hedgedoc-db-1 psql -qX -v ON_ERROR_STOP=1 -U hedgedoc -d "$HD_DB" < "$S/build-link-inventory.sql" > "$B/db-paths.txt"
# Merge db-paths.txt with the exact AkaMoney paths into paths.txt;
# deduplicate without losing query strings. Ensure the AkaMoney count matches
# the SELECT result count before accepting the list.
sort -u "$B/db-paths.txt" "$B/aka-paths.txt" > "$B/paths.txt"
docker run --rm -i --network src_web --entrypoint sh \
  -e A_HOST="<CODIMD_DOMAIN>" -e B_HOST="hedgedoc.yu.money" \
  -v "$S:/work:ro" \
  curlimages/curl:latest /work/compare-note-links.sh /dev/stdin \
  < "$B/paths.txt" > "$B/links.tsv"
```

Do not accept any `ERROR`; investigate every `DIFF`. `title-brand` means the
note title is identical except for the expected ` - CodiMD` / ` - HedgeDoc`
browser-title suffix; changed note titles still fail. All AkaMoney paths
must be `OK`. `/pdf` and `/pandoc` do not exist in HedgeDoc: inventory these
and request an explicit decision **per affected link** before cutover, even
when AkaMoney does not contain it. Live changes after the dump must be
rechecked with a fresh copy at cutover. Exercise each AkaMoney redirect via
Cloudflare/Caddy as well as direct-container comparison.

The agent must personally test the real staging site using Playwright after
interactive Entra login. Sample 10–15 notes: private, limited, aliases,
shortids, CJK, Mermaid, tables, Azure Blob images, revisions and history.
Test logged-out private link → login → same note; verify user ID and ownership
did not change and no duplicate Users appeared. Markmap and some CodiMD
fences are known rendering differences; the Markdown source must remain
unchanged. A new HedgeDoc session secret means users must log in again.

## 5. Cutover only after a separate decision

1. Obtain explicit approval, including decisions about each incompatible
   link. Temporarily replace **both** Caddy site blocks with `respond
   "Maintenance" 503`; `docker compose restart caddy` (a bind-mounted
   Caddyfile alone is not reloaded). Check both public hosts return 503;
   wait until live Notes modification times stay unchanged for five minutes.
   CodiMD **containers remain running**.
2. Repeat step 1 backups with a new timestamp. `createdb hedgedoc_prod`
   **on `src-hedgedoc-db-1` only**, restore the new CodiMD dump there, and
   rerun orphan/pending-revision preflights. Copy new uploads to the separate
   HedgeDoc upload folder. Do not overwrite or delete the staging database.
3. Set `HEDGEDOC_DB_NAME=hedgedoc_prod` and
   `HEDGEDOC_DOMAIN=<CODIMD_DOMAIN>` in `.env`, then
   `docker compose --profile hedgedoc up -d --no-deps hedgedoc`. Rerun the full
   fingerprint and link comparison (set `B_HOST=<CODIMD_DOMAIN>`); no
   unexpected differences allowed. Save a `cutover-baseline.fingerprint`.
4. Record `CUTOVER_AT` **before opening traffic**. Set
   `CODIMD_UPSTREAM=hedgedoc:3000`; restore the original-domain Caddy
   reverse proxy, but **leave the staging block at 503**; recreate Caddy
   with `docker compose up -d caddy`. Verify its upstream environment,
   public short links, login and each other proxied service.

**Rollback requires approval and reconciliation, not merely an upstream
change.** Freeze both public hosts at 503, wait for HedgeDoc writes to settle,
dump/verify `hedgedoc_prod`, and diff a new full fingerprint against
`cutover-baseline.fingerprint` (note text, title, permission, alias, owner,
deletion, authorship and revisions). Preserve/export changed notes and decide
how to handle each change, especially privacy/deletions. Only then point
`CODIMD_UPSTREAM` back to `codimd:3000` and recreate Caddy. Keep both
databases, uploads and snapshots until explicitly authorized otherwise.

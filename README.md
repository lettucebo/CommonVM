# Common Services

This setup combines CodiMD, Outline, n8n, Open WebUI, Cloudflare Tunnel, and RustDesk onto a single VM using Docker Compose. Caddy remains the reverse proxy for CodiMD, n8n, and Outline only.

> **Note**: This project merges multiple deployments:
> - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter) - n8n workflow automation
> - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc) - Collaborative markdown editor
> - [Outline](https://github.com/outline/outline) - Team knowledge base, being introduced to replace CodiMD
> - [Open WebUI](https://github.com/open-webui/open-webui) - Self-hosted chat and RAG UI, published through a dedicated Cloudflare Tunnel
> - [RustDesk Server](https://github.com/rustdesk/rustdesk-server) - Self-hosted remote desktop relay

> **Open WebUI publishing model**: Open WebUI is **not** routed by Caddy. It is published through a dedicated Cloudflare Tunnel and protected by Cloudflare Access, so no additional inbound NSG port is required and the existing Caddy routes stay unchanged.

## Prerequisites

- Azure VM (Ubuntu recommended)
- Docker and Docker Compose installed
- Public IP address for the Caddy and RustDesk surfaces
- DNS records pointing to the VM IP, one per Caddy-routed service (see `.env`):
  - CodiMD (`CODIMD_DOMAIN`)
  - n8n (`N8N_DOMAIN`)
  - Outline (`OUTLINE_DOMAIN`)
- Cloudflare Zero Trust account and active zone for the dedicated Open WebUI hostname (`OPENWEBUI_DOMAIN`)
- Microsoft Entra tenant for a **dedicated** Open WebUI app registration
- Microsoft Foundry chat and embedding deployments reachable through an OpenAI-compatible `/openai/v1` base URL
- Dedicated Azure Storage Account and private Blob container for Open WebUI uploads
- Ports open in Azure Network Security Group (NSG):
  - **80, 443** (HTTP/HTTPS for Caddy)
  - **21114-21119 TCP** (RustDesk)
  - **21116 UDP** (RustDesk)

> **Cloudflare upload limit**: Cloudflare documents a **100 MB** maximum proxied request body on Free and Pro plans. Check the current limits before enabling large uploads: <https://developers.cloudflare.com/workers/platform/limits/>

## Install Docker (Ubuntu 24.04 LTS)

If you haven't installed Docker yet, run the following commands to install Docker Engine and Docker Compose:

```bash
# 1. Install necessary dependencies (including git, curl, gnupg)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git

# 2. Set up Docker's apt repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# 3. Install Docker packages (includes docker-compose-plugin)
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Add user to the docker group (to avoid using sudo)
sudo usermod -aG docker $USER
newgrp docker
```

## Setup

1. **Mount Data Disk**:
   Based on your `lsblk` output, `sdc` (32G) is your data disk but it is not mounted. `sdb` (16G) is the Azure temporary disk; **DO NOT** store data on `sdb` as it is wiped on reboot.

   Run the following commands to format and mount `sdc` to `/mnt/data`:

   ```bash
   # 1. Format the disk (using XFS or ext4)
   sudo mkfs.xfs /dev/sdc

   # 2. Create mount point
   sudo mkdir -p /mnt/data

   # 3. Mount the disk
   sudo mount /dev/sdc /mnt/data

   # 4. Configure auto-mount on boot
   # Get UUID
   sudo blkid /dev/sdc
   # Add UUID to /etc/fstab (Replace <UUID> with the actual UUID)
   # echo "UUID=<UUID> /mnt/data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
   ```

   > **Tip**: You can use `df -h` or `lsblk` to verify the mount.
2. **Copy Files**: Transfer this directory (`src`) to your VM.
3. **Configure Environment**:
   - Copy `.env.example` to `.env`, then replace every placeholder.
   - `ACME_EMAIL` is required; an empty value makes Caddy reject its
     configuration and all proxied services become unavailable.
   - Set `CADDY_TLS` explicitly: leave it empty for automatic Let's Encrypt,
     or use `tls internal` only when an upstream proxy accepts a self-signed
     origin certificate.
   - Configure all `OUTLINE_*` values before starting Outline. Generate
     `OUTLINE_SECRET_KEY` and `OUTLINE_UTILS_SECRET` independently with
     `openssl rand -hex 32`.
   - Outline v1.10.0 initially names the workspace `Outline`; rename it after
     the first sign-in from **Settings → Details**.
   - `OUTLINE_FILE_STORAGE_UPLOAD_MAX_SIZE` defaults to 10 MiB in this
     configuration. Increase it only after considering VM memory and disk
     capacity.
   - Configure every `OPENWEBUI_*` and `CLOUDFLARED_*` placeholder before the
     first Open WebUI boot.
   - **Important**: Update `DATA_ROOT` in `.env` to point to your mounted disk path (default: `/mnt/data`).
4. **Fix Folder Permissions**:
   Since container user IDs (UID) may differ from the host, run the following commands to fix folder permissions and avoid `Permission denied` errors:

   ```bash
   # Fix n8n folder permissions (UID 1000)
   sudo chown -R 1000:1000 /mnt/data/n8n

   # Fix CodiMD folder permissions (UID 1500)
   sudo chown -R 1500:1500 /mnt/data/codimd

   # Fix Outline folder permissions (UID 1001, the image's "nodejs" user)
   sudo mkdir -p /mnt/data/outline/data /mnt/data/outline/db /mnt/data/outline/redis
   sudo chown -R 1001:1001 /mnt/data/outline/data
   ```
5. **Create RustDesk Data Directory**:
   ```bash
   sudo mkdir -p /mnt/data/rustdesk/data
   ```
6. **Start Services**:
   ```bash
   docker compose up -d
   ```
7. **Verification (Before DNS Switch)**:
   If you haven't pointed DNS to this VM yet, follow these steps for local verification:

   **A. Modify Local Hosts File**
   On your computer (not the Azure VM), modify the hosts file to point domains to the VM's public IP:
   - **Windows**: `C:\Windows\System32\drivers\etc\hosts` (requires administrator privileges)
   - **Mac/Linux**: `/etc/hosts` (requires sudo)

   Add the following:
   ```text
   <VM_PUBLIC_IP> <CODIMD_DOMAIN>
   <VM_PUBLIC_IP> <N8N_DOMAIN>
   <VM_PUBLIC_IP> <OUTLINE_DOMAIN>
   ```

   **B. Temporary Self-Signed Certificate**
   Set `CADDY_TLS=tls internal` in `.env`, then run
   `docker compose restart caddy`. This allows Caddy to issue self-signed
   certificates before DNS is available.

   **C. Test Connection**
   1. Restart Caddy: `docker compose restart caddy`
   2. Open `https://<CODIMD_DOMAIN>`, `https://<N8N_DOMAIN>`, and
      `https://<OUTLINE_DOMAIN>` in your browser.
   3. Your browser will warn about an insecure connection (due to self-signed cert). Click "Advanced" and "Proceed".
   4. Verify CodiMD, n8n, and Outline functionality.

   **D. Prepare for Production**
   Once everything works:
   1. Remove the hosts file entries.
   2. Point your DNS to the VM IP at your DNS provider.
   3. Clear `CADDY_TLS` in `.env`.
   4. Run `docker compose restart caddy` to let Caddy obtain official
      Let's Encrypt certificates.

8. **Final Verification**:

   - Check logs: `docker compose logs -f`
   - Access `https://<CODIMD_DOMAIN>`
   - Access `https://<N8N_DOMAIN>`
   - Access `https://<OUTLINE_DOMAIN>`

## Open WebUI Deployment (Cloudflare Tunnel + Microsoft Entra ID)

All commands in this section run from `src/`.

### Capacity gate before enabling

Check actual headroom before you enable Open WebUI:

```bash
cd src
free -h
df -h
docker stats --no-stream
```

`OPENWEBUI_MEM_LIMIT` defaults to `1024m` in `src/.env.example`, and Compose applies `mem_limit: ${OPENWEBUI_MEM_LIMIT:-1024m}`. Treat that as a **safety limit**, not proof that the VM has enough spare RAM. Do **not** reduce the existing service limits to squeeze Open WebUI onto the host. If the VM cannot preserve operating-system headroom plus the current workloads, stop here and resize or discuss the deployment instead of forcing it.

### Azure Storage provisioning (Azure PowerShell)

Use a dedicated storage account for Open WebUI uploads. The account key is a secret; never print it into transcripts unnecessarily and never commit it to Git.

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

# Paste the values privately into src/.env, then clear the key from the shell.
# OPENWEBUI_AZURE_STORAGE_ENDPOINT=$StorageEndpoint
# OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME=$ContainerName
# OPENWEBUI_AZURE_STORAGE_KEY=$StorageKey
Remove-Variable StorageKey
```

Use an approved subscription or resource group only; do **not** aim this at any temporary lab subscription. `OPENWEBUI_AZURE_STORAGE_ENDPOINT` must stay in the Azure Blob endpoint form `https://<storage-account>.blob.core.windows.net`, `OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME` must be `openwebui`, and `OPENWEBUI_AZURE_STORAGE_KEY` must be handled as a secret in `.env` or an approved secret manager.

### Dedicated Entra app registration

Use a **dedicated** app registration for Open WebUI; do not reuse the shared CodiMD/Outline registration.

1. In the [Microsoft Entra admin center](https://entra.microsoft.com), go to **Entra ID** → **App registrations** → **New registration**.
2. Set a dedicated display name such as `Open WebUI - Production`.
3. Under **Supported account types**, choose **Single tenant only - <your tenant>**.
4. Add a **Web** redirect URI of `https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`.
5. Register the app, then record:
   - **Application (client) ID** → `OPENWEBUI_MICROSOFT_CLIENT_ID`
   - **Directory (tenant) ID** → `OPENWEBUI_MICROSOFT_CLIENT_TENANT_ID`
6. Go to **Certificates & secrets** → **New client secret**, copy the **Value** immediately, and store it only in `OPENWEBUI_MICROSOFT_CLIENT_SECRET` inside `src/.env` or an approved secret manager. You will not be able to read that secret value again later.
7. Confirm **Authentication** still shows the exact redirect URI `https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`.
8. Verify the tenant has the matching enterprise application (service principal). If your tenant does not create it automatically, create it once with verified Az PowerShell:

   ```powershell
   New-AzADServicePrincipal -ApplicationId '<OPENWEBUI_MICROSOFT_CLIENT_ID>'
   ```

For basic OpenID `openid profile email` sign-in, you do **not** need Microsoft Graph **application** permissions. Do not grant broad directory permissions just to make basic sign-in work.

### Microsoft Foundry

Open WebUI is configured against OpenAI-compatible v1 endpoints. The accepted base URL formats are:

- `https://<resource>.openai.azure.com/openai/v1`
- `https://<resource>.services.ai.azure.com/openai/v1`

Do **not** add `/models` to either `.env` base URL. The base URL stops at `/openai/v1`; one-off test requests may append a request path such as `/models`, but the environment variable itself must not.

Map your chat and embedding deployments to the exact Task 1 variables:

- `OPENWEBUI_FOUNDRY_BASE_URL` → v1 base URL for the chat model endpoint
- `OPENWEBUI_FOUNDRY_API_KEY` → API key for that endpoint
- `OPENWEBUI_FOUNDRY_CHAT_MODEL` → the deployed chat model name
- `OPENWEBUI_RAG_OPENAI_BASE_URL` → v1 base URL for embeddings
- `OPENWEBUI_RAG_OPENAI_API_KEY` → API key for embeddings
- `OPENWEBUI_RAG_EMBEDDING_MODEL` → the deployed embedding model name

If one Foundry resource and key serve both chat and embeddings, duplicate the values intentionally in both variable groups so the Compose file stays explicit.

This is a secret-safe validation template you can run manually without pasting the key into shell history:

```bash
read -rsp "Foundry API key: " FOUNDRY_KEY && echo
BASE_URL="https://<resource>.services.ai.azure.com/openai/v1"
curl -fsS "${BASE_URL}/models" \
  -H "api-key: ${FOUNDRY_KEY}" \
  | python -m json.tool | sed -n '1,40p'
unset FOUNDRY_KEY BASE_URL
```

That example is only a template; it does **not** imply this repository has tested your live endpoint.

### Cloudflare Tunnel and Access

Create a **remotely managed** tunnel in the Cloudflare Zero Trust dashboard.

1. Create the tunnel in Zero Trust.
2. Add a public hostname for `<OPENWEBUI_DOMAIN>` (for example, `openwebui.example.com`), then set the service target separately to `http://open-webui:8080` in the dashboard. If the UI asks for a protocol, choose `HTTP` there rather than typing `https://` into the hostname field.
3. Copy the tunnel token once into `CLOUDFLARED_TUNNEL_TOKEN` in `src/.env`. The token is secret.
4. Keep DNS as the tunnel-managed **CNAME**. Do **not** create an `A` record from the hostname to the VM public IP.
5. Create a **self-hosted** Cloudflare Access application for the same hostname and add an **Allow** policy for the intended Entra users or groups.

Tunnel traffic is outbound-only from the VM. Neither `open-webui` nor `cloudflared` publishes a host port, which prevents direct-origin bypass for this hostname and does not interfere with the existing Caddy-published sites. This hostname currently depends on a single tunnel connector; `restart: always` helps recover the `cloudflared` process, and `docker compose logs cloudflared` is the first place to check if the route disappears.

Authoritative references:

- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>

### First boot and verification

Create the Open WebUI data directory on the Azure data disk before the first start:

```bash
sudo install -d -m 0750 /mnt/data/open-webui/data
```

Open WebUI image `ghcr.io/open-webui/open-webui:v0.11.3` runs as UID/GID `0` by default, so no service-specific `chown` is required here. The directory still should not be world-writable.

Then prepare the first boot:

1. From `src/`, copy `.env.example` to `.env` if you have not already done so.
2. Fill every Open WebUI and Cloudflare placeholder before starting:
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
3. Leave `ENABLE_PERSISTENT_CONFIG=false` in place. In this mode, environment variables remain authoritative; Admin UI configuration edits may appear editable but do not persist across restart.
4. Leave `OPENWEBUI_ENABLE_OAUTH_SIGNUP=true` for the first authorized OAuth user bootstrap. After the intended account exists, set it to `false` and recreate **only** Open WebUI:

   ```bash
   cd src
   docker compose up -d --no-deps open-webui
   ```

   Do **not** restart or recreate Caddy for this step.
5. Start only the new services:

   ```bash
   cd src
   docker compose up -d open-webui cloudflared
   ```

Suggested verification sequence:

```bash
cd src
docker compose ps open-webui cloudflared
docker compose logs --tail=100 open-webui cloudflared
docker compose exec open-webui curl -fsS http://127.0.0.1:8080/health
```

Then manually verify:

- authorized Cloudflare Access users can reach `https://<OPENWEBUI_DOMAIN>`
- unauthorized users are blocked by Access
- existing `https://<CODIMD_DOMAIN>`, `https://<N8N_DOMAIN>`, and `https://<OUTLINE_DOMAIN>` still behave as before
- RustDesk logs and connectivity remain healthy
- chat requests succeed against the configured Foundry model
- file upload succeeds
- a later file re-read / RAG lookup succeeds against the embedding model
- the expected Blob objects appear in the `openwebui` container
- recreating `open-webui` preserves chats, accounts, and configuration stored in `${DATA_ROOT}/open-webui/data`

Azure Blob is **not** the whole storage story here. In Open WebUI v0.11.3, the Azure storage provider writes each upload to `/app/backend/data/uploads` first and then uploads it to Blob storage. The local copy is not removed after a successful upload, so `${DATA_ROOT}` still needs capacity for local Open WebUI growth.

## RustDesk Configuration

After the first startup, RustDesk generates a key pair for encrypted connections.

1. **Retrieve the public key**:
   ```bash
   cat /mnt/data/rustdesk/data/id_ed25519.pub
   ```
2. **Configure RustDesk clients**:
   - Open RustDesk client → Settings → Network → ID/Relay Server
   - **ID Server**: `<VM_PUBLIC_IP>`
   - **Relay Server**: `<VM_PUBLIC_IP>`
   - **Key**: paste the public key from step 1
3. **Verify connectivity**:
   ```bash
   # Check containers are running
   docker compose ps rustdesk-hbbs rustdesk-hbbr

   # Check logs
   docker compose logs rustdesk-hbbs rustdesk-hbbr

   # Test port from external machine
   nc -zv <VM_PUBLIC_IP> 21116
   ```

> **Note**: `ENCRYPTED_ONLY=1` is set by default, which forces all clients to use the public key. This prevents unauthorized connections.

## Database Migration

If you are migrating data from old VMs, follow the steps below.

### 1. Backup Old Databases

**On Old CodiMD VM:**
```bash
# Backup CodiMD DB
docker exec -t codimd_database_1 pg_dump -U codimd codimd > codimd_backup.sql
```

**On Old n8n VM:**
```bash
# Find your postgres container name (e.g., src_postgres_1)
docker ps

# Backup n8n DB (replace CONTAINER_NAME)
docker exec -t CONTAINER_NAME pg_dump -U n8n n8n > n8n_backup.sql
```

### 2. Verify Backups Without Overwriting Live Databases

**On New VM (after starting services):**
```bash
# Create new, separate databases. Never drop or overwrite the live databases.
docker exec src-codimd-db-1 createdb -U codimd codimd_restore_check
docker exec src-n8n-db-1 createdb -U n8n n8n_restore_check

# Restore into the new databases only.
cat codimd_backup.sql | docker exec -i src-codimd-db-1 psql -U codimd -d codimd_restore_check
cat n8n_backup.sql | docker exec -i src-n8n-db-1 psql -U n8n -d n8n_restore_check

# Compare record counts with the live databases. Keep the verification
# databases until you have explicitly approved their removal.
```

## Cost Estimation 💰

This repository does **not** assert a current live VM SKU or monthly price. Confirm the actual VM size, disks, and subscription pricing before you resize for Open WebUI.

Open WebUI mainly adds four cost vectors:

- more VM memory and data-disk consumption on the existing host
- Azure Blob capacity and transactions for uploads
- Microsoft Foundry model usage for chat and embeddings
- Cloudflare Zero Trust / Access features if your usage exceeds the Free tier

Azure Container Apps was not chosen for this repository because Open WebUI still depends on a reliable local filesystem for SQLite and local upload/cache data, while the existing VM usually has near-zero incremental infrastructure cost if it already exists. ACA can still be the better fit in some environments, but once you add durable storage and a database, it usually introduces more moving parts and may cost more than keeping this workload on the current VM.

_Cheaper than your coffee addiction, if you already have the headroom. ☕_

## Maintenance

### Updates

Image versions are pinned in `src/docker-compose.yml`. `docker compose pull` by itself can refresh the currently configured tags, but it does **not** move a pinned service to a newer tag.

For an Open WebUI or cloudflared upgrade:

1. Read the upstream release notes first.
2. Create the pre-upgrade backups from the **Backups** section below.
3. Edit the exact image tag in `src/docker-compose.yml`.
4. Validate the Compose file:

   ```bash
   cd src
   docker compose config --quiet
   ```

5. Pull only the changed service image:

   ```bash
   cd src
   docker compose pull open-webui
   ```

6. Recreate only that service:

   ```bash
   cd src
   docker compose up -d --no-deps open-webui
   ```

7. Inspect health and logs:

   ```bash
   cd src
   docker compose ps open-webui
   docker compose logs --tail=100 open-webui
   ```

Schema migrations can make a blind image rollback unsafe. If an upgrade fails after a schema change, restore from the verified pre-upgrade backup instead of assuming the previous image tag can read the new data safely.

### Monitoring

1. Check container status:
```bash
docker compose ps
```

2. View logs:
```bash
docker compose logs -f
```

3. Monitor system resources:
```bash
htop
```

### Backups

Back up all three PostgreSQL databases, Outline's local attachments, and Open WebUI's local data. These commands create timestamped files and do not overwrite prior backups.

```bash
# Run from the Compose project directory so docker compose can find docker-compose.yml.
cd /path/to/CommonVM/src
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "/mnt/data/backup/${STAMP}"

docker exec src-codimd-db-1 pg_dump -U codimd -d codimd -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/codimd.dump"
docker exec src-n8n-db-1 pg_dump -U n8n -d n8n -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/n8n.dump"
docker exec src-outline-db-1 pg_dump -U outline -d outline -Fc --no-owner --no-privileges \
  > "/mnt/data/backup/${STAMP}/outline.dump"

# Some private attachments are mode 0600 and owned by Outline's UID 1001.
sudo tar czf "/mnt/data/backup/${STAMP}/outline-data.tar.gz" \
  -C /mnt/data/outline data
sudo chown "$(id -u):$(id -g)" "/mnt/data/backup/${STAMP}/outline-data.tar.gz"

# Open WebUI uses SQLite under /mnt/data/open-webui/data. Stop only this
# service before copying it, then bring it back immediately.
docker compose stop open-webui
sudo tar czf "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz" \
  -C /mnt/data/open-webui data
docker compose up -d open-webui
sudo chown "$(id -u):$(id -g)" "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz"

# Non-destructive backup validation
cat "/mnt/data/backup/${STAMP}/outline.dump" \
  | docker exec -i src-outline-db-1 pg_restore --list > /dev/null
tar tzf "/mnt/data/backup/${STAMP}/outline-data.tar.gz" > /dev/null
tar tzf "/mnt/data/backup/${STAMP}/open-webui-data.tar.gz" > /dev/null
```

Azure Blob contents do **not** replace the SQLite/data backup. Chats, accounts, configuration, and other local Open WebUI state still live under `${DATA_ROOT}/open-webui/data`, and that backup remains required.

To verify an Open WebUI restore non-destructively, extract into a **new** directory and inspect the SQLite database there. Never overwrite the live directory for a restore check, and do not delete the verification directory unless you explicitly approve that cleanup.

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

Back up secrets separately in an approved secret manager: `OPENWEBUI_SECRET_KEY`, `OPENWEBUI_MICROSOFT_CLIENT_SECRET`, `OPENWEBUI_FOUNDRY_API_KEY`, `OPENWEBUI_RAG_OPENAI_API_KEY`, and `CLOUDFLARED_TUNNEL_TOKEN` must **not** be stored inside the tar files or in Git.

## Security Considerations 🔒

1. **Firewall Rules**:
   - Azure NSG allows ports 80/443 (HTTP/HTTPS) and 21114-21119 TCP + 21116 UDP (RustDesk)
   - No extra inbound NSG port is required for Open WebUI because `cloudflared` makes outbound-only tunnel connections
   - Consider disabling SSH port 22 after initial setup (use Azure Bastion instead)

2. **SSH Access**:
   - Use SSH key-based authentication only
   - Password authentication should be disabled

3. **Application Security**:
   - HTTPS is enforced for CodiMD, n8n, and Outline via Caddy
   - Open WebUI is intended to sit behind Cloudflare Access on its dedicated hostname
   - CodiMD uses Microsoft Entra ID (OAuth2) for authentication
   - Outline uses the **same** Entra app registration via generic OIDC
   - Open WebUI should use its **own** dedicated Entra app registration
   - n8n supports built-in authentication and 2FA

4. **Why NSG allowlisting cannot protect one site at a time**:
   - CodiMD, n8n, and Outline all share the same inbound port `443` behind Caddy
   - Open WebUI is published through Cloudflare's edge, whose source addresses are shared infrastructure rather than a per-site allowlist you can model at the Azure NSG layer
   - Because of those two facts, NSG rules can allow or deny transport, but they cannot meaningfully express "allow only this one hostname" for the HTTPS sites

5. **Shared Entra app registration for CodiMD and Outline** ⚠️:

   CodiMD and Outline intentionally share one app registration, so:

   - They also share one client secret. **Rotating it breaks both services**;
     update `CODIMD_OAUTH2_CLIENT_SECRET` and `OUTLINE_OIDC_CLIENT_SECRET`
     together.
   - The app must carry both redirect URIs:
     `https://<CODIMD_DOMAIN>/auth/oauth2/callback` and
     `https://<OUTLINE_DOMAIN>/auth/oidc.callback`
   - **Do not delete the app registration when retiring CodiMD** — Outline
     still authenticates through it.

   Outline is configured with the generic OIDC plugin rather than its Azure
   plugin on purpose: the Azure plugin calls Microsoft Graph
   `/v1.0/organization` and fails hard without `Organization.Read.All`, which
   normally requires admin consent. OIDC only needs `openid profile email`.

## Troubleshooting

### Cannot connect to services
- Check VM status in Azure portal
- Verify DNS settings point to the VM IP for Caddy-routed sites
- Check containers: `docker compose ps`
- Review logs: `docker compose logs -f`

### Cloudflare Tunnel / Open WebUI route issues
- Check `docker compose logs cloudflared`
- Verify the public hostname is routed to `http://open-webui:8080`
- Verify DNS is the tunnel-managed CNAME, not an `A` record to the VM public IP
- Confirm `open-webui` and `cloudflared` do not publish host ports

### Microsoft OAuth redirect mismatch
- Verify `OPENWEBUI_DOMAIN` matches the public hostname exactly
- Verify the Entra app redirect URI is exactly `https://<OPENWEBUI_DOMAIN>/oauth/microsoft/callback`
- Confirm the `.env` values map correctly:
  - `OPENWEBUI_MICROSOFT_CLIENT_ID`
  - `OPENWEBUI_MICROSOFT_CLIENT_SECRET`
  - `OPENWEBUI_MICROSOFT_CLIENT_TENANT_ID`
- Confirm the app is single-tenant and the matching service principal exists

### Foundry URL or model configuration issues
- `OPENWEBUI_FOUNDRY_BASE_URL` and `OPENWEBUI_RAG_OPENAI_BASE_URL` must end at `/openai/v1`
- Do **not** put `/models` into either environment variable
- Verify `OPENWEBUI_FOUNDRY_CHAT_MODEL` is the deployed chat model name
- Verify `OPENWEBUI_RAG_EMBEDDING_MODEL` is the deployed embedding model name

### Azure Blob 403 or upload failures
- Verify `OPENWEBUI_AZURE_STORAGE_ENDPOINT` is in the form `https://<storage-account>.blob.core.windows.net`
- Verify `OPENWEBUI_AZURE_STORAGE_CONTAINER_NAME=openwebui`
- Verify the container exists and remains private (`-Permission Off`)
- If the account key was rotated, update `OPENWEBUI_AZURE_STORAGE_KEY` in `.env` and recreate only `open-webui`

### Local disk growth
- Open WebUI still writes local files under `${DATA_ROOT}/open-webui/data`
- Uploads are written locally first, then copied to Azure Blob
- Inspect growth before the disk fills:
  ```bash
  du -sh /mnt/data/open-webui/data/*
  ```

### Memory pressure or OOM
- `OPENWEBUI_MEM_LIMIT=1024m` is a guardrail, not a sizing guarantee
- Check `free -h` and `docker stats --no-stream`
- Review `docker compose logs open-webui` for restart loops or OOM symptoms
- If the host cannot preserve system headroom, resize the VM instead of reducing existing service limits

### Database connection issues
- Check PostgreSQL logs: `docker compose logs codimd-db` or `docker compose logs n8n-db`
- Verify environment variables in `.env`
- Ensure database containers are running

### SSL/HTTPS issues
- Check Caddy logs: `docker compose logs caddy`
- Verify domain points to correct IP
- Ensure ports 80 and 443 are open in Azure NSG
- For local testing, set `CADDY_TLS=tls internal` in `.env`, then restart Caddy

### RustDesk connection issues
- Verify NSG rules include TCP 21114-21119 and UDP 21116
- Check containers: `docker compose logs rustdesk-hbbs rustdesk-hbbr`
- Ensure `network_mode: "host"` is set (ports must not conflict with other host services)
- Verify the client has the correct public key: `cat /mnt/data/rustdesk/data/id_ed25519.pub`
- If key is missing, restart the hbbs container: `docker compose restart rustdesk-hbbs`

### n8n 2FA/Login issues
If you migrated from an old n8n instance and cannot login with 2FA:
1. Retrieve the old encryption key from the previous instance:
   ```bash
   docker exec -t <old_container> cat /home/node/.n8n/config
   ```
2. Add it to `.env`:
   ```bash
   N8N_ENCRYPTION_KEY=your_old_key
   ```
3. Delete the auto-generated config and restart:
   ```bash
   docker compose stop n8n
   sudo rm /mnt/data/n8n/data/config
   docker compose up -d
   ```

## Support

For issues:
1. Check [n8n documentation](https://docs.n8n.io/)
2. Check [CodiMD documentation](https://hackmd.io/c/codimd-documentation)
3. Check [Outline documentation](https://docs.getoutline.com/)
4. Check [Open WebUI documentation](https://docs.openwebui.com/)
5. Check [RustDesk documentation](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/)
6. Open an issue in the original repositories:
   - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter)
   - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc)
   - [Open WebUI](https://github.com/open-webui/open-webui)
7. Visit [n8n community forums](https://community.n8n.io/)

## License

This deployment template is MIT licensed. n8n, CodiMD, Open WebUI, and RustDesk are licensed under their own respective terms.

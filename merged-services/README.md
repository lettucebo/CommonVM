# Merged CodiMD & n8n Services

This setup combines CodiMD and n8n onto a single VM using Docker Compose and Caddy as a reverse proxy.

## Prerequisites

- Azure VM (Ubuntu recommended)
- Docker and Docker Compose installed
- Public IP address
- DNS records pointing to the VM IP:
  - `doc.yu.money`
  - `n8n.yu.money`
- Ports 80 and 443 open in Azure Network Security Group (NSG)

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
2. **Copy Files**: Transfer this directory (`merged-services`) to your VM.
3. **Configure Environment**: 
   - Check `.env` and ensure all secrets are correct.
   - **Important**: Update `DATA_ROOT` in `.env` to point to your mounted disk path (default: `/mnt/data`).
4. **Start Services**:
   ```bash
   docker compose up -d
   ```
4. **Verify**:
   - Check logs: `docker compose logs -f`
   - Access `https://doc.yu.money`
   - Access `https://n8n.yu.money`

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

### 2. Restore to New VM

**On New VM (after starting services):**
```bash
# Stop app containers
docker compose stop codimd n8n

# Restore CodiMD
cat codimd_backup.sql | docker exec -i merged-services-codimd-db-1 psql -U codimd -d codimd

# Restore n8n
cat n8n_backup.sql | docker exec -i merged-services-n8n-db-1 psql -U n8n -d n8n

# Restart services
docker compose start codimd n8n
```

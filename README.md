# Common Services

This setup combines CodiMD and n8n onto a single VM using Docker Compose and Caddy as a reverse proxy.

> **Note**: This project merges two separate Docker deployments:
> - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter) - n8n workflow automation
> - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc) - Collaborative markdown editor

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
4. **Fix Folder Permissions**:
   Since container user IDs (UID) may differ from the host, run the following commands to fix folder permissions and avoid `Permission denied` errors:

   ```bash
   # Fix n8n folder permissions (UID 1000)
   sudo chown -R 1000:1000 /mnt/data/n8n

   # Fix CodiMD folder permissions (UID 1500)
   sudo chown -R 1500:1500 /mnt/data/codimd
   ```
5. **Start Services**:
   ```bash
   docker compose up -d
   ```
6. **Verification (Before DNS Switch)**:
   If you haven't pointed DNS to this VM yet, follow these steps for local verification:

   **A. Modify Local Hosts File**
   On your computer (not the Azure VM), modify the hosts file to point domains to the VM's public IP:
   - **Windows**: `C:\Windows\System32\drivers\etc\hosts` (requires administrator privileges)
   - **Mac/Linux**: `/etc/hosts` (requires sudo)

   Add the following:
   ```text
   <VM_PUBLIC_IP> doc.yu.money
   <VM_PUBLIC_IP> n8n.yu.money
   ```

   **B. Temporary Self-Signed Certificate (Already Configured)**
   I've temporarily added `tls internal` to the `Caddyfile`. This allows Caddy to issue self-signed certificates for HTTPS without DNS.
   
   **C. Test Connection**
   1. Restart Docker services: `docker compose restart`
   2. Open `https://doc.yu.money` and `https://n8n.yu.money` in your browser.
   3. Your browser will warn about an insecure connection (due to self-signed cert). Click "Advanced" and "Proceed".
   4. Verify CodiMD and n8n functionality (login, create notes, create workflows).

   **D. Prepare for Production**
   Once everything works:
   1. Remove the hosts file entries.
   2. Point your DNS to the VM IP at your DNS provider.
   3. Edit `src/Caddyfile` and remove the two `tls internal` lines.
   4. Run `docker compose restart` to let Caddy obtain official Let's Encrypt certificates.

7. **Final Verification**:

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

## Cost Estimation 💰

Monthly cost breakdown (Azure B1ms VM):
- VM (B1ms): ~$13.14
- Storage (OS Disk 32GB): ~$2.40
- **Total: ~$15.54/month**

_Cheaper than your coffee addiction! ☕_

## Maintenance

### Updates

Update services to latest versions:
```bash
docker compose pull
docker compose up -d
```

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

Automated backups can be configured using cron:
```bash
# Add to crontab for daily backups at midnight
(crontab -l 2>/dev/null; echo "0 0 * * * /path/to/backup.sh") | crontab -
```

## Security Considerations 🔒

1. **Firewall Rules**:
   - Azure NSG allows only ports 80 (HTTP) and 443 (HTTPS)
   - Consider disabling SSH port 22 after initial setup (use Azure Bastion instead)

2. **SSH Access**:
   - Use SSH key-based authentication only
   - Password authentication should be disabled

3. **Application Security**:
   - HTTPS enforced via Caddy
   - Regular security updates recommended
   - CodiMD uses Microsoft Entra ID (OAuth2) for authentication
   - n8n supports built-in authentication and 2FA

## Troubleshooting

### Cannot connect to services
- Check VM status in Azure portal
- Verify DNS settings point to VM IP
- Check containers: `docker compose ps`
- Review logs: `docker compose logs -f`

### Database connection issues
- Check PostgreSQL logs: `docker compose logs codimd-db` or `docker compose logs n8n-db`
- Verify environment variables in `.env`
- Ensure database containers are running

### SSL/HTTPS issues
- Check Caddy logs: `docker compose logs caddy`
- Verify domain points to correct IP
- Ensure ports 80 and 443 are open in Azure NSG
- For local testing, use `tls internal` in Caddyfile (already configured)

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
3. Open an issue in the original repositories:
   - [n8n-azure-vm-starter](https://github.com/lettucebo/n8n-azure-vm-starter)
   - [CodiMD-Doc](https://github.com/lettucebo/CodiMD-Doc)
4. Visit [n8n community forums](https://community.n8n.io/)

## License

This deployment template is MIT licensed. n8n and CodiMD are licensed under their own respective terms.


# 🚀 n8n on Azure: Because Workflows Shouldn't Be a Pain in the Cloud

Deploy n8n like a boss on Azure! This repo helps you set up n8n faster than you can say "automation" (okay, maybe not that fast, but pretty close).

## What's in the Box? 🎁
- 🐳 Docker-powered goodness
- 🔒 Auto-HTTPS (because security is cool)
- 💾 PostgreSQL that actually remembers stuff
- 🤖 n8n ready to automate your life
- 🔧 Scripts that do the heavy lifting

## Why This? 🤔
Because manually setting up n8n on Azure is about as fun as debugging production at 3 AM. This template does all the boring stuff for you, so you can focus on building awesome workflows instead.

## Cost? 💰
About $15/month - cheaper than your coffee addiction! ☕

_Perfect for: People who love automation but hate complicated setups. Not perfect for: People who enjoy spending weekends configuring servers (you know who you are)._

Ready to make your life easier? Check out the docs below! 👇

# n8n Azure VM Deployment

This repository contains templates and scripts to deploy n8n workflow automation platform on Azure Virtual Machine. This deployment uses Docker and Docker Compose for running n8n and PostgreSQL, with Caddy as a reverse proxy for automatic HTTPS.

## Overview

The deployment consists of:
- Azure B1ms VM (1 vCPU, 2GB RAM)
- Ubuntu 22.04 LTS
- Docker & Docker Compose
- n8n Community Edition
- PostgreSQL database
- Caddy web server (for HTTPS)
- Automatic backups
- Basic monitoring

## Prerequisites

1. Azure CLI installed
```bash
curl -sL https://aka.ms/InstallAzureCLI | bash
```

2. Azure subscription
```bash
az login
```

3. A domain name pointed to Azure VM's IP (will be obtained during deployment)

## Repository Structure

```
.
├── n8n-vm-template.json    # Azure ARM template for VM
├── deploy.sh               # Deployment script
├── setup.sh               # VM setup script
├── docker-compose.yml     # Docker composition for n8n
├── backup.sh             # Backup script
└── README.md             # This file
```

## Deployment Steps

### 1. Clone the Repository

```bash
git clone https://github.com/jawand/n8n-azure-vm-starter
cd n8n-azure-vm-starter
```

### 2. Configure Deployment

Edit `deploy.sh` and set your preferred values:
```bash
RESOURCE_GROUP="n8n-rg"
LOCATION="eastus"
VM_NAME="n8n-vm"
ADMIN_USERNAME="n8nadmin"
```

### 3. Deploy the VM

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
- Create a resource group
- Generate SSH keys if needed
- Deploy the VM using ARM template
- Output connection information
- The VM public IP is Dynamic, so you need to use Azure DNS record to point to your domain.

### 4. Configure DNS

Point your domain to the VM's DNS Name (shown in deployment output). We cannot use IP address because it is dynamic and will change when the VM is restarted. Additionally, we are using Caddy as a reverse proxy to automatically handle HTTPS. 

Make sure to create `CNAME` record for `n8n.example.com` to point to the VM's DNS Name (found in deployment output) on your Domain Registrar.

We need the DNS configured before we setup n8n server because Caddy will use the DNS to get the SSL certificate from Let's Encrypt and if its not ready then SSL will not generate & will throw an error, because Caddy will not be able to get the SSL certificate since it will not find the DNS record. I will recommend to wait for 10-15 minutes after you have pointed your subdomain to Azure VM DNS Name, before we setup n8n server.

### 5. Setup n8n

1. SSH into the VM:
```bash
ssh -i ~/.ssh/id_rsa_n8n n8nadmin@<VM_IP>
```

2. Open new Terminal and Copy setup files:
```bash
# From your local machine
scp -i ~/.ssh/id_rsa_n8n setup.sh docker-compose.yml backup.sh n8nadmin@<VM_IP>:~/
```
- It will copy all the files to the VM.

3. Run setup:
```bash
chmod +x setup.sh
./setup.sh
```

It will ask for domain name, Please provide your domain name. I prefer to use subdomain like `n8n.yourdomain.com`.

### 7. Navigate to n8n folder and start containers
```bash
cd n8n
docker-compose up -d
```
- we are using volume to persist n8n data to make sure data is not lost when containers are restarted.

### 8. Access n8n

Once deployment is complete, you can access n8n at:
```
https://n8n.your-domain.com
```

Set your own credentials at the first login.

## Configuration Files

### docker-compose.yml
Contains service definitions for:
- n8n
- PostgreSQL

Key configurations:
```yaml
services:
  n8n:
    image: docker.io/n8nio/n8n:latest
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${N8N_HOST}
      - WEBHOOK_URL=https://${N8N_HOST}
      - NODE_ENV=production
      - N8N_PROTOCOL=https
      - N8N_SSL_CERT=/etc/caddy/certificates/${N8N_HOST}.crt
      - N8N_PORT=5678
      - GENERIC_TIMEZONE=UTC
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      - postgres

  postgres:
    image: postgres:14-alpine
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

### Backup Configuration

The `backup.sh` script performs:
- PostgreSQL database dumps
- n8n data volume backup
- Optional upload to Azure Storage

To enable automatic backups:
```bash
(crontab -l 2>/dev/null; echo "0 0 * * * /home/n8nadmin/backup.sh") | crontab -
```

## Maintenance

### Updates

Update n8n and PostgreSQL:
```bash
docker-compose pull
docker-compose up -d
```

### Monitoring

1. Check container status:
```bash
docker-compose ps
```

2. View logs:
```bash
docker-compose logs -f
```

3. Monitor system resources:
```bash
htop
```

### Backups

Manual backup:
```bash
./backup.sh
```

## Security Considerations

1. Firewall rules are configured to allow only:
   - SSH (22) Please make sure to disable SSH port 22 in Azure portal.
   - HTTPS (443)

2. SSH access:
   - SSH Key-based authentication only and is stored at `~/.ssh/id_rsa_n8n` on your local machine.
   - Password authentication disabled

3. n8n security:
   - HTTPS enforced
   - Regular security updates

## Troubleshooting

1. Cannot connect to n8n:
   - Check VM status in Azure portal
   - Verify domain DNS settings
   - Check docker containers: `docker-compose ps`

2. Database connection issues:
   - Check PostgreSQL logs: `docker-compose logs postgres`
   - Verify environment variables in docker-compose.yml

3. SSL/HTTPS issues:
   - Check Caddy logs: `sudo journalctl -u caddy`
   - Verify domain points to correct IP

## Cost Estimation

Monthly cost breakdown:
- VM (B1ms): ~$13.14
- Storage (OS Disk): ~$2.40
- Total: ~$15.54/month

## Support

For issues:
1. Check the [n8n documentation](https://docs.n8n.io/)
2. Open an issue in this repository
3. Check [n8n community forums](https://community.n8n.io/)

## License

This deployment template is MIT licensed. n8n is licensed under its own terms.

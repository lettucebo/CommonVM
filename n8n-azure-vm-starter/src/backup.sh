#!/bin/bash

# Backup PostgreSQL
docker exec n8n-postgres-1 pg_dump -U n8n n8n > backup_$(date +%Y%m%d).sql

# Backup n8n data
tar -czf n8n_data_$(date +%Y%m%d).tar.gz /var/lib/docker/volumes/n8n_n8n_data

# Upload to Azure Storage (if needed)
az storage blob upload \
  --account-name yourstorageaccount \
  --container-name backups \
  --name backup_$(date +%Y%m%d).sql \
  --file backup_$(date +%Y%m%d).sql 
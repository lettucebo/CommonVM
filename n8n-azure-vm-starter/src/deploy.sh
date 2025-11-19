#!/bin/bash

# Variables
RESOURCE_GROUP="n8n"
LOCATION="eastasia"
VM_NAME="n8n-vm"
read -p "Enter admin username: " ADMIN_USERNAME
DNS_PREFIX="n8n-$(date +%s | cut -c6-10)"
read -s -p "Enter admin password: " PASSWORD
echo

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy the VM
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file n8n-vm-template.json \
  --parameters \
    vmName=$VM_NAME \
    adminUsername=$ADMIN_USERNAME \
    adminPasswordOrKey=$PASSWORD \
    dnsLabelPrefix=$DNS_PREFIX

# Get the VM's public IP
VM_IP=$(az vm show -d -g $RESOURCE_GROUP -n $VM_NAME --query publicIps -o tsv)

# Output connection information
echo "VM deployed successfully!"
echo "SSH connection: ssh -i ~/.ssh/id_rsa_n8n $ADMIN_USERNAME@$VM_IP"
echo "DNS name: $DNS_PREFIX.$LOCATION.cloudapp.azure.com" 
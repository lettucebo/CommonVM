#!/bin/bash

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker and Docker Compose
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add current user to docker group to avoid permission issues
sudo usermod -aG docker $USER
# Notify about group changes
echo "Added user to docker group. You may need to log out and back in for this to take effect."

sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install Caddy for HTTPS
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy

# Prompt for domain name
read -p "Enter your domain name: " domain_name

# Create Caddyfile with user's domain
cat << EOF | sudo tee /etc/caddy/Caddyfile
${domain_name} {
    # Add debug logging
    log {
        output stderr
        format console
        level DEBUG
    }
    
    # Add security headers
    header {
        # Enable HSTS
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        # Disable FLoC tracking
        Permissions-Policy "interest-cohort=()"
        # XSS protection
        X-XSS-Protection "1; mode=block"
        # Prevent clickjacking
        X-Frame-Options "SAMEORIGIN"
        # Disable MIME type sniffing
        X-Content-Type-Options "nosniff"
    }

    reverse_proxy localhost:5678 {
        # Add WebSocket support
        header_up X-Forwarded-Proto "https"
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
}
EOF

# Restart Caddy and check its status
sudo systemctl restart caddy
sudo systemctl status caddy

# Create n8n directory and set environment variables
mkdir -p n8n && mv docker-compose.yml n8n && cd n8n

# Set N8N_HOST environment variable both in .env and current session
export N8N_HOST="${domain_name}"
echo "N8N_HOST=${domain_name}" > .env
echo "N8N_PROTOCOL=https" >> .env
echo "N8N_PORT=5678" >> .env

# Notify user to log out and back in
echo "Setup complete! Please log out and log back in for docker permissions to take effect."
echo "Then run 'docker-compose up -d' in the n8n directory to start the containers." 
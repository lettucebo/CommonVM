#!/bin/bash
# Deploy and configure RustDesk client (macOS) with self-hosted server settings.
#
# Usage:
#   chmod +x deploy-rustdesk-client.sh
#   ./deploy-rustdesk-client.sh -s <SERVER_IP> -k <KEY>
#
# Parameters:
#   -s  Server IP or domain of your RustDesk server (required)
#   -k  Public key from server id_ed25519.pub (required)
#   -r  Relay server address (defaults to Server IP)
#
# Examples:
#   ./deploy-rustdesk-client.sh -s "203.0.113.10" -k "ITsuw4tzu39v..."
#   ./deploy-rustdesk-client.sh -s "rustdesk.example.com" -k "abc123..." -r "relay.example.com"

set -e

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Parse arguments
SERVER_IP=""
KEY=""
RELAY_SERVER=""

usage() {
    echo "Usage: $0 -s <SERVER_IP> -k <KEY> [-r <RELAY_SERVER>]"
    echo ""
    echo "  -s  Server IP or domain of your RustDesk server (required)"
    echo "  -k  Public key from server id_ed25519.pub (required)"
    echo "  -r  Relay server address (defaults to Server IP)"
    exit 1
}

while getopts "s:k:r:h" opt; do
    case $opt in
        s) SERVER_IP="$OPTARG" ;;
        k) KEY="$OPTARG" ;;
        r) RELAY_SERVER="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$SERVER_IP" ] || [ -z "$KEY" ]; then
    echo -e "${RED}Error: -s (Server IP) and -k (Key) are required.${NC}"
    echo ""
    usage
fi

if [ -z "$RELAY_SERVER" ]; then
    RELAY_SERVER="$SERVER_IP"
fi

# 1. Check Homebrew
echo -e "${CYAN}[1/3] Checking Homebrew...${NC}"
if ! command -v brew &> /dev/null; then
    echo -e "${RED}Homebrew not found. Install it first: https://brew.sh${NC}"
    exit 1
fi
echo -e "${GREEN}      Homebrew found${NC}"

# 2. Install RustDesk
echo -e "${CYAN}[2/3] Installing RustDesk via Homebrew...${NC}"
if brew list --cask rustdesk &> /dev/null; then
    echo -e "${GREEN}      RustDesk already installed, upgrading...${NC}"
    brew upgrade --cask rustdesk 2>/dev/null || echo -e "${GREEN}      Already up to date${NC}"
else
    brew install --cask rustdesk
fi

if [ ! -d "/Applications/RustDesk.app" ]; then
    echo -e "${RED}Installation failed: /Applications/RustDesk.app not found${NC}"
    exit 1
fi
echo -e "${GREEN}      RustDesk installed${NC}"

# 3. Write config
echo -e "${CYAN}[3/3] Writing server configuration...${NC}"
echo -e "      ID Server:    $SERVER_IP"
echo -e "      Relay Server: $RELAY_SERVER"
echo -e "      Key:          ${KEY:0:8}..."

CONFIG_DIR="$HOME/Library/Preferences/RustDesk/config"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/RustDesk2.toml" << EOF
rendezvous_server = '${SERVER_IP}:21116'
nat_type = 1
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
custom-rendezvous-server = '${SERVER_IP}'
relay-server = '${RELAY_SERVER}'
key = '${KEY}'
EOF

echo -e "${GREEN}      Config written to: $CONFIG_DIR/RustDesk2.toml${NC}"

# Launch
echo ""
echo -e "${GREEN}RustDesk deployment complete!${NC}"
echo -e "${YELLOW}Run:    open /Applications/RustDesk.app${NC}"
echo -e "${YELLOW}Config: $CONFIG_DIR/RustDesk2.toml${NC}"
echo ""
echo -e "${YELLOW}NOTE: On first launch, macOS will ask for Accessibility permissions.${NC}"
echo -e "${YELLOW}      Go to System Settings > Privacy & Security > Accessibility${NC}"
echo -e "${YELLOW}      and enable RustDesk.${NC}"

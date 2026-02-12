#!/usr/bin/env bash
set -euo pipefail

# =========================
# PicoTun Installer v2.0
# =========================
REPO_DEFAULT="amir6dev/RsTunnel"
BINARY_DEFAULT="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/picotun.service"

# --- Colors ---
NC='\033[0m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PURPLE='\033[1;35m'

# --- Helpers ---
print_header() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${PURPLE}      🚀 PicoTun Tunnel Manager (Pro Edition)      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}➤ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

print_error() {
    echo -e "${RED}✖ $1${NC}"
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "Please run as root: sudo bash setup.sh"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

ensure_deps() {
    if ! command -v curl &> /dev/null; then
        print_step "Installing dependencies..."
        apt-get update -y -qq >/dev/null
        apt-get install -y curl tar >/dev/null
    fi
}

# --- Installation Logic ---

download_binary() {
    print_step "Checking for latest version..."
    local arch=$(detect_arch)
    local api="https://api.github.com/repos/${REPO_DEFAULT}/releases/latest"
    
    # Try to fetch latest url
    local url=$(curl -fsSL "$api" | grep -Eo 'https://[^"]+picotun_linux_'"$arch"'\.tar\.gz' | head -n 1)

    if [[ -z "$url" ]]; then
        echo -e "${YELLOW}⚠ Could not auto-detect latest release.${NC}"
        read -p "Enter manual download URL (or press Enter to retry): " manual_url
        if [[ -n "$manual_url" ]]; then
            url="$manual_url"
        else
            print_error "Failed to download. Check repo settings."
            exit 1
        fi
    fi

    local tmp="$(mktemp -d)"
    print_step "Downloading core..."
    curl -fL "$url" -o "$tmp/picotun.tar.gz"
    
    print_step "Installing..."
    tar -xzf "$tmp/picotun.tar.gz" -C "$tmp"
    
    # Find binary regardless of folder structure
    local bin_path=$(find "$tmp" -type f -name "picotun" | head -n 1)
    if [[ -f "$bin_path" ]]; then
        mv "$bin_path" "$INSTALL_DIR/$BINARY_DEFAULT"
        chmod +x "$INSTALL_DIR/$BINARY_DEFAULT"
        rm -rf "$tmp"
        print_success "PicoTun installed to $INSTALL_DIR/$BINARY_DEFAULT"
    else
        print_error "Binary not found in archive."
        exit 1
    fi
}

# --- Configuration Wizard ---

generate_psk() {
    openssl rand -hex 16
}

ask_profile() {
    echo ""
    echo -e "${YELLOW}Select Operation Mode:${NC}"
    echo "  1) 🚀 Speed (Low Security, No Obfuscation)"
    echo "  2) ⚖️  Balanced (Recommended - Standard Obfuscation)"
    echo "  3) 👻 Ghost (High Security - Heavy Obfuscation & Random Delays)"
    read -p "Choice [2]: " p_choice
    p_choice=${p_choice:-2}

    case $p_choice in
        1) # Speed
            OBFS_ENABLED="false"
            MIN_PAD=0; MAX_PAD=0
            MIN_DELAY=0; MAX_DELAY=0
            ;;
        3) # Ghost
            OBFS_ENABLED="true"
            MIN_PAD=100; MAX_PAD=1024
            MIN_DELAY=20; MAX_DELAY=100
            ;;
        *) # Balanced
            OBFS_ENABLED="true"
            MIN_PAD=16; MAX_PAD=256
            MIN_DELAY=0; MAX_DELAY=20
            ;;
    esac
}

configure_server() {
    print_header
    echo -e "${CYAN}:: SERVER CONFIGURATION ::${NC}"
    
    mkdir -p "$CONFIG_DIR"

    # 1. Network
    echo ""
    read -p "Tunnel Listen Port [1010]: " PORT
    PORT=${PORT:-1010}

    # 2. Security
    echo ""
    read -p "Tunnel Password (PSK) [Press Enter to Auto-Generate]: " PSK
    if [[ -z "$PSK" ]]; then
        PSK=$(generate_psk)
        echo -e "${GREEN}ℹ Generated PSK: $PSK${NC}"
    fi

    # 3. Profile
    ask_profile

    # 4. Mimicry
    echo ""
    echo -e "${YELLOW}HTTP Mimicry Settings:${NC}"
    read -p "Fake Domain [www.google.com]: " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    # 5. Reverse Tunneling (Port Mapping)
    echo ""
    echo -e "${YELLOW}Port Forwarding (Reverse Tunnel):${NC}"
    echo "This forwards traffic from THIS server to the CLIENT'S target."
    
    TCP_MAPS=()
    while true; do
        echo ""
        read -p "Do you want to map a port? (y/N): " map_yn
        [[ ! "$map_yn" =~ ^[Yy] ]] && break

        read -p "  ➤ Server Listen Port (e.g. 2080): " bind_port
        read -p "  ➤ Client Target IP:Port (e.g. 127.0.0.1:80): " target_addr
        
        if [[ -n "$bind_port" && -n "$target_addr" ]]; then
            TCP_MAPS+=("0.0.0.0:${bind_port}->${target_addr}")
            print_success "Mapped 0.0.0.0:${bind_port} -> Tunnel -> Client -> ${target_addr}"
        else
            print_error "Invalid input."
        fi
    done

    # Write Config
    cat > "$CONFIG_FILE" <<EOF
mode: server
listen: "0.0.0.0:${PORT}"
session_timeout: 15
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  session_cookie: true

obfs:
  enabled: ${OBFUS_ENABLED:-true}
  min_padding: ${MIN_PAD:-16}
  max_padding: ${MAX_PAD:-256}
  min_delay: ${MIN_DELAY:-0}
  max_delay: ${MAX_DELAY:-20}
  burst_chance: 10

forward:
  tcp:
EOF
    for map in "${TCP_MAPS[@]}"; do
        echo "    - \"$map\"" >> "$CONFIG_FILE"
    done
    echo "  udp: []" >> "$CONFIG_FILE"

    print_success "Server configuration saved!"
    install_service
}

configure_client() {
    print_header
    echo -e "${CYAN}:: CLIENT CONFIGURATION ::${NC}"
    
    mkdir -p "$CONFIG_DIR"

    # 1. Connection
    echo ""
    read -p "Server IP Address: " SERVER_IP
    read -p "Server Tunnel Port [1010]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-1010}
    
    SERVER_URL="http://${SERVER_IP}:${SERVER_PORT}/tunnel"

    # 2. Security
    echo ""
    read -p "Tunnel Password (PSK) [Must match server]: " PSK
    
    # 3. Profile
    ask_profile # Must match server ideally, but client enforces outbound

    # 4. Mimicry
    echo ""
    read -p "Fake Domain (Must match server) [www.google.com]: " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    # Write Config
    cat > "$CONFIG_FILE" <<EOF
mode: client
server_url: "${SERVER_URL}"
session_id: "sess-$(date +%s)"
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  session_cookie: true

obfs:
  enabled: ${OBFUS_ENABLED:-true}
  min_padding: ${MIN_PAD:-16}
  max_padding: ${MAX_PAD:-256}
  min_delay: ${MIN_DELAY:-0}
  max_delay: ${MAX_DELAY:-20}
  burst_chance: 10

forward:
  tcp: []
  udp: []
EOF

    print_success "Client configuration saved!"
    install_service
}

# --- Service Management ---

install_service() {
    print_step "Creating Systemd Service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PicoTun Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$BINARY_DEFAULT -config $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable picotun >/dev/null 2>&1
    systemctl restart picotun
    print_success "Service started successfully!"
    echo -e "${YELLOW}Logs:${NC} journalctl -u picotun -f"
    read -p "Press Enter to continue..."
}

uninstall_all() {
    print_step "Removing Service..."
    systemctl stop picotun >/dev/null 2>&1 || true
    systemctl disable picotun >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -f "$INSTALL_DIR/$BINARY_DEFAULT"
    
    read -p "Remove config files? (y/N): " rm_conf
    if [[ "$rm_conf" =~ ^[Yy] ]]; then
        rm -rf "$CONFIG_DIR"
    fi
    
    systemctl daemon-reload
    print_success "Uninstalled successfully."
}

# --- Main Menu ---

while true; do
    print_header
    echo "1) Install / Update Core"
    echo "2) Configure SERVER (Iran)"
    echo "3) Configure CLIENT (Kharej)"
    echo "4) Show Logs"
    echo "5) Restart Service"
    echo "6) Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select Option: " OPT

    case $OPT in
        1) 
            ensure_deps
            download_binary 
            read -p "Press Enter..."
            ;;
        2) configure_server ;;
        3) configure_client ;;
        4) journalctl -u picotun -f ;;
        5) systemctl restart picotun; print_success "Restarted."; sleep 1 ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done
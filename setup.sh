#!/bin/bash

# ==========================================
#      DaggerConnect Automation Suite
#      Built-in Compiler Edition
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/DaggerConnect"
SYSTEMD_DIR="/etc/systemd/system"
# 👇 آدرس ریپوزیتوری خودت را اینجا بگذار
REPO_URL="https://github.com/amir6dev/RsTunnel.git"

show_banner() {
    clear
    echo -e "${CYAN}***********************************${NC}"
    echo -e "${GREEN}    DaggerConnect (Source Build)   ${NC}"
    echo -e "${CYAN}***********************************${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root!${NC}"; exit 1; fi
}

install_deps() {
    echo -e "${YELLOW}📦 Installing System Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl nano >/dev/null 2>&1
}

# --- تغییر مهم: ساخت باینری از سورس ---
build_core() {
    echo -e "${YELLOW}⬇️  Building DaggerConnect Core...${NC}"
    rm -rf /tmp/dagger_build
    git clone $REPO_URL /tmp/dagger_build
    
    if [ ! -d "/tmp/dagger_build" ]; then
        echo -e "${RED}❌ Failed to clone repo!${NC}"; exit 1
    fi
    
    cd /tmp/dagger_build || exit
    go mod tidy >/dev/null 2>&1
    go build -o DaggerConnect main.go
    
    mv DaggerConnect $INSTALL_DIR/
    chmod +x $INSTALL_DIR/DaggerConnect
    echo -e "${GREEN}✓ Core Installed successfully${NC}"
}

generate_ssl() {
    mkdir -p "$CONFIG_DIR/certs"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CONFIG_DIR/certs/key.pem" \
        -out "$CONFIG_DIR/certs/cert.pem" \
        -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
}

create_service() {
    local MODE=$1
    local SERVICE_FILE="$SYSTEMD_DIR/DaggerConnect-${MODE}.service"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Reverse Tunnel ${MODE^}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/DaggerConnect -c $CONFIG_DIR/${MODE}.yaml
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable DaggerConnect-${MODE}
    systemctl restart DaggerConnect-${MODE}
}

# --- SERVER INSTALL ---

install_server() {
    install_deps
    build_core
    mkdir -p $CONFIG_DIR
    
    echo -e "${CYAN}:: SERVER CONFIGURATION ::${NC}"
    read -p "Tunnel Listen Port [1010]: " LISTEN_PORT; LISTEN_PORT=${LISTEN_PORT:-1010}
    read -p "PSK: " PSK
    
    # Maps Configuration
    echo -e "${YELLOW}Configure Port Mapping (Reverse):${NC}"
    read -p "Bind Port (Listen on Server) [1400]: " BIND_PORT; BIND_PORT=${BIND_PORT:-1400}
    read -p "Target Port (Local on Client) [1400]: " TARGET_PORT; TARGET_PORT=${TARGET_PORT:-1400}
    
    echo "Transport: 1) httpmux 2) httpsmux"
    read -p "Select: " T; if [[ "$T" == "2" ]]; then TRANS="httpsmux"; else TRANS="httpmux"; fi
    
    if [[ "$TRANS" == "httpsmux" ]]; then generate_ssl; fi
    
    # Write YAML
    cat > $CONFIG_DIR/server.yaml <<EOF
mode: "server"
listen: "0.0.0.0:$LISTEN_PORT"
transport: "$TRANS"
psk: "$PSK"
profile: "aggressive"
verbose: false

maps:
  - type: tcp
    bind: "0.0.0.0:$BIND_PORT"
    target: "127.0.0.1:$TARGET_PORT"
  - type: udp
    bind: "0.0.0.0:$BIND_PORT"
    target: "127.0.0.1:$TARGET_PORT"

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: true
  session_cookie: true
EOF

    if [[ "$TRANS" == "httpsmux" ]]; then
        echo "cert_file: \"$CONFIG_DIR/certs/cert.pem\"" >> $CONFIG_DIR/server.yaml
        echo "key_file: \"$CONFIG_DIR/certs/key.pem\"" >> $CONFIG_DIR/server.yaml
    fi

    create_service "server"
    echo -e "${GREEN}Server Installed!${NC}"
}

# --- CLIENT INSTALL ---

install_client() {
    install_deps
    build_core
    mkdir -p $CONFIG_DIR
    
    echo -e "${CYAN}:: CLIENT CONFIGURATION ::${NC}"
    read -p "Server IP: " SERVER_IP
    read -p "Server Tunnel Port [1010]: " SERVER_PORT; SERVER_PORT=${SERVER_PORT:-1010}
    read -p "PSK: " PSK
    
    echo "Transport: 1) httpmux 2) httpsmux"
    read -p "Select: " T; if [[ "$T" == "2" ]]; then TRANS="httpsmux"; else TRANS="httpmux"; fi
    
    cat > $CONFIG_DIR/client.yaml <<EOF
mode: "client"
psk: "$PSK"
profile: "aggressive"
verbose: false

paths:
  - transport: "$TRANS"
    addr: "$SERVER_IP:$SERVER_PORT"
    connection_pool: 4
    aggressive_pool: false
    retry_interval: 3
    dial_timeout: 10

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: true
  session_cookie: true
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://www.google.com/"
EOF

    create_service "client"
    echo -e "${GREEN}Client Installed!${NC}"
}

# --- MENUS ---

main_menu() {
    clear
    echo -e "${CYAN}=== DaggerConnect Manager ===${NC}"
    echo "1) Install Server"
    echo "2) Install Client"
    echo "3) Uninstall"
    echo "0) Exit"
    read -p "Select: " OPT
    case $OPT in
        1) install_server ;;
        2) install_client ;;
        3) 
           systemctl stop DaggerConnect-server DaggerConnect-client
           rm -rf $INSTALL_DIR/DaggerConnect $CONFIG_DIR
           echo "Uninstalled." ;;
        0) exit ;;
    esac
}

check_root
main_menu
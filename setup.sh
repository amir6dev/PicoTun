#!/bin/bash

# ====================================================
#      RsTunnel v2.1 - Ultimate Manager
#      Full Lifecycle: Install -> Manage -> Remove
# ====================================================

# --- Colors & Vars ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BIN_DIR="/usr/local/bin"
# 👇 آدرس ریپوزیتوری خودت رو چک کن
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
SERVICE_DIR="/etc/systemd/system"

# --- Helper Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Please run as root (sudo)!${NC}"; exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}📦 Installing Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl >/dev/null 2>&1
}

update_core() {
    echo -e "${YELLOW}⬇️ Building Core from Source...${NC}"
    rm -rf /tmp/rsbuild
    git clone $REPO_URL /tmp/rsbuild
    if [ ! -d "/tmp/rsbuild" ]; then
        echo -e "${RED}❌ Error: Could not clone repo. Check URL/Network.${NC}"
        return
    fi
    cd /tmp/rsbuild || exit
    go mod tidy >/dev/null 2>&1
    go build -o rstunnel-bridge bridge.go
    go build -o rstunnel-upstream upstream.go
    mv rstunnel-* $BIN_DIR/
    chmod +x $BIN_DIR/rstunnel-*
}

generate_ssl() {
    mkdir -p /etc/rstunnel/certs
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/rstunnel/certs/key.pem \
        -out /etc/rstunnel/certs/cert.pem \
        -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
}

detect_service() {
    SVC=""
    ROLE="None"
    if systemctl is-active --quiet rstunnel-bridge; then
        SVC="rstunnel-bridge"
        ROLE="Bridge (Server)"
    elif systemctl is-active --quiet rstunnel-upstream; then
        SVC="rstunnel-upstream"
        ROLE="Upstream (Client)"
    fi
}

# --- Install Logic ---

install_server() {
    install_dependencies
    update_core
    clear
    echo -e "${CYAN}:: INSTALL SERVER (BRIDGE) ::${NC}"
    
    echo ""
    echo "Select Transport:"
    echo "   1) httpmux"
    echo "   2) httpsmux (TLS) ⭐"
    read -p "Select [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    read -p "Tunnel Port [443]: " T_PORT
    T_PORT=${T_PORT:-443}

    echo "Select Profile:"
    echo "   1) balanced"
    echo "   2) aggressive"
    echo "   3) gaming"
    read -p "Select [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    if [[ "$MODE" == "httpsmux" ]]; then
        generate_ssl
        CERT_FLAGS="-cert /etc/rstunnel/certs/cert.pem -key /etc/rstunnel/certs/key.pem"
    fi

    read -p "Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "Fake Path [/search]: " F_PATH
    F_PATH=${F_PATH:-/search}

    read -p "User Bind Port [1432]: " U_PORT
    U_PORT=${U_PORT:-1432}

    echo -e "${YELLOW}⚙️ Configuring Systemd...${NC}"
    cat > $SERVICE_DIR/rstunnel-bridge.service <<EOF
[Unit]
Description=RsTunnel Bridge
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-bridge -l :$T_PORT -u :$U_PORT -m $MODE -profile $PROF -host $F_HOST -path $F_PATH $CERT_FLAGS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rstunnel-bridge
    systemctl restart rstunnel-bridge
    echo -e "${GREEN}✅ Server Installed!${NC}"
    read -p "Press Enter..."
}

install_client() {
    install_dependencies
    update_core
    clear
    echo -e "${CYAN}:: INSTALL CLIENT (UPSTREAM) ::${NC}"
    
    read -p "Server IP: " S_IP
    read -p "Server Port [443]: " S_PORT
    S_PORT=${S_PORT:-443}

    echo "Select Transport:"
    echo "   1) httpmux"
    echo "   2) httpsmux"
    read -p "Select [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    echo "Select Profile:"
    echo "   1) balanced"
    echo "   2) aggressive"
    echo "   3) gaming"
    read -p "Select [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    read -p "Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "Fake Path [/search]: " F_PATH
    F_PATH=${F_PATH:-/search}

    read -p "Local Panel Address [127.0.0.1:1432]: " LOC
    LOC=${LOC:-127.0.0.1:1432}

    echo -e "${YELLOW}⚙️ Configuring Systemd...${NC}"
    cat > $SERVICE_DIR/rstunnel-upstream.service <<EOF
[Unit]
Description=RsTunnel Upstream
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-upstream -c $S_IP:$S_PORT -p $LOC -m $MODE -profile $PROF -host $F_HOST -path $F_PATH
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rstunnel-upstream
    systemctl restart rstunnel-upstream
    echo -e "${GREEN}✅ Client Installed!${NC}"
    read -p "Press Enter..."
}

# --- Service Management ---

manage_service() {
    detect_service
    if [[ "$SVC" == "" ]]; then
        echo -e "${RED}❌ No active RsTunnel service found!${NC}"
        read -p "Press Enter..."
        return
    fi

    while true; do
        clear
        echo -e "${CYAN}:: SERVICE MANAGEMENT ::${NC}"
        echo -e "Current Service: ${GREEN}$SVC ($ROLE)${NC}"
        echo "1) Start Service"
        echo "2) Stop Service"
        echo "3) Restart Service"
        echo "4) View Status"
        echo "5) View Live Logs"
        echo "0) Back"
        echo ""
        read -p "Select: " OPT
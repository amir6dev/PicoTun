#!/bin/bash

# ====================================================
#      RsTunnel v4.0 - DaggerConnect Edition
#      Advanced Manager with Full Options
# ====================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- Configs ---
BIN_DIR="/usr/local/bin"
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
SERVICE_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/rstunnel"

# --- Helper Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Error: Please run this script as root!${NC}"
        exit 1
    fi
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "========================================================"
    echo "           🚀 RsTunnel Auto Installer v4.0"
    echo "      Based on DaggerConnect Architecture (Go)"
    echo "========================================================"
    echo -e "${NC}"
}

install_dependencies() {
    echo -e "${YELLOW}📦 Installing System Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl >/dev/null 2>&1
    echo -e "${GREEN}✅ Dependencies Ready.${NC}"
}

update_core() {
    echo -e "${YELLOW}⬇️ Downloading Core from GitHub...${NC}"
    rm -rf /tmp/rsbuild
    git clone $REPO_URL /tmp/rsbuild
    
    if [ ! -d "/tmp/rsbuild" ]; then
        echo -e "${RED}❌ Error: Could not clone repository.${NC}"
        return
    fi

    cd /tmp/rsbuild || exit
    
    echo -e "${PURPLE}⚙️ Compiling Binary Files...${NC}"
    go mod tidy >/dev/null 2>&1
    go build -o rstunnel-bridge bridge.go
    go build -o rstunnel-upstream upstream.go
    
    mv rstunnel-* $BIN_DIR/
    chmod +x $BIN_DIR/rstunnel-*
    
    echo -e "${GREEN}✅ Core Installed Successfully.${NC}"
}

generate_ssl() {
    echo -e "${YELLOW}🔐 Generating Self-Signed SSL Certificate...${NC}"
    mkdir -p $CONFIG_DIR/certs
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout $CONFIG_DIR/certs/key.pem \
        -out $CONFIG_DIR/certs/cert.pem \
        -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
    echo -e "${GREEN}✅ Certificate Generated.${NC}"
}

detect_service() {
    SVC=""
    ROLE="None"
    STATUS="${RED}Inactive${NC}"
    
    if systemctl is-active --quiet rstunnel-bridge; then
        SVC="rstunnel-bridge"
        ROLE="Bridge (Server)"
        STATUS="${GREEN}Active (Running)${NC}"
    elif systemctl is-active --quiet rstunnel-upstream; then
        SVC="rstunnel-upstream"
        ROLE="Upstream (Client)"
        STATUS="${GREEN}Active (Running)${NC}"
    fi
}

# --- Install Menus ---

install_server() {
    install_dependencies
    update_core
    show_banner
    echo -e "${CYAN}:: INSTALL SERVER (BRIDGE MODE) ::${NC}"
    echo ""
    
    # 1. Transport
    echo -e "${YELLOW}1. Select Transport Type:${NC}"
    echo "   1) httpmux   - HTTP Mimicry (Standard)"
    echo "   2) httpsmux  - HTTPS Mimicry (TLS + DPI Bypass) ⭐"
    read -p "   Select [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    # 2. Port
    echo ""
    echo -e "${YELLOW}2. Tunnel Configuration:${NC}"
    read -p "   - Tunnel Port (Listen for Upstream) [443]: " T_PORT
    T_PORT=${T_PORT:-443}
    read -p "   - User Bind Port (Listen for Users) [1432]: " U_PORT
    U_PORT=${U_PORT:-1432}

    # 3. Profile
    echo ""
    echo -e "${YELLOW}3. Performance Profile:${NC}"
    echo "   1) balanced      (Default)"
    echo "   2) aggressive    (High Throughput)"
    echo "   3) gaming        (Low Latency)"
    read -p "   Select [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    # 4. SSL
    CERT_FLAGS=""
    if [[ "$MODE" == "httpsmux" ]]; then
        echo ""
        echo -e "${YELLOW}4. SSL Configuration:${NC}"
        echo "   1) Auto-Generate Self-Signed Cert"
        echo "   2) Use Existing Cert Path"
        read -p "   Select [1-2]: " S_OPT
        if [[ "$S_OPT" == "1" ]]; then
            generate_ssl
            CERT_FLAGS="-cert $CONFIG_DIR/certs/cert.pem -key $CONFIG_DIR/certs/key.pem"
        else
            read -p "   - Cert Path: " CP
            read -p "   - Key Path: " KP
            CERT_FLAGS="-cert $CP -key $KP"
        fi
    fi

    # 5. Mimicry
    echo ""
    echo -e "${YELLOW}5. HTTP Mimicry Settings:${NC}"
    read -p "   - Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "   - Fake Path [/search]: " F_PATH
    F_PATH=${F_PATH:-/search}

    # Service
    echo ""
    echo -e "${PURPLE}⚙️  Creating Systemd Service...${NC}"
cat <<EOF > $SERVICE_DIR/rstunnel-bridge.service
[Unit]
Description=RsTunnel Bridge Server
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
    
    echo ""
    echo -e "${GREEN}✅ Server Installed & Running!${NC}"
    echo -e "   Mode: $MODE | Profile: $PROF | Port: $T_PORT"
    read -p "Press Enter to continue..."
}

install_client() {
    install_dependencies
    update_core
    show_banner
    echo -e "${CYAN}:: INSTALL CLIENT (UPSTREAM MODE) ::${NC}"
    echo ""
    
    # 1. Connection
    echo -e "${YELLOW}1. Connection Settings:${NC}"
    read -p "   - Bridge IP (Iran Server IP): " S_IP
    read -p "   - Bridge Port [443]: " S_PORT
    S_PORT=${S_PORT:-443}

    # 2. Transport
    echo ""
    echo -e "${YELLOW}2. Select Transport (Must match Server):${NC}"
    echo "   1) httpmux"
    echo "   2) httpsmux"
    read -p "   Select [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    # 3. Profile
    echo ""
    echo -e "${YELLOW}3. Select Profile:${NC}"
    echo "   1) balanced"
    echo "   2) aggressive"
    echo "   3) gaming"
    read -p "   Select [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    # 4. Mimicry
    echo ""
    echo -e "${YELLOW}4. HTTP Mimicry Settings:${NC}"
    read -p "   - Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "   - Fake Path [/search]: " F_PATH
    F_PATH=${F_PATH:-/search}

    # 5. Target
    echo ""
    echo -e "${YELLOW}5. Local Forwarding:${NC}"
    read -p "   - Local Panel Address [127.0.0.1:1432]: " LOC
    LOC=${LOC:-127.0.0.1:1432}

    # Service
    echo ""
    echo -e "${PURPLE}⚙️  Creating Systemd Service...${NC}"
cat <<EOF > $SERVICE_DIR/rstunnel-upstream.service
[Unit]
Description=RsTunnel Upstream Client
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
    
    echo ""
    echo -e "${GREEN}✅ Client Installed & Connected!${NC}"
    read -p "Press Enter to continue..."
}

# --- Management & Uninstall ---

manage_service() {
    detect_service
    if [[ "$SVC" == "" ]]; then
        echo -e "${RED}❌ No active RsTunnel service found.${NC}"
        read -p "Press Enter..."
        return
    fi

    while true; do
        show_banner
        echo -e "   Current Service: ${YELLOW}$SVC${NC}"
        echo -e "   Role:            ${CYAN}$ROLE${NC}"
        echo -e "   Status:          $STATUS"
        echo ""
        echo "   1) Start Service"
        echo "   2) Stop Service"
        echo "   3) Restart Service"
        echo "   4) View Live Logs"
        echo "   0) Back to Menu"
        echo ""
        read -p "   Select Option: " OPT
        case $OPT in
            1) systemctl start $SVC; echo -e "${GREEN}Started.${NC}"; sleep 1;;
            2) systemctl stop $SVC; echo -e "${RED}Stopped.${NC}"; sleep 1;;
            3) systemctl restart $SVC; echo -e "${GREEN}Restarted.${NC}"; sleep 1;;
            4) journalctl -u $SVC -f;;
            0) return;;
            *) echo "Invalid"; sleep 1;;
        esac
        detect_service # Refresh status
    done
}

uninstall_all() {
    show_banner
    echo -e "${RED}⚠️  DANGER ZONE: FULL UNINSTALL ⚠️${NC}"
    echo ""
    echo "   This action will remove:"
    echo "   1. All RsTunnel Services (Bridge & Upstream)"
    echo "   2. All Binary Files"
    echo "   3. All Configurations & SSL Certificates"
    echo ""
    read -p "   Are you sure? (y/N): " CONFIRM
    
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        return
    fi

    echo -e "${YELLOW}Stopping services...${NC}"
    systemctl stop rstunnel-bridge rstunnel-upstream 2>/dev/null
    systemctl disable rstunnel-bridge rstunnel-upstream 2>/dev/null
    
    echo -e "${YELLOW}Removing files...${NC}"
    rm -f $SERVICE_DIR/rstunnel-*.service
    rm -f $BIN_DIR/rstunnel-*
    rm -rf $CONFIG_DIR
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ Uninstallation Complete.${NC}"
    read -p "Press Enter..."
}

# --- Main Loop ---

check_root
while true; do
    show_banner
    detect_service
    echo -e "   System Status: $STATUS"
    echo ""
    echo "   1) Install Server (Iran/Bridge)"
    echo "   2) Install Client (Kharej/Upstream)"
    echo "   3) Service Management (Logs/Start/Stop)"
    echo "   4) Update Core (Force Rebuild)"
    echo "   5) Uninstall (Remove Everything)"
    echo "   0) Exit"
    echo ""
    read -p "   Select Option: " OPT
    
    case $OPT in
        1) install_server ;;
        2) install_client ;;
        3) manage_service ;;
        4) update_core; read -p "Press Enter..." ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo "Invalid Option"; sleep 1 ;;
    esac
done
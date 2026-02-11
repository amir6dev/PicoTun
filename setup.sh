#!/bin/bash

# ====================================================
#      RsTunnel v3.0 - Ultimate Manager
#      Fixed Syntax & Full Features
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BIN_DIR="/usr/local/bin"
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
SERVICE_DIR="/etc/systemd/system"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Please run as root!${NC}"; exit 1
    fi
}

install_deps() {
    echo -e "${YELLOW}📦 Installing Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl >/dev/null 2>&1
}

update_core() {
    echo -e "${YELLOW}⬇️ Building Core...${NC}"
    rm -rf /tmp/rsbuild
    git clone $REPO_URL /tmp/rsbuild
    if [ ! -d "/tmp/rsbuild" ]; then
        echo -e "${RED}❌ Error cloning repo! Check URL.${NC}"
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
    if systemctl is-active --quiet rstunnel-bridge; then SVC="rstunnel-bridge"; fi
    if systemctl is-active --quiet rstunnel-upstream; then SVC="rstunnel-upstream"; fi
}

install_server() {
    install_deps
    update_core
    clear
    echo -e "${CYAN}:: INSTALL SERVER (BRIDGE) ::${NC}"
    
    echo "1) httpmux"
    echo "2) httpsmux (TLS)"
    read -p "Select [1-2]: " M_OPT
    if [[ "$M_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    read -p "Tunnel Port [443]: " TPORT
    TPORT=${TPORT:-443}

    CERT_FLAGS=""
    if [[ "$MODE" == "httpsmux" ]]; then
        generate_ssl
        CERT_FLAGS="-cert /etc/rstunnel/certs/cert.pem -key /etc/rstunnel/certs/key.pem"
    fi

    echo "1) balanced 2) aggressive 3) gaming"
    read -p "Select Profile [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    read -p "Fake Host [www.google.com]: " FHOST
    FHOST=${FHOST:-www.google.com}

    read -p "User Port [1432]: " UPORT
    UPORT=${UPORT:-1432}

    echo -e "${YELLOW}Configuring Service...${NC}"
    cat <<EOF > $SERVICE_DIR/rstunnel-bridge.service
[Unit]
Description=RsTunnel Bridge
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-bridge -l :$TPORT -u :$UPORT -m $MODE -profile $PROF -host $FHOST $CERT_FLAGS
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
    install_deps
    update_core
    clear
    echo -e "${CYAN}:: INSTALL CLIENT (UPSTREAM) ::${NC}"
    
    read -p "Server IP: " SIP
    read -p "Server Port [443]: " SPORT
    SPORT=${SPORT:-443}

    echo "1) httpmux 2) httpsmux"
    read -p "Select: " M_OPT
    if [[ "$M_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    echo "1) balanced 2) aggressive 3) gaming"
    read -p "Select Profile: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    read -p "Fake Host [www.google.com]: " FHOST
    FHOST=${FHOST:-www.google.com}

    read -p "Local Panel [127.0.0.1:1432]: " LOC
    LOC=${LOC:-127.0.0.1:1432}

    echo -e "${YELLOW}Configuring Service...${NC}"
    cat <<EOF > $SERVICE_DIR/rstunnel-upstream.service
[Unit]
Description=RsTunnel Upstream
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-upstream -c $SIP:$SPORT -p $LOC -m $MODE -profile $PROF -host $FHOST
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

manage_service() {
    detect_service
    if [[ "$SVC" == "" ]]; then
        echo -e "${RED}No active service found.${NC}"
        read -p "Enter..."
        return
    fi
    while true; do
        clear
        echo -e "Service: ${GREEN}$SVC${NC}"
        echo "1) Start 2) Stop 3) Restart 4) Logs 0) Back"
        read -p "Opt: " OPT
        case $OPT in
            1) systemctl start $SVC; echo "Started"; sleep 1;;
            2) systemctl stop $SVC; echo "Stopped"; sleep 1;;
            3) systemctl restart $SVC; echo "Restarted"; sleep 1;;
            4) journalctl -u $SVC -f;;
            0) return;;
        esac
    done
}

uninstall() {
    echo -e "${RED}⚠️ UNINSTALLING...${NC}"
    systemctl stop rstunnel-bridge rstunnel-upstream 2>/dev/null
    systemctl disable rstunnel-bridge rstunnel-upstream 2>/dev/null
    rm -f $SERVICE_DIR/rstunnel-*.service
    rm -f $BIN_DIR/rstunnel-*
    rm -rf /etc/rstunnel
    systemctl daemon-reload
    echo -e "${GREEN}✅ Removed.${NC}"
    read -p "Enter..."
}

check_root
while true; do
    clear
    echo -e "${CYAN}--- RsTunnel Manager v3.0 ---${NC}"
    echo "1) Install Server (Iran)"
    echo "2) Install Client (Kharej)"
    echo "3) Manage Service"
    echo "4) Uninstall"
    echo "0) Exit"
    read -p "Select: " OPT
    case $OPT in
        1) install_server ;;
        2) install_client ;;
        3) manage_service ;;
        4) uninstall ;;
        0) exit 0 ;;
    esac
done
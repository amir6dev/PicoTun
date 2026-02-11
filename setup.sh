#!/bin/bash

# ====================================================
#      RsTunnel v7.0 - DaggerConnect Clone
#      Full YAML Config Support & Service Management
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BIN_DIR="/usr/local/bin"
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
CONFIG_DIR="/etc/rstunnel"
SERVICE_DIR="/etc/systemd/system"

check_root() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root!${NC}"; exit 1; fi
}

install_deps() {
    if ! command -v go &> /dev/null; then
        apt update -qq >/dev/null 2>&1
        apt install -y git golang openssl curl >/dev/null 2>&1
    fi
}

update_core() {
    if [[ ! -f "$BIN_DIR/rstunnel" ]]; then
        echo -e "${YELLOW}⬇️  Building RsTunnel Core...${NC}"
        rm -rf /tmp/rsbuild
        git clone $REPO_URL /tmp/rsbuild
        cd /tmp/rsbuild || exit
        go mod tidy >/dev/null 2>&1
        go build -o rstunnel main.go config.go
        mv rstunnel $BIN_DIR/
        chmod +x $BIN_DIR/rstunnel
        echo -e "${GREEN}✅ Core Installed.${NC}"
    fi
}

# --- Config Generators (YAML) ---

generate_client_config() {
    mkdir -p $CONFIG_DIR
    cat > $CONFIG_DIR/client.yaml <<EOF
mode: "client"
psk: "$PSK"
profile: "$PROFILE"
verbose: true

paths:
  - transport: "$MODE"
    addr: "$SERVER_IP:$SERVER_PORT"
    connection_pool: $POOL
    aggressive_pool: $AGG
    retry_interval: 3
    dial_timeout: 10

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "$FHOST"
  fake_path: "$FPATH"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  chunked_encoding: true
  session_cookie: true
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://$FHOST/"

smux:
  keepalive: 5
  max_recv: 16777216
  max_stream: 16777216
  frame_size: 32768
  version: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 15
  tcp_read_buffer: 8388608
  tcp_write_buffer: 8388608
  connection_timeout: 60
EOF
}

generate_server_config() {
    mkdir -p $CONFIG_DIR
    cat > $CONFIG_DIR/server.yaml <<EOF
mode: "server"
listen: "0.0.0.0:$TPORT"
transport: "$MODE"
psk: "$PSK"
profile: "$PROFILE"
verbose: true

cert_file: "$CERT_FILE"
key_file: "$KEY_KEY"

maps:
  - type: tcp
    bind: "0.0.0.0:$UPORT"
    target: "127.0.0.1:$TPORT"

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "$FHOST"
  fake_path: "$FPATH"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  chunked_encoding: true
  session_cookie: true
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://$FHOST/"

smux:
  keepalive: 5
  max_recv: 16777216
  max_stream: 16777216
  frame_size: 32768
  version: 2

advanced:
  tcp_nodelay: true
  tcp_keepalive: 15
  tcp_read_buffer: 8388608
  tcp_write_buffer: 8388608
  connection_timeout: 60
EOF
}

# --- Menus ---

install_client_menu() {
    install_deps
    update_core
    echo -e "${CYAN}:: CLIENT INSTALLATION ::${NC}"
    
    read -p "PSK: " PSK
    read -p "Server IP: " SERVER_IP
    read -p "Server Port [443]: " SERVER_PORT; SERVER_PORT=${SERVER_PORT:-443}
    
    echo "Transport: 1) httpmux 2) httpsmux"
    read -p "Select: " M; if [[ "$M" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi
    
    echo "Profile: 1) balanced 2) aggressive"
    read -p "Select: " P; if [[ "$P" == "2" ]]; then PROFILE="aggressive"; else PROFILE="balanced"; fi
    
    read -p "Fake Host [www.google.com]: " FHOST; FHOST=${FHOST:-www.google.com}
    read -p "Fake Path [/search]: " FPATH; FPATH=${FPATH:-/search}
    
    read -p "Connection Pool [4]: " POOL; POOL=${POOL:-4}
    read -p "Aggressive Pool (true/false) [false]: " AGG; AGG=${AGG:-false}
    
    generate_client_config
    
    # Service
    cat > $SERVICE_DIR/rstunnel-client.service <<EOF
[Unit]
Description=RsTunnel Client
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel -c $CONFIG_DIR/client.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rstunnel-client
    systemctl start rstunnel-client
    echo -e "${GREEN}✅ Client Configured & Started!${NC}"
    read -p "Enter..."
}

client_settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}:: CLIENT SETTINGS ::${NC}"
        echo "  1) Start Client"
        echo "  2) Stop Client"
        echo "  3) Restart Client"
        echo "  4) Client Status"
        echo "  5) View Client Logs (Live)"
        echo "  6) Enable Client Auto-start"
        echo "  7) Disable Client Auto-start"
        echo ""
        echo "  8) View Client Config"
        echo "  9) Edit Client Config"
        echo "  10) Delete Client Config & Service"
        echo ""
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select option: " OPT
        
        SVC="rstunnel-client"
        CFG="$CONFIG_DIR/client.yaml"
        
        case $OPT in
            1) systemctl start $SVC; echo "Started."; sleep 1;;
            2) systemctl stop $SVC; echo "Stopped."; sleep 1;;
            3) systemctl restart $SVC; echo "Restarted."; sleep 1;;
            4) systemctl status $SVC --no-pager; read -p "Enter...";;
            5) journalctl -u $SVC -f;;
            6) systemctl enable $SVC; echo "Enabled."; sleep 1;;
            7) systemctl disable $SVC; echo "Disabled."; sleep 1;;
            8) cat $CFG; read -p "Enter...";;
            9) nano $CFG; systemctl restart $SVC;;
            10) 
                systemctl stop $SVC
                systemctl disable $SVC
                rm $CFG $SERVICE_DIR/$SVC.service
                systemctl daemon-reload
                echo "Deleted."; sleep 1; return;;
            0) return;;
        esac
    done
}

# --- Main ---
check_root
while true; do
    clear
    echo -e "${CYAN}=== RsTunnel v7.0 (Dagger Clone) ===${NC}"
    echo "  1) Install Client"
    echo "  2) Install Server"
    echo "  3) Client Settings"
    echo "  4) Server Settings"
    echo "  0) Exit"
    echo ""
    read -p "Select option: " OPT
    case $OPT in
        1) install_client_menu ;;
        3) client_settings_menu ;;
        0) exit ;;
    esac
done
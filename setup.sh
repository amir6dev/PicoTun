#!/bin/bash

# ====================================================
#      RsTunnel v8.0 - Enterprise Edition
#      Full DaggerConnect Clone & YAML Manager
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

# --- Init ---
mkdir -p $CONFIG_DIR
mkdir -p $CONFIG_DIR/certs

check_root() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Please run as root!${NC}"; exit 1; fi
}

install_deps() {
    if ! command -v go &> /dev/null; then
        echo -e "${YELLOW}Installing Go & Deps...${NC}"
        apt update -qq >/dev/null 2>&1
        apt install -y git golang openssl curl nano >/dev/null 2>&1
    fi
}

update_core() {
    if [[ ! -f "$BIN_DIR/rstunnel" ]]; then
        echo -e "${YELLOW}Building RsTunnel Core...${NC}"
        rm -rf /tmp/rsbuild
        git clone $REPO_URL /tmp/rsbuild
        cd /tmp/rsbuild || exit
        go mod tidy >/dev/null 2>&1
        go build -o rstunnel main.go config.go
        mv rstunnel $BIN_DIR/
        chmod +x $BIN_DIR/rstunnel
        echo -e "${GREEN}Core Installed.${NC}"
    fi
}

generate_ssl() {
    if [[ ! -f "$CONFIG_DIR/certs/cert.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout $CONFIG_DIR/certs/key.pem \
            -out $CONFIG_DIR/certs/cert.pem \
            -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
    fi
}

# --- YAML Generators ---

write_client_yaml() {
    FILE="$CONFIG_DIR/client.yaml"
    echo "mode: \"client\"" > $FILE
    echo "psk: \"$PSK\"" >> $FILE
    echo "profile: \"$PROFILE\"" >> $FILE
    echo "verbose: true" >> $FILE
    echo "" >> $FILE
    echo "paths:" >> $FILE
    echo "  - transport: \"$MODE\"" >> $FILE
    echo "    addr: \"$SERVER_IP:$SERVER_PORT\"" >> $FILE
    echo "    connection_pool: $POOL" >> $FILE
    echo "    aggressive_pool: $AGG" >> $FILE
    echo "    retry_interval: 3" >> $FILE
    echo "    dial_timeout: 10" >> $FILE
    echo "" >> $FILE
    echo "obfuscation:" >> $FILE
    echo "  enabled: true" >> $FILE
    echo "  min_padding: 16" >> $FILE
    echo "  max_padding: 512" >> $FILE
    echo "  min_delay_ms: 5" >> $FILE
    echo "  max_delay_ms: 50" >> $FILE
    echo "  burst_chance: 0.15" >> $FILE
    echo "" >> $FILE
    echo "http_mimic:" >> $FILE
    echo "  fake_domain: \"$FHOST\"" >> $FILE
    echo "  fake_path: \"$FPATH\"" >> $FILE
    echo "  user_agent: \"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\"" >> $FILE
    echo "  chunked_encoding: true" >> $FILE
    echo "  session_cookie: true" >> $FILE
    echo "  custom_headers:" >> $FILE
    echo "    - \"X-Requested-With: XMLHttpRequest\"" >> $FILE
    echo "    - \"Referer: https://$FHOST/\"" >> $FILE
    echo "" >> $FILE
    echo "smux:" >> $FILE
    echo "  keepalive: 5" >> $FILE
    echo "  max_recv: 16777216" >> $FILE
    echo "  max_stream: 16777216" >> $FILE
    echo "  frame_size: 32768" >> $FILE
    echo "  version: 2" >> $FILE
    echo "" >> $FILE
    echo "advanced:" >> $FILE
    echo "  tcp_nodelay: true" >> $FILE
    echo "  tcp_keepalive: 15" >> $FILE
    echo "  tcp_read_buffer: 8388608" >> $FILE
    echo "  tcp_write_buffer: 8388608" >> $FILE
    echo "  connection_timeout: 60" >> $FILE
}

write_server_yaml() {
    FILE="$CONFIG_DIR/server.yaml"
    echo "mode: \"server\"" > $FILE
    echo "listen: \"0.0.0.0:$TPORT\"" >> $FILE
    echo "transport: \"$MODE\"" >> $FILE
    echo "psk: \"$PSK\"" >> $FILE
    echo "profile: \"$PROFILE\"" >> $FILE
    echo "verbose: true" >> $FILE
    echo "" >> $FILE
    echo "cert_file: \"$CONFIG_DIR/certs/cert.pem\"" >> $FILE
    echo "key_file: \"$CONFIG_DIR/certs/key.pem\"" >> $FILE
    echo "" >> $FILE
    echo "maps:" >> $FILE
    echo "  - type: tcp" >> $FILE
    echo "    bind: \"0.0.0.0:$UPORT\"" >> $FILE
    echo "    target: \"127.0.0.1:$TPORT\"" >> $FILE
    echo "" >> $FILE
    echo "obfuscation:" >> $FILE
    echo "  enabled: true" >> $FILE
    echo "  min_padding: 16" >> $FILE
    echo "  max_padding: 512" >> $FILE
    echo "  min_delay_ms: 5" >> $FILE
    echo "  max_delay_ms: 50" >> $FILE
    echo "  burst_chance: 0.15" >> $FILE
    echo "" >> $FILE
    echo "http_mimic:" >> $FILE
    echo "  fake_domain: \"$FHOST\"" >> $FILE
    echo "  fake_path: \"$FPATH\"" >> $FILE
    echo "  user_agent: \"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\"" >> $FILE
    echo "  chunked_encoding: true" >> $FILE
    echo "  session_cookie: true" >> $FILE
    echo "  custom_headers:" >> $FILE
    echo "    - \"X-Requested-With: XMLHttpRequest\"" >> $FILE
    echo "    - \"Referer: https://$FHOST/\"" >> $FILE
    echo "" >> $FILE
    echo "smux:" >> $FILE
    echo "  keepalive: 5" >> $FILE
    echo "  max_recv: 16777216" >> $FILE
    echo "  max_stream: 16777216" >> $FILE
    echo "  frame_size: 32768" >> $FILE
    echo "  version: 2" >> $FILE
    echo "" >> $FILE
    echo "advanced:" >> $FILE
    echo "  tcp_nodelay: true" >> $FILE
    echo "  tcp_keepalive: 15" >> $FILE
    echo "  tcp_read_buffer: 8388608" >> $FILE
    echo "  tcp_write_buffer: 8388608" >> $FILE
    echo "  connection_timeout: 60" >> $FILE
}

# --- Service Creator ---

create_service() {
    NAME=$1
    CFG=$2
    FILE="$SERVICE_DIR/$NAME.service"
    
    echo "[Unit]" > $FILE
    echo "Description=RsTunnel $NAME" >> $FILE
    echo "After=network.target" >> $FILE
    echo "" >> $FILE
    echo "[Service]" >> $FILE
    echo "Type=simple" >> $FILE
    echo "User=root" >> $FILE
    echo "LimitNOFILE=1048576" >> $FILE
    echo "ExecStart=$BIN_DIR/rstunnel -c $CFG" >> $FILE
    echo "Restart=always" >> $FILE
    echo "RestartSec=3" >> $FILE
    echo "" >> $FILE
    echo "[Install]" >> $FILE
    echo "WantedBy=multi-user.target" >> $FILE
    
    systemctl daemon-reload
    systemctl enable $NAME
    systemctl restart $NAME
}

# --- Install Menus ---

install_client_menu() {
    install_deps
    update_core
    echo -e "${CYAN}:: INSTALL CLIENT ::${NC}"
    
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
    
    write_client_yaml
    create_service "rstunnel-client" "$CONFIG_DIR/client.yaml"
    
    echo -e "${GREEN}✅ Client Installed!${NC}"
    read -p "Press Enter..."
}

install_server_menu() {
    install_deps
    update_core
    echo -e "${CYAN}:: INSTALL SERVER ::${NC}"
    
    read -p "Tunnel Port [443]: " TPORT; TPORT=${TPORT:-443}
    read -p "PSK: " PSK
    
    echo "Transport: 1) httpmux 2) httpsmux"
    read -p "Select: " M; if [[ "$M" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi
    
    echo "Profile: 1) balanced 2) aggressive"
    read -p "Select: " P; if [[ "$P" == "2" ]]; then PROFILE="aggressive"; else PROFILE="balanced"; fi
    
    read -p "Fake Host [www.google.com]: " FHOST; FHOST=${FHOST:-www.google.com}
    read -p "Fake Path [/search]: " FPATH; FPATH=${FPATH:-/search}
    
    read -p "User Bind Port [1432]: " UPORT; UPORT=${UPORT:-1432}
    
    if [[ "$MODE" == "httpsmux" ]]; then generate_ssl; fi
    
    write_server_yaml
    create_service "rstunnel-server" "$CONFIG_DIR/server.yaml"
    
    echo -e "${GREEN}✅ Server Installed!${NC}"
    read -p "Press Enter..."
}

# --- Management Menus ---

manage_client() {
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
        echo "  0) Back to Settings"
        echo ""
        read -p "Select option: " OPT
        
        SVC="rstunnel-client"
        FILE="$CONFIG_DIR/client.yaml"
        
        case $OPT in
            1) systemctl start $SVC; echo "Started."; sleep 1;;
            2) systemctl stop $SVC; echo "Stopped."; sleep 1;;
            3) systemctl restart $SVC; echo "Restarted."; sleep 1;;
            4) systemctl status $SVC --no-pager; read -p "Enter...";;
            5) journalctl -u $SVC -f;;
            6) systemctl enable $SVC; echo "Enabled."; sleep 1;;
            7) systemctl disable $SVC; echo "Disabled."; sleep 1;;
            8) cat $FILE; read -p "Enter...";;
            9) nano $FILE; systemctl restart $SVC; echo "Updated."; sleep 1;;
            10) 
                systemctl stop $SVC
                systemctl disable $SVC
                rm -f $FILE $SERVICE_DIR/$SVC.service
                systemctl daemon-reload
                echo "Deleted."; sleep 1; return;;
            0) return;;
            *) echo "Invalid"; sleep 1;;
        esac
    done
}

manage_server() {
    while true; do
        clear
        echo -e "${CYAN}:: SERVER SETTINGS ::${NC}"
        echo "  1) Start Server"
        echo "  2) Stop Server"
        echo "  3) Restart Server"
        echo "  4) Server Status"
        echo "  5) View Server Logs (Live)"
        echo "  6) Enable Server Auto-start"
        echo "  7) Disable Server Auto-start"
        echo ""
        echo "  8) View Server Config"
        echo "  9) Edit Server Config"
        echo "  10) Delete Server Config & Service"
        echo ""
        echo "  0) Back to Settings"
        echo ""
        read -p "Select option: " OPT
        
        SVC="rstunnel-server"
        FILE="$CONFIG_DIR/server.yaml"
        
        case $OPT in
            1) systemctl start $SVC; echo "Started."; sleep 1;;
            2) systemctl stop $SVC; echo "Stopped."; sleep 1;;
            3) systemctl restart $SVC; echo "Restarted."; sleep 1;;
            4) systemctl status $SVC --no-pager; read -p "Enter...";;
            5) journalctl -u $SVC -f;;
            6) systemctl enable $SVC; echo "Enabled."; sleep 1;;
            7) systemctl disable $SVC; echo "Disabled."; sleep 1;;
            8) cat $FILE; read -p "Enter...";;
            9) nano $FILE; systemctl restart $SVC; echo "Updated."; sleep 1;;
            10) 
                systemctl stop $SVC
                systemctl disable $SVC
                rm -f $FILE $SERVICE_DIR/$SVC.service
                systemctl daemon-reload
                echo "Deleted."; sleep 1; return;;
            0) return;;
            *) echo "Invalid"; sleep 1;;
        esac
    done
}

# --- Main ---
check_root
while true; do
    clear
    echo -e "${CYAN}=== RsTunnel v8.0 (Enterprise) ===${NC}"
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Server Settings"
    echo "  4) Client Settings"
    echo "  5) Uninstall All"
    echo "  0) Exit"
    echo ""
    read -p "Select option: " OPT
    case $OPT in
        1) install_server_menu ;;
        2) install_client_menu ;;
        3) manage_server ;;
        4) manage_client ;;
        5) 
           systemctl stop rstunnel-client rstunnel-server 2>/dev/null
           rm -f $BIN_DIR/rstunnel
           rm -rf $CONFIG_DIR
           echo "Uninstalled."; sleep 1;;
        0) exit ;;
    esac
done
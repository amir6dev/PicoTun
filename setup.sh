#!/bin/bash

# ==========================================
#      DaggerConnect Automation Suite
#      v1.1 (Full Features)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/DaggerConnect"
SYSTEMD_DIR="/etc/systemd/system"
# 👇 آدرس ریپوزیتوری خودت
REPO_URL="https://github.com/amir6dev/RsTunnel.git"

check_root() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root!${NC}"; exit 1; fi
}

install_deps() {
    echo -e "${YELLOW}📦 Installing Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl nano >/dev/null 2>&1
}

build_core() {
    echo -e "${YELLOW}⬇️  Building DaggerConnect...${NC}"
    rm -rf /tmp/dagger_build
    git clone $REPO_URL /tmp/dagger_build
    cd /tmp/dagger_build || exit
    go mod tidy >/dev/null 2>&1
    go build -o DaggerConnect main.go
    mv DaggerConnect $INSTALL_DIR/
    chmod +x $INSTALL_DIR/DaggerConnect
}

generate_ssl() {
    mkdir -p "$CONFIG_DIR/certs"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CONFIG_DIR/certs/key.pem" \
        -out "$CONFIG_DIR/certs/cert.pem" \
        -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
}

# --- SERVER INSTALLATION (11 STEPS) ---

install_server() {
    install_deps
    build_core
    mkdir -p $CONFIG_DIR
    
    echo -e "${CYAN}:: INSTALL SERVER ::${NC}"
    echo ""

    # 1. Transport Type
    echo "2. انتخاب Transport Type:"
    echo "   1) tcpmux   - TCP Multiplexing"
    echo "   2) kcpmux   - KCP Multiplexing"
    echo "   3) wsmux    - WebSocket"
    echo "   4) wssmux   - WebSocket Secure"
    echo "   5) httpmux  - HTTP Mimicry (DPI bypass) 🆕"
    echo "   6) httpsmux - HTTPS Mimicry (TLS + DPI bypass) ⭐"
    read -p "Select [1-6]: " T
    case $T in
        1) TRANS="tcpmux" ;; 2) TRANS="kcpmux" ;; 3) TRANS="wsmux" ;;
        4) TRANS="wssmux" ;; 5) TRANS="httpmux" ;; 6) TRANS="httpsmux" ;;
        *) TRANS="httpmux" ;;
    esac

    # 2. Tunnel Port
    echo ""
    read -p "3. پورت Tunnel را وارد کنید [443]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}

    # 3. PSK
    echo ""
    read -p "4. PSK (رمز ارتباط) را وارد کنید: " PSK

    # 4. Profile
    echo ""
    echo "5. پروفایل عملکرد را انتخاب کنید:"
    echo "   1) balanced"
    echo "   2) aggressive"
    echo "   3) latency"
    echo "   4) cpu-efficient"
    echo "   5) gaming"
    read -p "Select [1-5]: " P
    case $P in
        1) PROFILE="balanced" ;; 2) PROFILE="aggressive" ;; 3) PROFILE="latency" ;;
        4) PROFILE="cpu-efficient" ;; 5) PROFILE="gaming" ;; *) PROFILE="balanced" ;;
    esac

    # 5. SSL Settings
    if [[ "$TRANS" == "httpsmux" || "$TRANS" == "wssmux" ]]; then
        echo ""
        echo "6. تنظیم SSL:"
        echo "   1) Generate self-signed certificate ✅"
        echo "   2) Use existing certificate files"
        read -p "Select [1-2]: " SSL_OPT
        if [[ "$SSL_OPT" == "1" ]]; then
            generate_ssl
            CERT_CFG="cert_file: \"$CONFIG_DIR/certs/cert.pem\"\nkey_file: \"$CONFIG_DIR/certs/key.pem\""
        else
            read -p "Path to Cert: " CP
            read -p "Path to Key: " KP
            CERT_CFG="cert_file: \"$CP\"\nkey_file: \"$KP\""
        fi
    else
        CERT_CFG=""
    fi

    # 6. HTTP Mimicry Settings
    if [[ "$TRANS" == "httpmux" || "$TRANS" == "httpsmux" ]]; then
        echo ""
        echo "7. HTTP Mimicry Settings:"
        read -p "   - Fake domain [www.google.com]: " FHOST; FHOST=${FHOST:-www.google.com}
        read -p "   - Fake path [/search]: " FPATH; FPATH=${FPATH:-/search}
        read -p "   - User-Agent [Chrome...]: " UA; UA=${UA:-"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"}
        read -p "   - Chunked encoding (Y/n): " CHUNK; [[ $CHUNK =~ ^[Nn]$ ]] && CHUNK_BOOL="false" || CHUNK_BOOL="true"
        read -p "   - Session cookies (Y/n): " COOKIE; [[ $COOKIE =~ ^[Nn]$ ]] && COOKIE_BOOL="false" || COOKIE_BOOL="true"
        
        MIMIC_CFG="http_mimic:\n  fake_domain: \"$FHOST\"\n  fake_path: \"$FPATH\"\n  user_agent: \"$UA\"\n  chunked_encoding: $CHUNK_BOOL\n  session_cookie: $COOKIE_BOOL\n  custom_headers:\n    - \"X-Requested-With: XMLHttpRequest\"\n    - \"Referer: https://$FHOST/\""
    else
        MIMIC_CFG="http_mimic:\n  fake_domain: \"www.google.com\"\n  fake_path: \"/search\"\n  user_agent: \"Mozilla/5.0\"\n  chunked_encoding: true\n  session_cookie: true\n  custom_headers: []"
    fi

    # 7. Traffic Obfuscation
    echo ""
    echo "8. فعال‌سازی Traffic Obfuscation:"
    read -p "   Enable? (Y/n): " OBFUS
    if [[ ! $OBFUS =~ ^[Nn]$ ]]; then
        read -p "   - Min Padding [16]: " MIN_P; MIN_P=${MIN_P:-16}
        read -p "   - Max Padding [512]: " MAX_P; MAX_P=${MAX_P:-512}
        read -p "   - Min Delay ms [5]: " MIN_D; MIN_D=${MIN_D:-5}
        read -p "   - Max Delay ms [50]: " MAX_D; MAX_D=${MAX_D:-50}
        OBFUS_CFG="obfuscation:\n  enabled: true\n  min_padding: $MIN_P\n  max_padding: $MAX_P\n  min_delay_ms: $MIN_D\n  max_delay_ms: $MAX_D\n  burst_chance: 0.15"
    else
        OBFUS_CFG="obfuscation:\n  enabled: false\n  min_padding: 0\n  max_padding: 0\n  min_delay_ms: 0\n  max_delay_ms: 0\n  burst_chance: 0"
    fi

    # 8. Advanced Settings
    echo ""
    echo "9. Advanced Settings (اختیاری):"
    read -p "   Configure? (y/N): " ADV
    if [[ $ADV =~ ^[Yy]$ ]]; then
        echo "   [SMUX]"
        read -p "   - KeepAlive [10]: " S_KA; S_KA=${S_KA:-10}
        read -p "   - Max Recv Buffer [4194304]: " S_MR; S_MR=${S_MR:-4194304}
        read -p "   - Max Stream Buffer [1048576]: " S_MS; S_MS=${S_MS:-1048576}
        read -p "   - Frame Size [32768]: " S_FS; S_FS=${S_FS:-32768}
        
        echo "   [TCP]"
        read -p "   - NoDelay (true/false) [true]: " T_ND; T_ND=${T_ND:-true}
        read -p "   - KeepAlive [15]: " T_KA; T_KA=${T_KA:-15}
        read -p "   - Read Buffer [4194304]: " T_RB; T_RB=${T_RB:-4194304}
        read -p "   - Write Buffer [4194304]: " T_WB; T_WB=${T_WB:-4194304}
        read -p "   - Max Connections [2000]: " MAX_C; MAX_C=${MAX_C:-2000}
        
        ADV_CFG="smux:\n  keepalive: $S_KA\n  max_recv: $S_MR\n  max_stream: $S_MS\n  frame_size: $S_FS\n  version: 2\n\nadvanced:\n  tcp_nodelay: $T_ND\n  tcp_keepalive: $T_KA\n  tcp_read_buffer: $T_RB\n  tcp_write_buffer: $T_WB\n  max_connections: $MAX_C"
    else
        ADV_CFG="smux:\n  keepalive: 10\n  max_recv: 4194304\n  max_stream: 1048576\n  frame_size: 32768\n  version: 2\n\nadvanced:\n  tcp_nodelay: true\n  tcp_keepalive: 15\n  tcp_read_buffer: 4194304\n  tcp_write_buffer: 4194304\n  max_connections: 2000"
    fi

    # 9. Port Mappings
    echo ""
    echo "10. Port Mappings:"
    echo "    Protocol: tcp/udp/both"
    read -p "    Protocol [tcp]: " MAP_PROTO; MAP_PROTO=${MAP_PROTO:-tcp}
    
    echo "    Bind Settings (پورت روی این سرور):"
    read -p "    - Bind IP [0.0.0.0]: " BIND_IP; BIND_IP=${BIND_IP:-0.0.0.0}
    read -p "    - Bind Port [443]: " BIND_PORT; BIND_PORT=${BIND_PORT:-443}
    
    echo "    Target Settings (پورت مقصد):"
    read -p "    - Target IP [127.0.0.1]: " TARGET_IP; TARGET_IP=${TARGET_IP:-127.0.0.1}
    read -p "    - Target Port [443]: " TARGET_PORT; TARGET_PORT=${TARGET_PORT:-443}
    
    echo "    ✓ Mapping: $BIND_IP:$BIND_PORT → $TARGET_IP:$TARGET_PORT"
    
    MAP_CFG="maps:\n  - type: $MAP_PROTO\n    bind: \"$BIND_IP:$BIND_PORT\"\n    target: \"$TARGET_IP:$TARGET_PORT\""

    # 10. Verbose
    echo ""
    read -p "11. Verbose logging (y/N): " VERB
    [[ $VERB =~ ^[Yy]$ ]] && VERB_BOOL="true" || VERB_BOOL="false"

    # Write Config
    echo -e "mode: \"server\"\nlisten: \"0.0.0.0:$LISTEN_PORT\"\ntransport: \"$TRANS\"\npsk: \"$PSK\"\nprofile: \"$PROFILE\"\nverbose: $VERB_BOOL" > $CONFIG_DIR/server.yaml
    echo -e "$CERT_CFG" >> $CONFIG_DIR/server.yaml
    echo -e "$MIMIC_CFG" >> $CONFIG_DIR/server.yaml
    echo -e "$OBFUS_CFG" >> $CONFIG_DIR/server.yaml
    echo -e "$ADV_CFG" >> $CONFIG_DIR/server.yaml
    echo -e "$MAP_CFG" >> $CONFIG_DIR/server.yaml

    # Service
    cat > $SYSTEMD_DIR/DaggerConnect-server.service <<EOF
[Unit]
Description=DaggerConnect Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/DaggerConnect -c $CONFIG_DIR/server.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable DaggerConnect-server
    systemctl restart DaggerConnect-server
    echo -e "${GREEN}✅ Server Installed Successfully!${NC}"
    read -p "Press Enter..."
}

install_client() {
    install_deps
    build_core
    mkdir -p $CONFIG_DIR
    echo -e "${CYAN}:: CLIENT INSTALL ::${NC}"
    
    # Simple Client Setup for compatibility
    read -p "Server Address (IP:Port): " S_ADDR
    read -p "PSK: " PSK
    read -p "Transport (httpmux/httpsmux): " TRANS
    
    cat > $CONFIG_DIR/client.yaml <<EOF
mode: "client"
psk: "$PSK"
profile: "aggressive"
verbose: true
paths:
  - transport: "$TRANS"
    addr: "$S_ADDR"
    connection_pool: 4
    retry_interval: 3
    dial_timeout: 10
obfuscation:
  enabled: true
  min_delay_ms: 5
http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0"
  chunked_encoding: true
  session_cookie: true
smux:
  keepalive: 10
  max_recv: 4194304
  max_stream: 1048576
advanced:
  tcp_nodelay: true
  tcp_keepalive: 15
EOF

    cat > $SYSTEMD_DIR/DaggerConnect-client.service <<EOF
[Unit]
Description=DaggerConnect Client
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$INSTALL_DIR/DaggerConnect -c $CONFIG_DIR/client.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable DaggerConnect-client
    systemctl restart DaggerConnect-client
    echo -e "${GREEN}Client Installed!${NC}"
    read -p "Press Enter..."
}

# --- Main Menu ---
check_root
while true; do
    clear
    echo -e "${CYAN}=== DaggerConnect Installer ===${NC}"
    echo "1) Install Server"
    echo "2) Install Client"
    echo "0) Exit"
    read -p "Select option: " OPT
    case $OPT in
        1) install_server ;;
        2) install_client ;;
        0) exit ;;
    esac
done
#!/usr/bin/env bash
set -euo pipefail

# =========================
# PicoTun Ultimate Installer
# =========================
REPO_DEFAULT="amir6dev/RsTunnel"
BINARY_NAME="picotun"
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

# --- Helper Functions (تعریف شده در بالا برای جلوگیری از ارور) ---
print_header() {
    clear
    echo -e "${CYAN}===============================================${NC}"
    echo -e "${GREEN}      🚀 PicoTun Tunnel Manager (Auto)     ${NC}"
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

print_msg() { echo -e "${BLUE}➤ $1${NC}"; }
print_ok() { echo -e "${GREEN}✔ $1${NC}"; }
print_err() { echo -e "${RED}✖ $1${NC}"; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_err "Run as root!"
        exit 1
    fi
}

# --- 1. Force Install Go ---
install_go() {
    print_msg "Checking Go version..."
    
    force_install() {
        echo -e "${YELLOW}⬇️  Installing Go 1.22 (Force Update)...${NC}"
        rm -rf /usr/local/go
        rm -f /usr/bin/go
        
        wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz -O go.tar.gz
        tar -C /usr/local -xzf go.tar.gz
        rm go.tar.gz
        
        ln -sf /usr/local/go/bin/go /usr/bin/go
        export PATH=$PATH:/usr/local/go/bin
    }

    if ! command -v go &> /dev/null; then
        force_install
    else
        VER=$(go version | awk '{print $3}' | tr -d "go")
        if [[ "$VER" != 1.2* ]]; then
            force_install
        else
            print_ok "Go version is OK: $VER"
        fi
    fi
}

# --- 2. Build Core ---
install_core() {
    install_go
    
    print_msg "Cloning source code..."
    rm -rf /tmp/picobuild
    git clone "https://github.com/${REPO_DEFAULT}.git" /tmp/picobuild
    cd /tmp/picobuild || exit
    
    # ورود به پوشه پروژه اگر در ساب‌فولدر باشد
    if [ -d "PicoTun" ]; then cd PicoTun; fi

    print_msg "Fixing dependencies..."
    # حذف فایل‌های مزاحم قبلی برای بیلد تمیز
    rm -f go.mod go.sum
    
    # ساخت مجدد ماژول برای جلوگیری از ارور مسیر
    go mod init github.com/amir6dev/rstunnel
    go mod tidy
    
    # پیدا کردن مسیر main.go
    TARGET=""
    if [ -f "cmd/picotun/main.go" ]; then TARGET="cmd/picotun/main.go"; fi
    if [ -f "main.go" ]; then TARGET="main.go"; fi
    
    if [ -z "$TARGET" ]; then
        print_err "Could not find main.go!"
        ls -R
        exit 1
    fi

    print_msg "Building Binary..."
    CGO_ENABLED=0 go build -o picotun "$TARGET"
    
    if [ -f "picotun" ]; then
        mv picotun "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        rm -rf /tmp/picobuild
        print_ok "Installed successfully!"
    else
        print_err "Build failed!"
        exit 1
    fi
}

# --- Configuration Wizard ---
configure_wizard() {
    MODE=$1
    mkdir -p "$CONFIG_DIR"
    
    echo ""
    read -p "Tunnel Port [1010]: " PORT; PORT=${PORT:-1010}
    read -p "PSK (Password): " PSK
    if [[ -z "$PSK" ]]; then PSK=$(openssl rand -hex 16); echo "Generated: $PSK"; fi
    
    if [[ "$MODE" == "server" ]]; then
        TCP_MAPS=""
        echo -e "${YELLOW}Port Forwarding (Reverse Tunnel):${NC}"
        while true; do
            read -p "Add Map? (y/N): " yn
            [[ ! "$yn" =~ ^[Yy] ]] && break
            read -p "  Bind Port (e.g. 2080): " bp
            read -p "  Target (e.g. 127.0.0.1:80): " tg
            TCP_MAPS+="    - \"0.0.0.0:${bp}->${tg}\"\n"
        done
        
        cat > "$CONFIG_FILE" <<EOF
mode: server
listen: "0.0.0.0:${PORT}"
session_timeout: 15
psk: "${PSK}"
mimic:
  fake_domain: "www.google.com"
  session_cookie: true
obfs:
  enabled: true
  min_padding: 16
  max_padding: 256
forward:
  tcp:
${TCP_MAPS}
EOF
    else
        read -p "Server IP: " SIP
        cat > "$CONFIG_FILE" <<EOF
mode: client
server_url: "http://${SIP}:${PORT}/tunnel"
session_id: "sess-$(date +%s)"
psk: "${PSK}"
mimic:
  fake_domain: "www.google.com"
  session_cookie: true
obfs:
  enabled: true
  min_padding: 16
  max_padding: 256
forward:
  tcp: []
EOF
    fi
    install_service
}

install_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PicoTun Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$BINARY_NAME -config $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable picotun >/dev/null 2>&1
    systemctl restart picotun
    print_ok "Service Started!"
}

manage_menu() {
    while true; do
        echo -e "\n${YELLOW}:: Service Management ::${NC}"
        echo "1) Start"
        echo "2) Stop"
        echo "3) Restart"
        echo "4) Logs"
        echo "5) Uninstall"
        echo "0) Back"
        read -p "Select: " opt
        case $opt in
            1) systemctl start picotun; print_ok "Started" ;;
            2) systemctl stop picotun; print_ok "Stopped" ;;
            3) systemctl restart picotun; print_ok "Restarted" ;;
            4) journalctl -u picotun -f ;;
            5) uninstall_all; return ;;
            0) return ;;
        esac
    done
}

uninstall_all() {
    print_msg "Uninstalling..."
    systemctl stop picotun >/dev/null 2>&1 || true
    systemctl disable picotun >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "Uninstalled."
}

# --- Main Menu ---
main_menu() {
    need_root
    while true; do
        print_header
        echo "1) Install / Update Core (Auto-Fix)"
        echo "2) Configure Server"
        echo "3) Configure Client"
        echo "4) Manage Service"
        echo "5) Uninstall"
        echo "0) Exit"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) install_core; read -p "Press Enter..." ;;
            2) configure_wizard "server" ;;
            3) configure_wizard "client" ;;
            4) manage_menu ;;
            5) uninstall_all ;;
            0) exit ;;
        esac
    done
}

main_menu
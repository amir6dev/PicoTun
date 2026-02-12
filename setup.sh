#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  RsTunnel / PicoTun Manager (Dagger Style Automation)
# ============================================================================

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'

# Paths
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
APP="picotun"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP}"
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"
BUILD_DIR="/tmp/picobuild"
HOME_DIR="$HOME"

# Helper Functions
say() { echo -e "${CYAN}➤${NC} $*"; }
ok()  { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die() { echo -e "${RED}✖${NC} $*"; exit 1; }

check_root() { [[ ${EUID} -eq 0 ]] || die "This script must be run as root."; }

banner() {
    clear
    echo -e "${CYAN}"
    echo -e "${GREEN}*** RsTunnel / PicoTun  ***${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${PURPLE}   Automation like Dagger    ${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${GREEN}*** Private Tunneling   ***${NC}"
    echo ""
}

# ============================================================================
#  CORE INSTALLATION (Iran Optimized)
# ============================================================================

ensure_deps() {
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt-get update -qq
        apt-get install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    fi
    ok "Dependencies installed"
}

install_go() {
    # تنظیمات پروکسی برای ایران
    export GOPROXY=https://goproxy.cn,direct
    export GOTOOLCHAIN=local
    export GOSUMDB=off

    if command -v go >/dev/null 2>&1; then
        if go version | grep -E "go1\.(2[2-9]|[3-9][0-9])"; then return; fi
    fi
    
    local GO_VER="1.22.1"
    echo -e "${YELLOW}⬇️  Installing Go ${GO_VER} (Mirror)...${NC}"
    local url="https://mirrors.aliyun.com/golang/go${GO_VER}.linux-amd64.tar.gz"
    
    rm -rf /usr/local/go
    curl -fsSL -L "$url" -o /tmp/go.tgz || die "Go download failed."
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    export PATH="/usr/local/go/bin:${PATH}"
    ok "Go environment ready."
}

update_core() {
    ensure_deps
    install_go
    
    export PATH="/usr/local/go/bin:${PATH}"
    export GOPROXY=https://goproxy.cn,direct
    export GOTOOLCHAIN=local
    export GOSUMDB=off

    echo -e "${YELLOW}⬇️  Cloning source code...${NC}"
    cd "$HOME_DIR"
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null
    
    cd "$BUILD_DIR"
    echo -e "${YELLOW}🔧 Fixing build environment...${NC}"
    
    # اصلاح ساختار ماژول و ایمپورت‌ها
    rm -f go.mod go.sum
    go mod init github.com/amir6dev/rstunnel
    
    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel/PicoTun|github.com/amir6dev/rstunnel|g' {} +
    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel|github.com/amir6dev/rstunnel|g' {} +

    # پین کردن نسخه کتابخانه‌ها
    go get golang.org/x/net@v0.23.0
    go get github.com/refraction-networking/utls@v1.6.0
    go get github.com/xtaci/smux@v1.5.24
    go get gopkg.in/yaml.v3@v3.0.1
    go mod tidy

    echo -e "${YELLOW}🔨 Building binary...${NC}"
    local TARGET=""
    if [[ -f "cmd/picotun/main.go" ]]; then TARGET="cmd/picotun/main.go"; fi
    if [[ -f "main.go" ]]; then TARGET="main.go"; fi
    
    [[ -z "$TARGET" ]] && die "Main file not found."
    
    CGO_ENABLED=0 go build -o picotun "$TARGET" || die "Build failed."
    
    install -m 0755 picotun "${BIN_PATH}"
    ok "Core updated successfully: ${BIN_PATH}"
    
    cd "$HOME_DIR"
    rm -rf "$BUILD_DIR"
}

# ============================================================================
#  SYSTEM OPTIMIZER (Ported from Dagger)
# ============================================================================

optimize_system() {
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SYSTEM OPTIMIZATION (BBR/TCP)    ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Applying kernel tweaks...${NC}"

    # Anti-jitter & Low-latency TCP settings
    cat > /etc/sysctl.d/99-picotun.conf << 'EOF'
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF
    sysctl -p /etc/sysctl.d/99-picotun.conf >/dev/null 2>&1
    ok "TCP Tweaks applied"
    ok "BBR enabled"
    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
#  CONFIGURATION WIZARD
# ============================================================================

configure_server() {
    mkdir -p "$CONFIG_DIR"
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SERVER CONFIGURATION             ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # 1. Tunnel Port
    read -p "Tunnel Listen Port [1010]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-1010}

    # 2. PSK
    echo ""
    read -p "Enter PSK (Leave empty to generate): " USER_PSK
    if [ -z "$USER_PSK" ]; then
        PSK=$(openssl rand -hex 16)
        echo -e "${GREEN}Generated PSK: ${PSK}${NC}"
    else
        PSK="$USER_PSK"
    fi

    # 3. Mimicry
    echo ""
    echo -e "${YELLOW}HTTP Mimicry Settings:${NC}"
    read -p "Fake Domain (e.g. www.google.com): " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    # 4. Obfuscation
    echo ""
    echo -e "${YELLOW}Obfuscation Settings:${NC}"
    read -p "Enable Obfuscation? [Y/n]: " ENABLE_OBFS
    if [[ "$ENABLE_OBFS" =~ ^[Nn] ]]; then OBFS_BOOL="false"; else OBFS_BOOL="true"; fi

    # 5. Port Mapping (The Dagger way)
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS                    ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo "Examples: 8080->127.0.0.1:80 | 443->127.0.0.1:443"
    
    MAPPINGS_YAML=""
    while true; do
        echo ""
        read -p "Add Port Mapping? [y/N]: " yn
        [[ ! "$yn" =~ ^[Yy] ]] && break
        
        read -p "  Bind Port (e.g. 2080): " BP
        read -p "  Target IP:Port (e.g. 127.0.0.1:80): " TP
        
        # Validation logic can go here
        MAPPINGS_YAML+="    - \"0.0.0.0:${BP}->${TP}\"\n"
        ok "Added: 0.0.0.0:${BP} -> ${TP}"
    done

    # Generate Config
    cat > "$CONFIG_DIR/server.yaml" <<EOF
mode: "server"
listen: "0.0.0.0:${LISTEN_PORT}"
session_timeout: 30
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  session_cookie: true

obfs:
  enabled: ${OBFS_BOOL}
  min_padding: 16
  max_padding: 256

forward:
  tcp:
${MAPPINGS_YAML}
  udp: []
EOF

    create_service "server"
    
    echo ""
    echo -e "${GREEN}Configuration Complete!${NC}"
    echo -e "PSK: ${YELLOW}${PSK}${NC} (Copy this for client)"
    read -p "Press Enter to start service..."
    
    systemctl restart picotun-server
    show_logs "server"
}

configure_client() {
    mkdir -p "$CONFIG_DIR"
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CLIENT CONFIGURATION             ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -p "Server IP: " SIP
    read -p "Server Port [1010]: " SPORT
    SPORT=${SPORT:-1010}
    
    echo ""
    read -p "Enter PSK (From Server): " PSK
    
    echo ""
    read -p "Fake Domain (Must match server): " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    cat > "$CONFIG_DIR/client.yaml" <<EOF
mode: "client"
server_url: "http://${SIP}:${SPORT}/tunnel"
session_id: "client-$(openssl rand -hex 4)"
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 16
  max_padding: 256

forward:
  tcp: []
EOF

    create_service "client"
    systemctl restart picotun-client
    ok "Client started."
    read -p "Press Enter to continue..."
}

create_service() {
    local TYPE=$1
    local SERVICE_NAME="picotun-${TYPE}"
    
    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RsTunnel ${TYPE^}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -config ${CONFIG_DIR}/${TYPE}.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    ok "Service ${SERVICE_NAME} created."
}

# ============================================================================
#  MENUS
# ============================================================================

show_logs() {
    local TYPE=$1
    if [[ -z "$TYPE" ]]; then
        echo ""
        echo "1) Server Logs"
        echo "2) Client Logs"
        read -p "Select: " opt
        [[ "$opt" == "1" ]] && TYPE="server" || TYPE="client"
    fi
    journalctl -u "picotun-${TYPE}" -f
}

manage_service() {
    while true; do
        banner
        echo -e "${YELLOW}Service Management${NC}"
        echo "1) Restart Server"
        echo "2) Stop Server"
        echo "3) Restart Client"
        echo "4) Stop Client"
        echo "5) View Configs"
        echo "0) Back"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) systemctl restart picotun-server; ok "Server Restarted"; sleep 1 ;;
            2) systemctl stop picotun-server; ok "Server Stopped"; sleep 1 ;;
            3) systemctl restart picotun-client; ok "Client Restarted"; sleep 1 ;;
            4) systemctl stop picotun-client; ok "Client Stopped"; sleep 1 ;;
            5) ls -l $CONFIG_DIR; read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

uninstall_all() {
    echo ""
    echo -e "${RED}⚠️  WARNING: This will remove everything!${NC}"
    read -p "Are you sure? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        systemctl stop picotun-server picotun-client 2>/dev/null || true
        systemctl disable picotun-server picotun-client 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/picotun-server.service" "$SYSTEMD_DIR/picotun-client.service"
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR" "$BIN_PATH" "$BUILD_DIR"
        ok "Uninstalled completely."
        exit 0
    fi
}

main_menu() {
    while true; do
        banner
        echo "1) Install Server"
        echo "2) Install Client"
        echo "3) Settings (Manage Services)"
        echo "4) System Optimizer"
        echo "5) Update Core / Re-install"
        echo "6) Show Logs"
        echo "7) Uninstall"
        echo "0) Exit"
        echo ""
        read -p "Select option: " opt
        case $opt in
            1) 
                if [[ ! -f "$BIN_PATH" ]]; then update_core; fi
                configure_server 
                ;;
            2) 
                if [[ ! -f "$BIN_PATH" ]]; then update_core; fi
                configure_client 
                ;;
            3) manage_service ;;
            4) optimize_system ;;
            5) update_core; read -p "Press Enter..." ;;
            6) show_logs "" ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) warn "Invalid option"; sleep 1 ;;
        esac
    done
}

check_root
main_menu
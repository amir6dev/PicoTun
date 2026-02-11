#!/bin/bash

# ====================================================
#      RsTunnel v6.0 - Ultimate Enterprise Manager
#      Graphic Interface | Multi-Tunnel | Full Control
# ====================================================

# --- Colors & Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Configurations ---
BIN_DIR="/usr/local/bin"
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
SERVICE_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/rstunnel"

# --- System Checks & Helpers ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${BOLD}❌ Critical Error: Please run this script as root!${NC}"
        exit 1
    fi
}

header() {
    clear
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${PURPLE}      🚀 RsTunnel Ultimate Manager v6.0 (Enterprise)${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${YELLOW}    » Multi-Port Tunneling  » Advanced Traffic Obfuscation${NC}"
    echo -e "${YELLOW}    » HTTP/HTTPS Mimicry    » Real-time Monitoring${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

install_deps() {
    if ! command -v go &> /dev/null; then
        echo -e "${BLUE}📦 Installing System Dependencies (Go, Git, OpenSSL)...${NC}"
        apt update -qq >/dev/null 2>&1
        apt install -y git golang openssl curl >/dev/null 2>&1
    fi
}

update_core() {
    # Only build if missing or forced
    if [[ ! -f "$BIN_DIR/rstunnel-bridge" ]]; then
        echo -e "${BLUE}⬇️  Downloading & Compiling Core Engine...${NC}"
        rm -rf /tmp/rsbuild
        git clone $REPO_URL /tmp/rsbuild
        if [ ! -d "/tmp/rsbuild" ]; then
            echo -e "${RED}❌ Error: Failed to clone repository.${NC}"
            return
        fi
        cd /tmp/rsbuild || exit
        
        echo -e "${PURPLE}⚙️  Building Binaries...${NC}"
        go mod tidy >/dev/null 2>&1
        go build -o rstunnel-bridge bridge.go
        go build -o rstunnel-upstream upstream.go
        
        mv rstunnel-* $BIN_DIR/
        chmod +x $BIN_DIR/rstunnel-*
        echo -e "${GREEN}✅ Core Engine Installed Successfully.${NC}"
        sleep 1
    fi
}

generate_ssl() {
    mkdir -p $CONFIG_DIR/certs
    if [[ ! -f "$CONFIG_DIR/certs/cert.pem" ]]; then
        echo -e "${YELLOW}🔐 Generating Self-Signed SSL Certificates...${NC}"
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout $CONFIG_DIR/certs/key.pem \
            -out $CONFIG_DIR/certs/cert.pem \
            -days 365 -subj "/CN=www.google.com" >/dev/null 2>&1
    fi
}

# --- Tunnel Installation Functions ---

install_server() {
    install_deps
    update_core
    header
    echo -e "${GREEN}:: CREATE NEW BRIDGE (SERVER) TUNNEL ::${NC}"
    echo ""
    
    # 1. Port Selection
    echo -e "${BOLD}1. Tunnel Configuration:${NC}"
    read -p "   - Tunnel Port (Must be unique) [443]: " T_PORT
    T_PORT=${T_PORT:-443}

    SERVICE_NAME="rstunnel-bridge-$T_PORT"
    if [[ -f "$SERVICE_DIR/$SERVICE_NAME.service" ]]; then
        echo -e "${RED}⚠️  Error: A tunnel on port $T_PORT already exists!${NC}"
        read -p "   Press Enter to return..."
        return
    fi

    # 2. Transport
    echo ""
    echo -e "${BOLD}2. Transport Protocol:${NC}"
    echo "   1) httpmux   (HTTP Mimicry)"
    echo "   2) httpsmux  (HTTPS Mimicry + TLS) ⭐"
    read -p "   Select [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    # 3. Profile
    echo ""
    echo -e "${BOLD}3. Performance Profile:${NC}"
    echo "   1) balanced"
    echo "   2) aggressive (High Speed)"
    echo "   3) gaming     (Low Latency)"
    read -p "   Select [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    # 4. SSL & Configs
    CERT_FLAGS=""
    if [[ "$MODE" == "httpsmux" ]]; then
        generate_ssl
        CERT_FLAGS="-cert $CONFIG_DIR/certs/cert.pem -key $CONFIG_DIR/certs/key.pem"
    fi

    echo ""
    echo -e "${BOLD}4. Mimicry Settings:${NC}"
    read -p "   - Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "   - Fake Path [/search]: " F_PATH
    F_PATH=${F_PATH:-/search}
    
    read -p "   - User Bind Port (Local V2Ray) [1432]: " U_PORT
    U_PORT=${U_PORT:-1432}

    # Service Creation
    echo ""
    echo -e "${PURPLE}⚙️  Generating Systemd Service ($SERVICE_NAME)...${NC}"

cat <<EOF > $SERVICE_DIR/$SERVICE_NAME.service
[Unit]
Description=RsTunnel Bridge Port $T_PORT
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
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    
    echo ""
    echo -e "${GREEN}✅ Tunnel Successfully Created on Port $T_PORT!${NC}"
    read -p "   Press Enter to continue..."
}

install_client() {
    install_deps
    update_core
    header
    echo -e "${GREEN}:: CREATE NEW UPSTREAM (CLIENT) TUNNEL ::${NC}"
    echo ""
    
    read -p "   - Server IP Address: " S_IP
    read -p "   - Server Port [443]: " S_PORT
    S_PORT=${S_PORT:-443}

    SERVICE_NAME="rstunnel-upstream-$S_PORT"
    if [[ -f "$SERVICE_DIR/$SERVICE_NAME.service" ]]; then
        echo -e "${RED}⚠️  Error: A client for port $S_PORT already exists!${NC}"
        read -p "   Press Enter to return..."
        return
    fi

    echo ""
    echo "   1) httpmux"
    echo "   2) httpsmux"
    read -p "   Select Transport [1-2]: " T_OPT
    if [[ "$T_OPT" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    echo ""
    echo "   1) balanced"
    echo "   2) aggressive"
    echo "   3) gaming"
    read -p "   Select Profile [1-3]: " P_OPT
    case $P_OPT in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    echo ""
    read -p "   - Fake Host [www.google.com]: " F_HOST
    F_HOST=${F_HOST:-www.google.com}
    read -p "   - Local Listen Address [127.0.0.1:1432]: " LOC
    LOC=${LOC:-127.0.0.1:1432}

    echo -e "${PURPLE}⚙️  Generating Systemd Service...${NC}"

cat <<EOF > $SERVICE_DIR/$SERVICE_NAME.service
[Unit]
Description=RsTunnel Client to $S_PORT
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-upstream -c $S_IP:$S_PORT -p $LOC -m $MODE -profile $PROF -host $F_HOST
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    
    echo -e "${GREEN}✅ Client Connection Established!${NC}"
    read -p "   Press Enter to continue..."
}

# --- Management Functions ---

list_tunnels() {
    echo -e "${CYAN}--- Active Tunnels List ---${NC}"
    services=$(systemctl list-units --all --plain --no-legend | grep -o 'rstunnel-[^ ]*')
    
    if [[ -z "$services" ]]; then
        echo -e "${YELLOW}   No active tunnels found.${NC}"
        return 1
    fi

    i=1
    declare -a SERVICE_ARRAY
    for svc in $services; do
        if systemctl is-active --quiet $svc; then
            status="${GREEN}● Active${NC}"
        else
            status="${RED}● Inactive${NC}"
        fi
        
        # Clean up name for display
        clean_name=${svc//rstunnel-/}
        clean_name=${clean_name//.service/}
        
        echo -e "   $i) ${BOLD}$clean_name${NC} \t [$status] \t ($svc)"
        SERVICE_ARRAY[$i]=$svc
        ((i++))
    done
    return 0
}

manage_tunnels() {
    while true; do
        header
        echo -e "${GREEN}:: TUNNEL MANAGEMENT ::${NC}"
        echo ""
        list_tunnels
        if [[ $? -eq 1 ]]; then read -p "   Press Enter to return..."; return; fi
        
        echo ""
        echo -e "${YELLOW}Enter the number of the tunnel to manage (or 0 to back):${NC}"
        read -p "   > " NUM
        
        if [[ "$NUM" == "0" ]]; then return; fi
        
        SELECTED_SVC=${SERVICE_ARRAY[$NUM]}
        if [[ -z "$SELECTED_SVC" ]]; then 
            echo -e "${RED}Invalid selection!${NC}"
            sleep 1
            continue
        fi
        
        while true; do
            header
            echo -e "   Managing Tunnel: ${CYAN}$SELECTED_SVC${NC}"
            echo ""
            echo "   1) ${GREEN}Start Tunnel${NC}"
            echo "   2) ${RED}Stop Tunnel${NC}"
            echo "   3) ${YELLOW}Restart Tunnel${NC}"
            echo "   4) ${BLUE}View Live Logs${NC}"
            echo "   5) ${RED}${BOLD}DELETE TUNNEL (Permanent)${NC}"
            echo "   0) Back to list"
            echo ""
            read -p "   Select Action: " ACTION
            
            case $ACTION in
                1) systemctl start $SELECTED_SVC; echo -e "${GREEN}Started.${NC}"; sleep 1;;
                2) systemctl stop $SELECTED_SVC; echo -e "${RED}Stopped.${NC}"; sleep 1;;
                3) systemctl restart $SELECTED_SVC; echo -e "${YELLOW}Restarted.${NC}"; sleep 1;;
                4) journalctl -u $SELECTED_SVC -f;;
                5) 
                    echo -e "${RED}${BOLD}⚠️  WARNING: This will delete '$SELECTED_SVC' permanently.${NC}"
                    read -p "   Are you sure? (y/N): " DEL_CONF
                    if [[ "$DEL_CONF" == "y" ]]; then
                        systemctl stop $SELECTED_SVC
                        systemctl disable $SELECTED_SVC
                        rm -f $SERVICE_DIR/$SELECTED_SVC.service
                        systemctl daemon-reload
                        echo -e "${GREEN}✅ Tunnel Deleted Successfully.${NC}"
                        sleep 1
                        break # Break inner loop to refresh list
                    fi
                    ;;
                0) break;; # Break inner loop
            esac
        done
    done
}

uninstall_all() {
    header
    echo -e "${RED}${BOLD}:: DANGER ZONE: FULL UNINSTALL ::${NC}"
    echo ""
    echo "   This action will:"
    echo "   1. Stop and Delete ALL RsTunnel Services"
    echo "   2. Remove ALL Binaries and Configurations"
    echo "   3. Clean Systemd entries"
    echo ""
    read -p "   Are you sure you want to proceed? (yes/no): " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        return
    fi

    echo ""
    echo -e "${YELLOW}Stopping all services...${NC}"
    services=$(systemctl list-units --all --plain --no-legend | grep -o 'rstunnel-[^ ]*')
    for svc in $services; do
        echo "   - Removing $svc..."
        systemctl stop $svc 2>/dev/null
        systemctl disable $svc 2>/dev/null
        rm -f $SERVICE_DIR/$svc.service
    done

    echo -e "${YELLOW}Cleaning files...${NC}"
    rm -f $BIN_DIR/rstunnel-*
    rm -rf $CONFIG_DIR
    
    systemctl daemon-reload
    echo ""
    echo -e "${GREEN}✅ Uninstallation Complete. RsTunnel has been removed.${NC}"
    read -p "   Press Enter to exit..."
    exit 0
}

# --- Main Menu Loop ---

check_root
while true; do
    header
    echo -e "   ${BOLD}1)${NC} Create New Bridge (Server)"
    echo -e "   ${BOLD}2)${NC} Create New Upstream (Client)"
    echo -e "   ${BOLD}3)${NC} Manage / Delete Tunnels"
    echo -e "   ${BOLD}4)${NC} Force Update Core"
    echo -e "   ${BOLD}5)${NC} ${RED}Uninstall Script & Tunnels${NC}"
    echo -e "   ${BOLD}0)${NC} Exit"
    echo ""
    read -p "   Select Option: " OPT
    
    case $OPT in
        1) install_server ;;
        2) install_client ;;
        3) manage_tunnels ;;
        4) 
           rm -f $BIN_DIR/rstunnel-* update_core
           read -p "   Update Complete. Press Enter..." 
           ;;
        5) uninstall_all ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid Option"; sleep 1 ;;
    esac
done
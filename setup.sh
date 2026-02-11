#!/bin/bash

# ======================================================
#   PicoTun — Full Auto Installer (Dagger-Style)
#   Author: amir6dev
#   Binary: picotun
#   Service: picotun
# ======================================================

REPO="amir6dev/PicoTun"
BINARY="picotun"
SERVICE="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SYSTEMD_FILE="/etc/systemd/system/$SERVICE.service"
GREEN="\e[92m"; RED="\e[91m"; CYAN="\e[96m"; YELLOW="\e[93m"; NC="\e[0m"

clear

logo() {
cat <<EOF
${CYAN}
██████╗ ██╗ ██████╗ ██████╗  ██████╗ ████████╗██╗   ██╗███╗   ██╗
██╔══██╗██║██╔════╝ ██╔══██╗██╔═══██╗╚══██╔══╝██║   ██║████╗  ██║
██████╔╝██║██║  ███╗██████╔╝██║   ██║   ██║   ██║   ██║██╔██╗ ██║
██╔═══╝ ██║██║   ██║██╔══██╗██║   ██║   ██║   ██║   ██║██║╚██╗██║
██║     ██║╚██████╔╝██║  ██║╚██████╔╝   ██║   ╚██████╔╝██║ ╚████║
╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝  ╚═══╝
${NC}
             ${YELLOW}PicoTun HTTPMUX Tunnel — Installer${NC}
EOF
}

pause() {
  read -p "Press enter to continue..."
}

install_dependencies() {
  echo -e "${GREEN}Installing dependencies...${NC}"
  apt update -y
  apt install -y wget curl tar jq unzip
}

fetch_latest_release() {
  echo -e "${GREEN}Fetching latest release...${NC}"
  URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest \
    | jq -r '.assets[] | select(.name | contains("linux_amd64")) | .browser_download_url')

  if [[ -z "$URL" ]]; then
    echo -e "${RED}Error: No release found.${NC}"
    exit 1
  fi

  echo -e "${CYAN}Downloading binary...${NC}"
  wget -O /tmp/$BINARY.tar.gz "$URL"
  tar -xzf /tmp/$BINARY.tar.gz -C /tmp
  chmod +x /tmp/$BINARY
  mv /tmp/$BINARY $INSTALL_DIR/$BINARY
}

generate_config_server() {
  mkdir -p $CONFIG_DIR

cat > $CONFIG_FILE <<EOF
mode: server
listen: 0.0.0.0:8080
session_timeout: 15

mimic:
  fake_domain: www.google.com
  fake_path: /search
  user_agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay: 0
  max_delay: 0

forward:
  tcp:
    - "1412->127.0.0.1:1412"
  udp: []
EOF

  echo -e "${GREEN}Server config generated: $CONFIG_FILE${NC}"
}

generate_config_client() {
  mkdir -p $CONFIG_DIR

cat > $CONFIG_FILE <<EOF
mode: client
server_url: http://SERVER_IP:8080/tunnel
session_id: mysession

mimic:
  fake_domain: www.google.com
  fake_path: /search
  user_agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 32

EOF

  echo -e "${GREEN}Client config generated: $CONFIG_FILE${NC}"
}

install_service() {
cat > $SYSTEMD_FILE <<EOF
[Unit]
Description=PicoTun HTTPMUX Tunnel
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$BINARY -config $CONFIG_FILE
Restart=always
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable $SERVICE
  systemctl restart $SERVICE

  echo -e "${GREEN}Service installed & running.${NC}"
}

uninstall_service() {
  systemctl stop $SERVICE
  systemctl disable $SERVICE
  rm -f $SYSTEMD_FILE
  systemctl daemon-reload
  echo -e "${YELLOW}Service removed.${NC}"
}

show_logs() {
  journalctl -u $SERVICE -f --no-pager
}

menu() {
  clear
  logo
echo -e "${CYAN}
1) Install Server
2) Install Client
3) View Logs
4) Restart Service
5) Remove Service
6) Update PicoTun
0) Exit
${NC}"
read -p "Select option: " opt

case $opt in
  1)
    install_dependencies
    fetch_latest_release
    generate_config_server
    install_service
    ;;
  2)
    install_dependencies
    fetch_latest_release
    generate_config_client
    install_service
    ;;
  3)
    show_logs
    ;;
  4)
    systemctl restart $SERVICE
    echo -e "${GREEN}Service restarted.${NC}"
    ;;
  5)
    uninstall_service
    ;;
  6)
    uninstall_service
    fetch_latest_release
    install_service
    ;;
  0)
    exit
    ;;
  *)
    echo "Invalid option"
    ;;
esac

pause
menu
}

menu

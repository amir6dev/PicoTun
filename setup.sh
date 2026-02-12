#!/usr/bin/env bash
set -euo pipefail

# ========= UI =========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say() { echo -e "${CYAN}➤${NC} $*"; }
ok()  { echo -e "${GREEN}✓${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
die() { echo -e "${RED}✖${NC} $*"; exit 1; }

# ========= Project =========
OWNER="amir6dev"
REPO="RsTunnel"
APP="picotun"

INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP}"

CONFIG_DIR="/etc/picotun"
SERVER_CFG="${CONFIG_DIR}/server.yaml"
CLIENT_CFG="${CONFIG_DIR}/client.yaml"

SYSTEMD_DIR="/etc/systemd/system"
SERVER_SVC="picotun-server"
CLIENT_SVC="picotun-client"
BUILD_DIR="/tmp/picobuild"

# ========= Helpers =========
need_root(){ [[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."; }

ensure_deps(){
  say "Checking environment..."
  if command -v apt >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates tar git >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates tar git >/dev/null
  else
    die "No supported package manager. Install curl+tar+git manually."
  fi
  ok "Dependencies installed"
}

banner(){
  echo -e "${GREEN}*** RsTunnel / PicoTun Ultimate ***${NC}"
  echo -e "Repo: https://github.com/${OWNER}/${REPO}"
  echo -e "================================="
  echo ""
}

# ========= Go Installation (Iran Optimized) =========
install_go(){
  export GOPROXY=https://goproxy.cn,direct
  export GOTOOLCHAIN=local
  export GOSUMDB=off

  if command -v go >/dev/null 2>&1; then
    if go version | grep -E "go1\.(2[2-9]|[3-9][0-9])"; then
       return
    fi
  fi
  
  local GO_VER="1.22.1"
  say "Installing Go ${GO_VER} (Mirror)..."
  local url="https://mirrors.aliyun.com/golang/go${GO_VER}.linux-amd64.tar.gz"
  
  rm -rf /usr/local/go
  if ! curl -fsSL -L "$url" -o /tmp/go.tgz; then
     die "Download failed. Check internet."
  fi
  
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  export PATH="/usr/local/go/bin:${PATH}"
  ok "Go installed."
}

# ========= Build Core (Fix Imports) =========
update_core() {
  ensure_deps
  install_go
  
  export PATH="/usr/local/go/bin:${PATH}"
  export GOPROXY=https://goproxy.cn,direct
  export GOTOOLCHAIN=local
  export GOSUMDB=off

  say "Cloning source code..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "https://github.com/${OWNER}/${REPO}.git" "$BUILD_DIR" >/dev/null
  cd "$BUILD_DIR"

  say "Fixing module & imports..."
  # 1. حذف فایل‌های ماژول قدیمی
  rm -f go.mod go.sum

  # 2. ایجاد ماژول جدید با حروف کوچک (استاندارد)
  go mod init github.com/amir6dev/rstunnel

  # 3. اصلاح مسیرهای ایمپورت در فایل‌های برنامه
  # مشکل ارور شما این بود که کدها دنبال پوشه PicoTun می‌گشتند ولی فایل‌ها در روت بودند.
  # این دستورات، آدرس‌های اشتباه را به آدرس ریشه تغییر می‌دهند.
  
  # تغییر github.com/amir6dev/RsTunnel/PicoTun -> github.com/amir6dev/rstunnel
  find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel/PicoTun|github.com/amir6dev/rstunnel|g' {} +
  
  # تغییر github.com/amir6dev/RsTunnel -> github.com/amir6dev/rstunnel (برای اطمینان)
  find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel|github.com/amir6dev/rstunnel|g' {} +
  
  say "Pinning dependencies..."
  # دانلود نسخه‌های سازگار با Go 1.22
  go get golang.org/x/net@v0.23.0
  go get github.com/refraction-networking/utls@v1.6.0
  go get github.com/xtaci/smux@v1.5.24
  go get gopkg.in/yaml.v3@v3.0.1
  
  go mod tidy
  
  say "Building binary..."
  # بیلد کردن از پوشه cmd/picotun
  CGO_ENABLED=0 go build -o picotun ./cmd/picotun
  
  if [[ ! -f "picotun" ]]; then
      die "Build failed! Check logs above."
  fi
  
  install -m 0755 picotun "${BIN_PATH}"
  ok "Installed binary: ${BIN_PATH}"
}

# ========= Config & Service =========
ensure_config_dir(){ mkdir -p "${CONFIG_DIR}"; }

write_default_server_config_if_missing(){
  ensure_config_dir
  [[ -f "${SERVER_CFG}" ]] && return
  cat > "${SERVER_CFG}" <<EOF
mode: "server"
listen: "0.0.0.0:1010"
psk: "$(openssl rand -hex 16)"

mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 10

forward:
  tcp: []
  udp: []
EOF
  ok "Created default server config."
}

write_default_client_config_if_missing(){
  ensure_config_dir
  [[ -f "${CLIENT_CFG}" ]] && return
  cat > "${CLIENT_CFG}" <<'YAML'
mode: "client"
server_url: "http://SERVER_IP:1010/tunnel"
session_id: "default"
psk: "PASTE_SERVER_PSK_HERE"

mimic:
  fake_domain: "www.google.com"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
YAML
  ok "Created default client config."
}

create_service() {
  local mode="$1" svc cfg
  if [[ "$mode" == "server" ]]; then svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"; else svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"; fi

  cat > "${SYSTEMD_DIR}/${svc}.service" <<EOF
[Unit]
Description=RsTunnel PicoTun (${mode})
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH} -config ${cfg}
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Service created: ${svc}"
}

enable_start_service(){
  local svc="$1"
  systemctl enable --now "$svc" >/dev/null 2>&1 || true
  ok "Started: $svc"
}

# ========= Menus =========
install_server(){
  banner
  update_core
  write_default_server_config_if_missing
  create_service "server"
  enable_start_service "${SERVER_SVC}"
  echo ""; echo "👉 Config: ${SERVER_CFG}"; echo "👉 PSK is inside config."; echo ""
  read -r -p "Press Enter..." _
}

install_client(){
  banner
  update_core
  write_default_client_config_if_missing
  create_service "client"
  enable_start_service "${CLIENT_SVC}"
  echo ""; echo "👉 Config: ${CLIENT_CFG}"; echo "⚠️  Edit config to set Server IP & PSK!"; echo ""
  read -r -p "Press Enter..." _
}

manage_service(){
  local mode="$1" svc cfg title
  if [[ "$mode" == "server" ]]; then svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"; else svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"; fi
  
  while true; do
    banner
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Logs"
    echo "  5) Config"
    echo "  6) Uninstall Service"
    echo "  0) Back"
    read -r -p "Select: " c
    case "${c:-}" in
      1) systemctl start "$svc"; ok "Started"; sleep 1 ;;
      2) systemctl stop "$svc"; ok "Stopped"; sleep 1 ;;
      3) systemctl restart "$svc"; ok "Restarted"; sleep 1 ;;
      4) journalctl -u "$svc" -f ;;
      5) nano "$cfg" ;;
      6) systemctl disable --now "$svc"; rm "${SYSTEMD_DIR}/${svc}.service"; ok "Deleted"; sleep 1 ;;
      0) break ;;
    esac
  done
}

settings_menu(){
  while true; do
    banner
    echo "  1) Manage Server"
    echo "  2) Manage Client"
    echo "  0) Back"
    read -r -p "Select: " c
    case "${c:-}" in
      1) manage_service "server" ;;
      2) manage_service "client" ;;
      0) break ;;
    esac
  done
}

show_logs_picker(){
  banner
  echo "  1) Server logs"
  echo "  2) Client logs"
  read -r -p "Select: " l
  if [[ "$l" == "1" ]]; then journalctl -u "${SERVER_SVC}" -f; fi
  if [[ "$l" == "2" ]]; then journalctl -u "${CLIENT_SVC}" -f; fi
}

uninstall_all(){
  banner
  read -r -p "Uninstall everything? [y/N]: " y
  [[ "$y" =~ ^[Yy]$ ]] || return
  systemctl stop "${SERVER_SVC}" "${CLIENT_SVC}" 2>/dev/null || true
  systemctl disable "${SERVER_SVC}" "${CLIENT_SVC}" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/${SERVER_SVC}.service" "${SYSTEMD_DIR}/${CLIENT_SVC}.service"
  systemctl daemon-reload
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}" "$BUILD_DIR"
  ok "Uninstalled."
  exit 0
}

main_menu(){
  while true; do
    banner
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings"
    echo "  4) Show Logs"
    echo "  5) Update Core"
    echo "  6) Uninstall"
    echo "  0) Exit"
    read -r -p "Select: " c
    case "${c:-}" in
      1) install_server ;;
      2) install_client ;;
      3) settings_menu ;;
      4) show_logs_picker ;;
      5) update_core; ok "Done"; sleep 1 ;;
      6) uninstall_all ;;
      0) exit 0 ;;
    esac
  done
}

need_root
main_menu
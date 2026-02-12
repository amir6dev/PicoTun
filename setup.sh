#!/usr/bin/env bash
set -euo pipefail

# ========= UI =========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ echo -e "${CYAN}➤${NC} $*"; }
ok(){  echo -e "${GREEN}✓${NC} $*"; }
warn(){echo -e "${YELLOW}⚠${NC} $*"; }
die(){ echo -e "${RED}✖${NC} $*"; exit 1; }

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

# ========= Helpers =========
need_root(){ [[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."; }

arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

ensure_deps(){
  say "Checking environment..."
  if command -v apt >/dev/null 2>&1; then
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates tar >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates tar >/dev/null
  else
    die "No supported package manager (apt/yum). Install curl+tar manually."
  fi
  ok "Dependencies installed"
}

banner(){
  echo -e "${GREEN}***  RsTunnel / PicoTun  ***${NC}"
  echo -e "Repo: https://github.com/${OWNER}/${REPO}"
  echo -e "================================="
  echo ""
}

# ========= Release Download =========
github_api_latest() {
  echo "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
}

get_latest_tag() {
  # Extract "tag_name" from GitHub API JSON without jq
  curl -fsSL "$(github_api_latest)" | awk -F'"' '/"tag_name":/ {print $4; exit}'
}

download_asset() {
  local tag="$1"
  local a; a="$(arch)"
  local asset="picotun_linux_${a}.tar.gz"

  # Prefer direct GitHub release asset URL:
  local url="https://github.com/${OWNER}/${REPO}/releases/download/${tag}/${asset}"

  say "Downloading ${asset} (${tag})..."
  rm -rf /tmp/picotun_dl
  mkdir -p /tmp/picotun_dl
  if ! curl -fL "$url" -o "/tmp/picotun_dl/${asset}"; then
    die "Failed to download asset. Ensure a release exists with ${asset} attached."
  fi

  say "Extracting..."
  tar -xzf "/tmp/picotun_dl/${asset}" -C /tmp/picotun_dl
  [[ -f "/tmp/picotun_dl/${APP}" ]] || die "Archive missing '${APP}' binary"
  install -m 0755 "/tmp/picotun_dl/${APP}" "${BIN_PATH}"
  ok "Installed binary: ${BIN_PATH}"
}

update_core() {
  ensure_deps
  local tag
  tag="$(get_latest_tag)"
  [[ -n "$tag" ]] || die "Could not detect latest release tag."
  download_asset "$tag"
}

# ========= Config =========
ensure_config_dir(){ mkdir -p "${CONFIG_DIR}"; }

write_default_server_config_if_missing(){
  ensure_config_dir
  [[ -f "${SERVER_CFG}" ]] && return
  cat > "${SERVER_CFG}" <<'YAML'
mode: "server"
listen: "0.0.0.0:1010"
psk: ""

mimic:
  fake_domain: ""
  fake_path: ""
  user_agent: "Mozilla/5.0"
  custom_headers: []
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 0

forward:
  tcp:
    - "1412->127.0.0.1:1412"
  udp: []
YAML
  ok "Created default server config: ${SERVER_CFG}"
}

write_default_client_config_if_missing(){
  ensure_config_dir
  [[ -f "${CLIENT_CFG}" ]] && return
  cat > "${CLIENT_CFG}" <<'YAML'
mode: "client"
server_url: "http://SERVER_IP:1010/tunnel"
session_id: "default"
psk: ""

mimic:
  fake_domain: ""
  fake_path: ""
  user_agent: "Mozilla/5.0"
  custom_headers: []
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 0
YAML
  ok "Created default client config: ${CLIENT_CFG}"
}

# ========= systemd =========
create_service() {
  local mode="$1" svc cfg
  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"
  else
    svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"
  fi

  say "Creating systemd service: ${svc}"
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
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Service created: ${svc}.service"
}

enable_start_service(){
  local svc="$1"
  systemctl enable --now "$svc" >/dev/null 2>&1 || true
  ok "Started: $svc"
}

# ========= Flows =========
install_server(){
  banner
  update_core
  write_default_server_config_if_missing
  create_service "server"
  enable_start_service "${SERVER_SVC}"
  systemctl status "${SERVER_SVC}" --no-pager || true
  echo ""
  read -r -p "Press Enter..." _
}

install_client(){
  banner
  update_core
  write_default_client_config_if_missing
  create_service "client"
  enable_start_service "${CLIENT_SVC}"
  systemctl status "${CLIENT_SVC}" --no-pager || true
  echo ""
  read -r -p "Press Enter..." _
}

manage_service(){
  local mode="$1" svc cfg title
  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"; title="SERVER MANAGEMENT"
  else
    svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"; title="CLIENT MANAGEMENT"
  fi

  while true; do
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}         ${title}${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) Logs (Live)"
    echo "  6) Enable Auto-start"
    echo "  7) Disable Auto-start"
    echo ""
    echo "  8) View Config"
    echo "  9) Edit Config"
    echo "  10) Delete Config & Service"
    echo ""
    echo "  0) Back"
    echo ""
    read -r -p "Select option: " c

    case "${c:-}" in
      1) systemctl start "$svc" || true; ok "Started"; sleep 1 ;;
      2) systemctl stop "$svc" || true; ok "Stopped"; sleep 1 ;;
      3) systemctl restart "$svc" || true; ok "Restarted"; sleep 1 ;;
      4) systemctl status "$svc" --no-pager || true; read -r -p "Press Enter..." _ ;;
      5) journalctl -u "$svc" -f ;;
      6) systemctl enable "$svc" >/dev/null 2>&1 || true; ok "Auto-start enabled"; sleep 1 ;;
      7) systemctl disable "$svc" >/dev/null 2>&1 || true; ok "Auto-start disabled"; sleep 1 ;;
      8) [[ -f "$cfg" ]] && cat "$cfg" || warn "Config not found: $cfg"; read -r -p "Press Enter..." _ ;;
      9)
        if [[ -f "$cfg" ]]; then
          ${EDITOR:-nano} "$cfg"
          echo ""
          read -r -p "Restart service to apply changes? [y/N]: " r
          if [[ "$r" =~ ^[Yy]$ ]]; then
            systemctl restart "$svc" || true
            ok "Service restarted"
            sleep 1
          fi
        else
          warn "Config not found: $cfg"; sleep 1
        fi
        ;;
      10)
        read -r -p "Delete ${mode} config and service? [y/N]: " y
        if [[ "$y" =~ ^[Yy]$ ]]; then
          systemctl stop "$svc" >/dev/null 2>&1 || true
          systemctl disable "$svc" >/dev/null 2>&1 || true
          rm -f "${SYSTEMD_DIR}/${svc}.service"
          rm -f "$cfg"
          systemctl daemon-reload
          ok "Deleted ${mode} config + service"
          sleep 1
        fi
        ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

settings_menu(){
  while true; do
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}            SETTINGS MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Manage Server"
    echo "  2) Manage Client"
    echo ""
    echo "  0) Back"
    echo ""
    read -r -p "Select option: " c
    case "${c:-}" in
      1) manage_service "server" ;;
      2) manage_service "client" ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

show_logs_picker(){
  banner
  echo ""
  echo "  1) Server logs"
  echo "  2) Client logs"
  read -r -p "Select: " l
  if [[ "$l" == "1" ]]; then journalctl -u "${SERVER_SVC}" -f; fi
  if [[ "$l" == "2" ]]; then journalctl -u "${CLIENT_SVC}" -f; fi
}

uninstall_all(){
  banner
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo -e "${RED}        UNINSTALL RsTunnel / PicoTun${NC}"
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}This will remove:${NC}"
  echo "  - Binary: ${BIN_PATH}"
  echo "  - Configs: ${CONFIG_DIR}"
  echo "  - Services: ${SERVER_SVC}, ${CLIENT_SVC}"
  echo ""
  read -r -p "Are you sure? [y/N]: " y
  [[ "$y" =~ ^[Yy]$ ]] || return

  say "Stopping and disabling services..."
  systemctl stop "${SERVER_SVC}" >/dev/null 2>&1 || true
  systemctl stop "${CLIENT_SVC}" >/dev/null 2>&1 || true
  systemctl disable "${SERVER_SVC}" >/dev/null 2>&1 || true
  systemctl disable "${CLIENT_SVC}" >/dev/null 2>&1 || true

  say "Removing systemd files..."
  rm -f "${SYSTEMD_DIR}/${SERVER_SVC}.service"
  rm -f "${SYSTEMD_DIR}/${CLIENT_SVC}.service"
  systemctl daemon-reload

  say "Removing binary and configs..."
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}"

  ok "Uninstalled successfully"
  exit 0
}

main_menu(){
  while true; do
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}            MAIN MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Show Logs (Pick service)"
    echo "  5) Update Core (Download latest release)"
    echo "  6) Uninstall (Remove everything)"
    echo ""
    echo "  0) Exit"
    echo ""
    read -r -p "Select option: " c

    case "${c:-}" in
      1) install_server ;;
      2) install_client ;;
      3) settings_menu ;;
      4) show_logs_picker ;;
      5) update_core; ok "Core updated. (Restart services if running)"; sleep 1 ;;
      6) uninstall_all ;;
      0) ok "Goodbye!"; exit 0 ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

need_root
main_menu

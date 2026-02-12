#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# RsTunnel Manager (Dagger-Style Automation) - Iran friendly
# - Prefers prebuilt binary (no Go needed) ✅
# - Falls back to build from source if you choose
# - Never deletes go.mod
# - Installs systemd services only if binary exists
# ============================================================================

APP_NAME="RsTunnel"
BIN_NAME="picotun"
INSTALL_DIR="/etc/${BIN_NAME}"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
SERVICE_SERVER="${BIN_NAME}-server"
SERVICE_CLIENT="${BIN_NAME}-client"

REPO_OWNER="amir6dev"
REPO_NAME="RsTunnel"
REPO_BRANCH_DEFAULT="main"
REPO_URL_DEFAULT="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

# If GitHub is blocked, we try proxy mirrors (best-effort)
DL_URLS_BASE=(
  "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download"
  "https://ghproxy.com/https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download"
  "https://mirror.ghproxy.com/https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download"
)

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"

log() { echo -e "${COLOR_CYAN}$*${COLOR_RESET}"; }
ok() { echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}✖${COLOR_RESET} $*"; }

pause() { read -r -p "Press Enter to return..." _; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  local a
  a="$(uname -m || true)"
  case "$a" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  if have_cmd apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif have_cmd yum; then
    yum install -y "${pkgs[@]}"
  elif have_cmd dnf; then
    dnf install -y "${pkgs[@]}"
  elif have_cmd apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    err "No supported package manager found."
    exit 1
  fi
}

ensure_deps() {
  log "📦 Checking dependencies..."
  local missing=()
  for c in curl git tar; do
    have_cmd "$c" || missing+=("$c")
  done
  if ((${#missing[@]}==0)); then
    ok "Dependencies already installed"
    return 0
  fi
  warn "Installing missing: ${missing[*]}"
  pkg_install "${missing[@]}"
  ok "Dependencies installed"
}

safe_workdir() { cd / || true; }

download_file() {
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 180 "$url" -o "$out"
}

download_prebuilt() {
  local arch="$1"
  local name="picotun-linux-${arch}"
  local tmp
  tmp="$(mktemp -d /tmp/picotun-dl.XXXXXX)"
  local out="${tmp}/${BIN_NAME}"

  log "⬇️  Trying to download prebuilt binary (${name})..."
  local ok_dl=0
  for base in "${DL_URLS_BASE[@]}"; do
    local u="${base}/${name}"
    log "   ${u}"
    if download_file "$u" "$out"; then
      ok_dl=1
      break
    else
      warn "Failed: ${u}"
    fi
  done

  if [[ "$ok_dl" -ne 1 ]]; then
    rm -rf "$tmp" || true
    return 1
  fi

  chmod +x "$out"
  install -m 0755 "$out" "$BIN_PATH"
  rm -rf "$tmp" || true
  ok "Installed binary to ${BIN_PATH}"
  return 0
}

clone_repo() {
  local repo_url="$1" branch="$2"
  safe_workdir
  local builddir
  builddir="$(mktemp -d /tmp/picobuild.XXXXXX)"
  log "🌐 Cloning from GitHub ..."
  git clone --depth 1 --branch "$branch" "$repo_url" "$builddir" >/dev/null
  echo "$builddir"
}

build_from_source() {
  if ! have_cmd go; then
    err "Go is not installed. For Iran-friendly install, use prebuilt binaries via GitHub Releases."
    err "If you REALLY need build-from-source: install Go via apt/yum or provide a local Go mirror."
    return 1
  fi

  local repo_url="$1" branch="$2"
  local builddir
  builddir="$(clone_repo "$repo_url" "$branch")"
  trap 'rm -rf "$builddir" 2>/dev/null || true' RETURN

  log "📦 Downloading Libraries..."
  export GOFLAGS="-mod=mod"
  ( cd "$builddir" && go mod download ) || true
  ( cd "$builddir" && go mod tidy ) || true

  log "🔨 Building binary..."
  ( cd "$builddir" && go build -o "${BIN_NAME}" ./cmd/picotun )
  install -m 0755 "${builddir}/${BIN_NAME}" "$BIN_PATH"
  ok "Built & installed to ${BIN_PATH}"
  return 0
}

make_dirs() { mkdir -p "$INSTALL_DIR"; }

write_server_service() {
  local cfg="$1"
  cat > "/etc/systemd/system/${SERVICE_SERVER}.service" <<EOF2
[Unit]
Description=${APP_NAME} Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
}

write_client_service() {
  local cfg="$1"
  cat > "/etc/systemd/system/${SERVICE_CLIENT}.service" <<EOF2
[Unit]
Description=${APP_NAME} Client Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
}

systemd_reload() { systemctl daemon-reload; }
enable_start() { systemctl enable --now "${1}.service"; }
stop_disable() { systemctl disable --now "${1}.service" 2>/dev/null || true; }

ask() {
  local prompt="$1" def="${2:-}"
  local v
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " v
    echo "${v:-$def}"
  else
    read -r -p "$prompt: " v
    echo "$v"
  fi
}

ask_yn() {
  local prompt="$1" def="${2:-Y}"
  local v
  read -r -p "$prompt [${def}/n]: " v
  v="${v:-$def}"
  [[ "$v" =~ ^[Yy]$ ]]
}

ua_by_choice() {
  case "$1" in
    1) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    2) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0" ;;
    3) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    4) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15" ;;
    5) echo "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36" ;;
    *) echo "Mozilla/5.0" ;;
  esac
}

install_core() {
  ensure_deps

  local arch
  arch="$(detect_arch)"

  # Prefer prebuilt
  if download_prebuilt "$arch"; then
    return 0
  fi

  warn "Prebuilt download failed."
  if ask_yn "Fallback to build from source (requires Go)?" "n"; then
    local repo_url branch
    repo_url="$(ask "Repo URL" "$REPO_URL_DEFAULT")"
    branch="$(ask "Repo branch" "$REPO_BRANCH_DEFAULT")"
    build_from_source "$repo_url" "$branch"
    return $?
  fi

  err "Cannot install core without prebuilt binary."
  err "Create GitHub Release assets: picotun-linux-amd64 and picotun-linux-arm64"
  return 1
}

install_server_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "         SERVER CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  local tunnel_port psk transport
  tunnel_port="$(ask "Tunnel Port" "2020")"
  psk="$(ask "Enter PSK (Pre-Shared Key)" "")"

  echo
  echo "Select Transport:"
  echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
  echo "  2) httpmux   - HTTP Mimicry"
  echo "  3) wssmux    - WebSocket Secure (TLS)"
  echo "  4) wsmux     - WebSocket"
  echo "  5) kcpmux    - KCP (UDP based)"
  echo "  6) tcpmux    - Simple TCP"
  local tchoice
  tchoice="$(ask "Choice [1-6]" "2")"
  case "$tchoice" in
    1) transport="httpsmux" ;;
    2) transport="httpmux" ;;
    3) transport="wssmux" ;;
    4) transport="wsmux" ;;
    5) transport="kcpmux" ;;
    6) transport="tcpmux" ;;
    *) transport="httpmux" ;;
  esac

  echo
  echo "PORT MAPPINGS"
  echo
  local maps=()
  local idx=1
  while true; do
    echo
    echo "Port Mapping #$idx"
    local bind_port target_port proto
    bind_port="$(ask "Bind Port (port on this server, e.g., 2222)" "")"
    target_port="$(ask "Target Port (destination port, e.g., 22)" "")"
    proto="$(ask "Protocol (tcp/udp/both)" "tcp")"
    maps+=("$proto|0.0.0.0:${bind_port}|127.0.0.1:${target_port}")
    ok "Mapping added: 0.0.0.0:${bind_port} → 127.0.0.1:${target_port} (${proto})"
    if ! ask_yn "Add another mapping?" "N"; then break; fi
    idx=$((idx+1))
  done

  local fake_domain fake_path ua uac chunked session_cookie
  fake_domain="$(ask "Fake domain (e.g., www.google.com)" "www.google.com")"
  fake_path="$(ask "Fake path (e.g., /search)" "/search")"

  echo
  echo "Select User-Agent:"
  echo "  1) Chrome Windows (default)"
  echo "  2) Firefox Windows"
  echo "  3) Chrome macOS"
  echo "  4) Safari macOS"
  echo "  5) Chrome Android"
  echo "  6) Custom"
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then
    ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"
  else
    ua="$(ua_by_choice "$uac")"
  fi

  if ask_yn "Enable session cookies?" "Y"; then session_cookie="true"; else session_cookie="false"; fi
  if ask_yn "Enable chunked encoding?" "n"; then chunked="true"; else chunked="false"; fi

  if ! install_core; then
    pause
    return
  fi

  make_dirs
  local cfg="${INSTALL_DIR}/server.yaml"
  {
    echo "mode: \"server\""
    echo "listen: \"0.0.0.0:${tunnel_port}\""
    echo "transport: \"${transport}\""
    echo "psk: \"${psk}\""
    echo "profile: \"latency\""
    echo "verbose: true"
    echo
    echo "heartbeat: 2"
    echo
    echo "maps:"
    for m in "${maps[@]}"; do
      IFS='|' read -r mtype mbind mtarget <<<"$m"
      echo "  - type: ${mtype}"
      echo "    bind: \"${mbind}\""
      echo "    target: \"${mtarget}\""
    done
    echo
    echo "obfuscation:"
    echo "  enabled: true"
    echo "  min_padding: 8"
    echo "  max_padding: 32"
    echo "  min_delay_ms: 0"
    echo "  max_delay_ms: 0"
    echo "  burst_chance: 0"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"Accept-Language: en-US,en;q=0.9\""
    echo "    - \"Accept-Encoding: gzip, deflate, br\""
  } > "$cfg"

  if [[ ! -x "$BIN_PATH" ]]; then
    err "Binary not found at ${BIN_PATH}, aborting service install."
    pause
    return
  fi

  write_server_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_SERVER"

  echo
  ok "Server configured"
  echo "  Config: ${cfg}"
  echo "  Logs: journalctl -u ${SERVICE_SERVER} -f"
  echo
  pause
}

install_client_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "         CLIENT CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  local psk profile obfs_enabled verbose
  psk="$(ask "Enter PSK (must match server)" "")"

  echo
  echo "Select Performance Profile:"
  echo "  1) balanced"
  echo "  2) aggressive"
  echo "  3) latency"
  echo "  4) cpu-efficient"
  echo "  5) gaming"
  local pchoice
  pchoice="$(ask "Choice [1-5]" "1")"
  case "$pchoice" in
    1) profile="balanced" ;;
    2) profile="aggressive" ;;
    3) profile="latency" ;;
    4) profile="cpu-efficient" ;;
    5) profile="gaming" ;;
    *) profile="balanced" ;;
  esac

  if ask_yn "Enable Traffic Obfuscation?" "Y"; then obfs_enabled="true"; else obfs_enabled="false"; fi

  local transport addr pool aggressive retry dial_timeout
  echo
  echo "Select Transport Type:"
  echo "  1) tcpmux"
  echo "  2) kcpmux"
  echo "  3) wsmux"
  echo "  4) wssmux"
  echo "  5) httpmux"
  echo "  6) httpsmux"
  local tchoice
  tchoice="$(ask "Choice [1-6]" "5")"
  case "$tchoice" in
    1) transport="tcpmux" ;;
    2) transport="kcpmux" ;;
    3) transport="wsmux" ;;
    4) transport="wssmux" ;;
    5) transport="httpmux" ;;
    6) transport="httpsmux" ;;
    *) transport="httpmux" ;;
  esac

  addr="$(ask "Server address with Tunnel Port (e.g., 1.2.3.4:4000)" "")"
  pool="$(ask "Connection pool size" "2")"
  if ask_yn "Enable aggressive pool?" "N"; then aggressive="true"; else aggressive="false"; fi
  retry="$(ask "Retry interval (seconds)" "3")"
  dial_timeout="$(ask "Dial timeout (seconds)" "10")"

  local fake_domain fake_path ua uac chunked session_cookie
  echo
  echo "HTTP MIMICRY SETTINGS"
  fake_domain="$(ask "Fake domain (e.g., www.google.com)" "www.google.com")"
  fake_path="$(ask "Fake path (e.g., /search)" "/search")"

  echo
  echo "Select User-Agent:"
  echo "  1) Chrome Windows"
  echo "  2) Firefox Windows"
  echo "  3) Chrome macOS"
  echo "  4) Safari macOS"
  echo "  5) Chrome Android"
  echo "  6) Custom"
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"; else ua="$(ua_by_choice "$uac")"; fi
  if ask_yn "Enable chunked encoding?" "Y"; then chunked="true"; else chunked="false"; fi
  if ask_yn "Enable session cookies?" "Y"; then session_cookie="true"; else session_cookie="false"; fi
  if ask_yn "Enable verbose logging?" "N"; then verbose="true"; else verbose="false"; fi

  if ! install_core; then
    pause
    return
  fi

  make_dirs
  local cfg="${INSTALL_DIR}/client.yaml"
  {
    echo "mode: \"client\""
    echo "psk: \"${psk}\""
    echo "profile: \"${profile}\""
    echo "verbose: ${verbose}"
    echo
    echo "paths:"
    echo "  - transport: \"${transport}\""
    echo "    addr: \"${addr}\""
    echo "    connection_pool: ${pool}"
    echo "    aggressive_pool: ${aggressive}"
    echo "    retry_interval: ${retry}"
    echo "    dial_timeout: ${dial_timeout}"
    echo
    echo "obfuscation:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: 16"
    echo "  max_padding: 512"
    echo "  min_delay_ms: 5"
    echo "  max_delay_ms: 50"
    echo "  burst_chance: 0.15"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"X-Requested-With: XMLHttpRequest\""
    echo "    - \"Referer: https://${fake_domain}/\""
  } > "$cfg"

  if [[ ! -x "$BIN_PATH" ]]; then
    err "Binary not found at ${BIN_PATH}, aborting service install."
    pause
    return
  fi

  write_client_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_CLIENT"

  echo
  ok "Client configured"
  echo "  Config: ${cfg}"
  echo "  Logs: journalctl -u ${SERVICE_CLIENT} -f"
  echo
  pause
}

settings_menu() {
  while true; do
    clear
    echo "═══════════════════════════════════════"
    echo "     SETTINGS (Manage Services)"
    echo "═══════════════════════════════════════"
    echo
    echo "  1) Status"
    echo "  2) Restart Server"
    echo "  3) Restart Client"
    echo "  4) Stop/Disable Server"
    echo "  5) Stop/Disable Client"
    echo "  6) View Config Paths"
    echo
    echo "  0) Back"
    echo
    local c
    c="$(ask "Select option" "0")"
    case "$c" in
      1)
        systemctl status "${SERVICE_SERVER}.service" --no-pager || true
        echo
        systemctl status "${SERVICE_CLIENT}.service" --no-pager || true
        pause
        ;;
      2) systemctl restart "${SERVICE_SERVER}.service" || true; ok "Server restarted"; pause ;;
      3) systemctl restart "${SERVICE_CLIENT}.service" || true; ok "Client restarted"; pause ;;
      4) stop_disable "${SERVICE_SERVER}"; ok "Server disabled"; pause ;;
      5) stop_disable "${SERVICE_CLIENT}"; ok "Client disabled"; pause ;;
      6)
        echo "Config dir: ${INSTALL_DIR}"
        echo "Server cfg: ${INSTALL_DIR}/server.yaml"
        echo "Client cfg: ${INSTALL_DIR}/client.yaml"
        echo "Binary: ${BIN_PATH}"
        pause
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

uninstall_all() {
  clear
  echo "═══════════════════════════════════════"
  echo "             UNINSTALL"
  echo "═══════════════════════════════════════"
  echo

  if ! ask_yn "Remove ${APP_NAME} services, configs, and binary?" "n"; then
    warn "Canceled"
    pause
    return
  fi

  stop_disable "$SERVICE_SERVER"
  stop_disable "$SERVICE_CLIENT"
  rm -f "/etc/systemd/system/${SERVICE_SERVER}.service" "/etc/systemd/system/${SERVICE_CLIENT}.service" || true
  systemctl daemon-reload || true

  rm -rf "$INSTALL_DIR" || true
  rm -f "$BIN_PATH" || true

  ok "Uninstalled."
  pause
}

main_menu() {
  while true; do
    clear
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Update Core (Download Binary)"
    echo "  5) Uninstall"
    echo
    echo "  0) Exit"
    echo
    local opt
    opt="$(ask "Select option" "0")"
    case "$opt" in
      1) install_server_flow ;;
      2) install_client_flow ;;
      3) settings_menu ;;
      4)
        if install_core; then ok "Core updated"; else err "Core update failed"; fi
        pause
        ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
main_menu
EOF

bash /root/setup.sh

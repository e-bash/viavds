#!/usr/bin/env bash
# viavds.sh -- unified installer & status tool for viavds
# Version: 1.1.0
# Purpose: status / install (local / server) for viavds project.
# Key changes in this version:
#  - Do not run whole script as root. Use sudo only where required.
#  - Download binaries to /tmp then sudo mv -> /usr/local/bin.
#  - Detect plain binary vs archive before tar extraction.
#  - Robust cloudflared installation (apt repo if available, fallback to binary).
#  - Safer mkcert handling for WSL vs native Linux / macOS / Windows considerations.
#  - Better docker permission handling: suggest usermod -aG docker; do NOT run docker compose as root automatically.
#  - Improved logging and verbose modes. All external command output is printed to terminal (no silent redirects).
#  - Activation URL + QR utility included.
#
# Usage examples:
#  # status (recommended run as normal user)
#  curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh | bash -s -- status
#
#  # install for local development (run as normal user; will sudo only where needed)
#  curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh \
#    | bash -s -- install --dir "$HOME/viavds" --webhook-host wh.vianl.loc --tunnel-host ngrok.vianl.loc --mkcert --cf-tunnel --yes --verbose
#
#  # quick server install (run as normal user; script will sudo for privileged ops)
#  curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh \
#    | bash -s -- install --dir /opt/viavds --webhook-host wh.vianl.ru --tunnel-host ngrok.vianl.ru --cf-tunnel --yes --verbose
#
set -euo pipefail
IFS=$'\n\t'

########################################
# metadata
VER="1.1.0"
SCRIPT_NAME="$(basename "$0")"

########################################
# logging / output
LOG_FILE=""
VERBOSE=false
DRY_RUN=false

_info(){ printf "\e[1;34m%s\e[0m\n" "$*"; }
_ok(){ printf "\e[1;32m%s\e[0m\n" "$*"; }
_warn(){ printf "\e[1;33m%s\e[0m\n" "$*"; }
_err(){ printf "\e[1;31m%s\e[0m\n" "$*" >&2; }

log() {
  # log both to stdout and to log file if configured
  local msg="$*"
  printf '%s\n' "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$(date --iso-8601=seconds) %s" "$msg" >>"$LOG_FILE" 2>&1 || true
  fi
}

run_cmd() {
  # Execute a command showing it first if verbose. Do not hide stdout/stderr.
  # Usage: run_cmd <cmd-string>
  local cmd="$*"
  if $DRY_RUN; then
    log "[DRYRUN] $cmd"
    return 0
  fi
  if $VERBOSE; then
    log "+ $cmd"
    eval "$cmd"
    return $?
  else
    # still print command output, just don't print the leading + line
    eval "$cmd"
    return $?
  fi
}

########################################
# defaults and flags
CMD="status"
PROJECT_DIR=""
REPO_URL="https://github.com/e-bash/viavds.git"
BRANCH="master"
WEBHOOK_HOST=""
TUNNEL_HOST=""
CF_TOKEN=""
PORT=14127
DO_MKCERT=false
DO_CFTUNNEL=false
ALLOW_INSTALL_DOCKER=false
ALLOW_INSTALL_NGINX=false
ASSUME_YES=false

# counters
WARN_COUNT=0
ERR_COUNT=0

########################################
# helper: detect whether running under WSL
is_wsl() {
  [[ -f /proc/version ]] && grep -qi 'microsoft' /proc/version 2>/dev/null
}

# helper: run a command as a non-root user if the script was started with sudo
# If the script is run normally (no sudo), just runs the command.
run_as_user() {
  # run_as_user <command...>
  if [[ -n "${SUDO_USER-}" && "$(id -u)" -eq 0 ]]; then
    # run as the original invoking user
    if command -v sudo >/dev/null 2>&1; then
      sudo -H -u "$SUDO_USER" bash -lc "$*"
    else
      su - "$SUDO_USER" -c "$*"
    fi
  else
    bash -lc "$*"
  fi
}

########################################
# pkg manager autodetect
PKG_MANAGER="unknown"
PKG_INSTALL_CMD=""
PKG_UPDATE_CMD=""
detect_pkg_manager() {
  PKG_MANAGER="unknown"
  PKG_INSTALL_CMD=""
  PKG_UPDATE_CMD=""
  if command -v brew >/dev/null 2>&1; then
    PKG_MANAGER="brew"
    PKG_INSTALL_CMD="brew install"
    PKG_UPDATE_CMD="brew update"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_INSTALL_CMD="apt-get install -y"
    PKG_UPDATE_CMD="apt-get update"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_INSTALL_CMD="dnf install -y"
    PKG_UPDATE_CMD="dnf makecache"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_INSTALL_CMD="yum install -y"
    PKG_UPDATE_CMD="yum makecache"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    PKG_INSTALL_CMD="pacman -S --noconfirm"
    PKG_UPDATE_CMD="pacman -Sy"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_UPDATE_CMD="apk update"
  else
    PKG_MANAGER="unknown"
  fi
  log "/usr/bin/which pkg manager -> $PKG_MANAGER"
}

pkg_install() {
  # pkg_install package1 package2 ...
  local pkgs=( "$@" )
  if [[ "$PKG_MANAGER" == "unknown" ]]; then
    _warn "Package manager not detected; cannot auto-install packages: ${pkgs[*]}"
    ((WARN_COUNT++))
    return 1
  fi
  _info "Installing packages: ${pkgs[*]} using $PKG_MANAGER"
  if $DRY_RUN; then
    log "[DRYRUN] $PKG_INSTALL_CMD ${pkgs[*]}"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt) run_cmd "sudo $PKG_UPDATE_CMD";;
    dnf|yum|pacman|apk) run_cmd "sudo $PKG_UPDATE_CMD" || true;;
    brew) run_cmd "$PKG_UPDATE_CMD" || true;;
  esac
  run_cmd "sudo $PKG_INSTALL_CMD ${pkgs[*]}"
}

########################################
# find project dir heuristics
PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )
find_project_dir() {
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
      echo "$PROJECT_DIR"; return 0
    else
      _warn "--dir provided but no docker-compose.yml found there"
      ((WARN_COUNT++))
    fi
  fi
  for d in "${PROJECT_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" ]]; then
      echo "$(cd "$d" && pwd)"; return 0
    fi
  done
  # walk up from cwd
  local cur="$PWD"
  while [[ "$cur" != "/" ]]; do
    if [[ -f "$cur/docker-compose.yml" ]]; then
      echo "$cur"; return 0
    fi
    cur=$(dirname "$cur")
  done
  echo ""
  return 1
}

########################################
# networking / port check
is_port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -qE "[:.]${port}\>" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt | grep -qE "[:.]${port}\>" && return 0 || return 1
  fi
  return 2
}

########################################
# detect environment: local (wsl/mac) or public
detect_environment() {
  if is_wsl; then
    echo "local (wsl)"; return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "local (macos)"; return 0
  fi
  # try to get public ip; if private -> local
  local pubip=""
  if command -v curl >/dev/null 2>&1; then
    pubip=$(curl -fsS --max-time 3 https://ifconfig.co || true)
  fi
  if [[ -z "$pubip" ]]; then
    echo "local"
    return 0
  fi
  if [[ "$pubip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then
    echo "local"
    return 0
  fi
  echo "public"
  return 0
}

########################################
# cloudflared install helper (robust)
cloudflared_install() {
  # Try apt repo first (if pkg supports codename), else fallback to direct binary download
  log "Attempting to install cloudflared..."
  if command -v cloudflared >/dev/null 2>&1; then
    _ok "cloudflared already installed: $(cloudflared --version 2>&1 || true)"
    return 0
  fi

  # Try apt source (best-effort)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    local codename
    if command -v lsb_release >/dev/null 2>&1; then
      codename="$(lsb_release -cs || true)"
    else
      codename="$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME" || true)"
    fi
    if [[ -n "$codename" ]]; then
      _info "Trying official Cloudflare apt repo for distro: $codename"
      run_cmd "curl -L https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-client-archive-keyring.gpg" || true
      run_cmd "echo \"deb [signed-by=/usr/share/keyrings/cloudflare-client-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main\" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list"
      run_cmd "sudo apt-get update"
      if run_cmd "sudo apt-get install -y cloudflared"; then
        _ok "cloudflared installed via apt"
        return 0
      else
        _warn "cloudflared apt package not available for ${codename} or install failed; fallback to binary"
      fi
    else
      _warn "Cannot determine distribution codename; skipping apt repo approach"
    fi
  fi

  # Fallback: download latest direct binary (stable) and install to /usr/local/bin
  # We'll prefer the "linux-amd64" plain binary (not tar). We detect arch and choose appropriate filename.
  local arch
  arch=$(uname -m)
  local file_arch="amd64"
  case "$arch" in
    x86_64|amd64) file_arch="amd64";;
    aarch64|arm64) file_arch="arm64";;
    armv7l) file_arch="armhf";;
    i386|i686) file_arch="386";;
    *) file_arch="amd64";;
  esac
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${file_arch}"
  local tmpf="/tmp/cloudflared-$$.bin"

  _info "Downloading cloudflared binary from: $url"
  run_cmd "curl -L -o \"$tmpf\" \"$url\""
  run_cmd "sudo mv \"$tmpf\" /usr/local/bin/cloudflared"
  run_cmd "sudo chmod +x /usr/local/bin/cloudflared"
  if command -v cloudflared >/dev/null 2>&1; then
    _ok "cloudflared installed to /usr/local/bin/cloudflared"
    cloudflared --version || true
    return 0
  fi

  _err "cloudflared installation failed"
  return 1
}

########################################
# mkcert install & create certs (careful with WSL)
install_mkcert() {
  if command -v mkcert >/dev/null 2>&1; then
    _ok "mkcert already installed: $(mkcert --version 2>&1 || true)"
    return 0
  fi

  _info "Installing mkcert (download to /tmp then move to /usr/local/bin)..."
  local url
  if [[ "$(uname -s)" == "Darwin" ]]; then
    url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-darwin-amd64"
  else
    # linux
    local arch
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
      url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-amd64"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
      url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-arm64"
    else
      url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-amd64"
    fi
  fi

  local tmpf="/tmp/mkcert-$$.bin"
  run_cmd "curl -L -o \"$tmpf\" \"$url\""
  run_cmd "sudo mv \"$tmpf\" /usr/local/bin/mkcert"
  run_cmd "sudo chmod +x /usr/local/bin/mkcert"
  _ok "mkcert placed to /usr/local/bin/mkcert"
}

generate_mkcert_for_host() {
  local host="$1"
  local certdir="/etc/viavds/certs"
  run_cmd "sudo mkdir -p \"$certdir\""
  # make the certdir readable by root and optionally by owner; keep root owner by default
  run_cmd "sudo chown root:root \"$certdir\" || true"
  run_cmd "sudo chmod 0755 \"$certdir\""
  # mkcert -install must be run as the user who will use the cert trust store.
  # For WSL: warn user that browsers on Windows may need mkcert in Windows.
  if is_wsl; then
    _warn "Detected WSL. If you browse from Windows, you should install mkcert in Windows and run 'mkcert -install' there so Windows browsers trust certs. This script will still generate certs for local usage."
    ((WARN_COUNT++))
  fi

  # Run mkcert -install as the invoking (non-root) user to properly install trust anchors in user context
  run_as_user "mkcert -install" || _warn "mkcert -install returned non-zero"
  # Generate certs as root so files are in /etc/viavds/certs
  run_cmd "sudo mkcert -key-file \"$certdir/$host-key.pem\" -cert-file \"$certdir/$host.pem\" \"$host\""
  _ok "mkcert: certificate generated for $host in $certdir"
}

########################################
# nginx config helpers
configure_nginx_for_host() {
  local host="$1"; local proxy_port="$2"
  local confdir="/etc/nginx/sites-available"; local enabled="/etc/nginx/sites-enabled"
  run_cmd "sudo mkdir -p \"$confdir\" \"$enabled\""
  local conf="/tmp/viavds-$host.conf"
  cat > "$conf" <<EOF
server {
    listen 80;
    server_name $host;
    location / {
        proxy_pass http://127.0.0.1:$proxy_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
  run_cmd "sudo mv \"$conf\" \"$confdir/viavds-$host.conf\""
  run_cmd "sudo ln -sf \"$confdir/viavds-$host.conf\" \"$enabled/viavds-$host.conf\""
  run_cmd "sudo nginx -t || true"
  run_cmd "sudo systemctl reload nginx || true"
  _ok "nginx configured for $host -> 127.0.0.1:$proxy_port"
}

configure_nginx_with_tls() {
  local host="$1"; local proxy_port="$2"; local certdir="/etc/viavds/certs"
  local confdir="/etc/nginx/sites-available"; local enabled="/etc/nginx/sites-enabled"
  run_cmd "sudo mkdir -p \"$confdir\" \"$enabled\" \"$certdir\""
  local conf="/tmp/viavds-$host.conf"
  cat > "$conf" <<EOF
server {
    listen 80;
    server_name $host;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $host;

    ssl_certificate $certdir/$host.pem;
    ssl_certificate_key $certdir/$host-key.pem;

    location / {
        proxy_pass http://127.0.0.1:$proxy_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
  run_cmd "sudo mv \"$conf\" \"$confdir/viavds-$host.conf\""
  run_cmd "sudo ln -sf \"$confdir/viavds-$host.conf\" \"$enabled/viavds-$host.conf\""
  run_cmd "sudo nginx -t || true"
  run_cmd "sudo systemctl reload nginx || true"
  _ok "nginx with TLS configured for $host"
}

########################################
# cloudflared config skeleton prepare
prepare_cloudflared_config() {
  local tunnel_name="$1"; local tunnel_port="$2"; local hostname="$3"
  run_cmd "sudo mkdir -p /etc/cloudflared"
  cat > /tmp/cloudflared-config-$$.yml <<EOF
tunnel: $tunnel_name
credentials-file: /etc/cloudflared/$tunnel_name.json

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$tunnel_port
  - service: http_status:404
EOF
  run_cmd "sudo mv /tmp/cloudflared-config-$$.yml /etc/cloudflared/config.yml"
  run_cmd "sudo chown root:root /etc/cloudflared/config.yml || true"
  _ok "Prepared /etc/cloudflared/config.yml ingress for $hostname -> 127.0.0.1:$tunnel_port"
}

########################################
# hosts helper
add_hosts_entry() {
  local host="$1"
  local ip="${2:-127.0.0.1}"
  if grep -qE "^[^#]*\s+$host(\s|$)" /etc/hosts 2>/dev/null; then
    _info "Host $host already present in /etc/hosts"
    return 0
  fi
  run_cmd "sudo sh -c 'echo \"$ip $host\" >> /etc/hosts'"
  _ok "Added /etc/hosts entry: $ip $host"
}

########################################
# docker checks & info
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    _warn "docker: not installed"
    ((WARN_COUNT++))
    DOCKER_PRESENT=false
    DOCKER_RUNNING=false
    return 1
  fi
  DOCKER_PRESENT=true
  # check daemon
  if (pgrep -x dockerd >/dev/null 2>&1) || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker); then
    _ok "docker daemon: running"
    DOCKER_RUNNING=true
  else
    _warn "docker daemon: not running or accessible"
    DOCKER_RUNNING=false
    ((WARN_COUNT++))
  fi
}

check_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    _ok "docker compose: present"
  else
    _warn "docker compose (v2) not present"
    ((WARN_COUNT++))
  fi
}

check_viavds_container() {
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then
    _warn "viavds container: check skipped (docker not present)"; ((WARN_COUNT++)); return
  fi
  local info
  info=$(docker ps --filter "name=viavds" --format "name={{.Names}} status={{.Status}} ports={{.Ports}}" | head -n1 || true)
  if [[ -n "$info" ]]; then
    _ok "viavds container: $info"
    return 0
  fi
  info=$(docker ps -a --filter "name=viavds" --format "name={{.Names}} status={{.Status}}" | head -n1 || true)
  if [[ -n "$info" ]]; then
    _warn "viavds container present but stopped: $info"
    ((WARN_COUNT++))
  else
    _warn "viavds container not found"
    ((WARN_COUNT++))
  fi
}

check_images() {
  local dir="$1"
  if [[ -z "$dir" || ! -f "$dir/docker-compose.yml" ]]; then
    _warn "Images: skip (no compose file)"
    ((WARN_COUNT++))
    return
  fi
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then
    _warn "Images: skipped (docker not present)"
    ((WARN_COUNT++))
    return
  fi
  local imgs
  IFS=$'\n' read -r -d '' -a imgs < <(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true; printf '\0')
  if [[ ${#imgs[@]} -eq 0 ]]; then
    _warn "Images: none declared in compose"
    ((WARN_COUNT++))
    return
  fi
  for im in "${imgs[@]}"; do
    if docker image inspect "$im" >/dev/null 2>&1; then
      _ok "Image present: $im"
    else
      _warn "Image missing: $im"
      ((WARN_COUNT++))
    fi
  done
}

check_networks_volumes() {
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then
    _warn "Networks & volumes: skipped (docker not present)"
    ((WARN_COUNT++))
    return
  fi
  if [[ "${DOCKER_RUNNING:-false}" != true ]]; then
    _warn "Networks & volumes: docker not running; skip detailed checks"
    ((WARN_COUNT++))
    return
  fi
  log "Docker networks:"
  docker network ls --format "  {{.Name}}"
  log "Docker volumes:"
  docker volume ls --format "  {{.Name}}"
}

check_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then _ok "nginx config OK"; else _err "nginx config error"; ((ERR_COUNT++)); fi
  else
    _warn "nginx: not installed"
    ((WARN_COUNT++))
  fi
}

check_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    cloudflared --version 2>&1 || true
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cloudflared 2>/dev/null; then
      _ok "cloudflared: running"
    else
      _warn "cloudflared: installed but not running"
      ((WARN_COUNT++))
    fi
  else
    _warn "cloudflared: not installed"
    ((WARN_COUNT++))
  fi
}

check_webhook() {
  if is_port_listening "$PORT"; then
    _ok "port $PORT: listening"
  else
    _warn "port $PORT: not listening"
    ((WARN_COUNT++))
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      _ok "health endpoint OK"
    else
      _warn "health endpoint not responding"
      ((WARN_COUNT++))
    fi
  else
    _warn "curl missing: cannot test health endpoint"
    ((WARN_COUNT++))
  fi
}

########################################
# helper: show activation URL and QR (if qrencode present)
activate_url() {
  local url
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    url="$1"
  else
    # try to read from stdin
    url="$(cat - 2>/dev/null || true)"
  fi
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  printf '\nДля активации сервиса перейдите по ссылке %s\n\n' "$url"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o - -t UTF8 "$url" 2>/dev/null || qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null || true
    printf '\n'
  fi
}

# Attempt to run interactive cloudflared login automatically and print activation URL (best-effort)
cloudflared_login_interactive() {
  # This tries to capture the activation URL that cloudflared prints.
  if ! command -v cloudflared >/dev/null 2>&1; then
    _err "cloudflared not installed; cannot run login"
    return 1
  fi
  _info "Starting cloudflared tunnel login (this may open a browser or print an activation URL)."
  _info "If a browser does not open, copy the URL printed here and run activate_url <url> to print a QR."
  # We will try to run the command and capture stdout for a short time.
  # cloudflared tunnel login typically prints a URL and waits.
  # Use run_as_user so credentials are stored in non-root $HOME.
  run_as_user "cloudflared tunnel login" || {
    _warn "cloudflared tunnel login returned non-zero; you may need to run it interactively as the invoking user."
    return 1
  }
  _ok "cloudflared login attempt finished. Check instructions in your terminal (or your browser)."
  return 0
}

########################################
# installer main routine
do_install() {
  detect_pkg_manager
  log "Package manager: ${PKG_MANAGER}"
  local ENV
  ENV="$(detect_environment)"
  log "Environment detected: $ENV"

  if [[ "$ENV" == local* ]]; then
    _info "Local environment detected ($ENV) — script will avoid apt-installing Docker Engine automatically."
    if $ALLOW_INSTALL_DOCKER; then
      _warn "--install-docker requested but skipped for local environment. Please install Docker Desktop / Docker Engine as appropriate."
      ((WARN_COUNT++))
    fi
  fi

  # Ensure basic tools exist (curl, git, ca-certificates, jq)
  log "Ensuring basic tools: curl git ca-certificates jq"
  pkg_install curl git ca-certificates jq || _warn "Some packages could not be installed automatically."

  # qrencode optional (for activation URL display)
  pkg_install qrencode || true

  # cloudflared installation (robust)
  if ! command -v cloudflared >/dev/null 2>&1; then
    if cloudflared_install; then
      _ok "cloudflared installed"
    else
      _warn "cloudflared install failed"
      ((WARN_COUNT++))
    fi
  else
    _ok "cloudflared present: $(cloudflared --version 2>&1 || true)"
  fi

  # mkcert if requested
  if $DO_MKCERT; then
    install_mkcert || _warn "mkcert install helper failed"
  fi

  # Prepare project dir (clone repo as invoking user)
  if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$HOME/viavds"
  fi
  _info "Project directory: $PROJECT_DIR"
  run_cmd "mkdir -p \"$PROJECT_DIR\""
  # Clone repo as non-root user to avoid root-owned files
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    _info "Project already present at $PROJECT_DIR (skipping clone)"
  else
    _info "Cloning repository $REPO_URL branch $BRANCH -> $PROJECT_DIR"
    # Use run_as_user so clone happens as the invoking user (not root)
    run_as_user "git clone --depth 1 --branch \"$BRANCH\" \"$REPO_URL\" \"$PROJECT_DIR\"" || {
      _warn "git clone failed; please clone manually or check network/credentials"
      ((WARN_COUNT++))
    }
  fi

  # Docker sanity
  check_docker || true
  if [[ "${DOCKER_PRESENT:-false}" == false ]]; then
    _warn "Docker not present. On server installations you can pass --install-docker (subject to limitations)."
  fi

  # Docker compose note
  if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    _warn "docker compose v2 plugin not available"
  fi

  # mkcert cert generation and nginx config
  if $DO_MKCERT && [[ -n "$WEBHOOK_HOST" ]]; then
    generate_mkcert_for_host "$WEBHOOK_HOST" || _warn "mkcert certificate generation reported issues"
    if command -v nginx >/dev/null 2>&1; then
      configure_nginx_with_tls "$WEBHOOK_HOST" "$PORT" || _warn "nginx TLS config failed"
    else
      _warn "nginx not installed; skipping nginx TLS vhost creation"
    fi
    add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"
  elif [[ -n "$WEBHOOK_HOST" ]]; then
    if command -v nginx >/dev/null 2>&1; then
      configure_nginx_for_host "$WEBHOOK_HOST" "$PORT"
      add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"
    else
      _warn "nginx not installed; skipping vhost creation"
    fi
  fi

  if [[ -n "$TUNNEL_HOST" || -n "$DO_CFTUNNEL" ]]; then
    local tname
    tname="viavds-$(hostname -s)-$(date +%s)"
    prepare_cloudflared_config "$tname" "$PORT" "${TUNNEL_HOST:-ngrok.vianl.loc}"
    log "Prepared cloudflared config. Next interactive steps (run as non-root user):"
    echo
    echo "  1) As the non-root user, run: cloudflared tunnel login"
    echo "     Use activate_url <url> to print activation URL + QR in terminal if cloudflared prints a URL."
    echo
    echo "  2) Create the tunnel and route DNS (example):"
    echo "     cloudflared tunnel create $tname"
    echo "     cloudflared tunnel route dns $tname ${TUNNEL_HOST:-ngrok.vianl.loc}"
    echo
    echo "  3) Move credential JSON to /etc/cloudflared and enable service as root:"
    echo "     sudo mv ~/.cloudflared/$tname.json /etc/cloudflared/$tname.json"
    echo "     sudo systemctl enable --now cloudflared"
    echo
    echo "  You can try automated login capture by running: cloudflared_login_interactive"
    echo
  fi

  # Start docker compose if possible (do not run docker compose as root by default)
  if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      _info "Starting docker compose in $PROJECT_DIR (as non-root user if possible)"
      # run as user so volumes and files created have correct ownership
      if [[ -n "${SUDO_USER-}" && "$(id -u)" -eq 0 ]]; then
        run_as_user "cd \"$PROJECT_DIR\" && docker compose up -d --build"
      else
        run_cmd "cd \"$PROJECT_DIR\" && docker compose up -d --build"
      fi
    else
      _warn "Skipping docker compose start: docker/docker-compose not ready"
    fi
  else
    _warn "docker-compose.yml not found in $PROJECT_DIR; skipping docker compose start"
  fi

  _ok "Install sequence finished (check summary below)."
}

########################################
# status command
cmd_status() {
  _info "=== viavds STATUS CHECK ==="
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  local ENV; ENV="$(detect_environment)"
  _info "Environment: $ENV"
  for c in curl jq git; do
    if command -v "$c" >/dev/null 2>&1; then
      _ok "$c: ok"
    else
      _warn "$c: missing"
      ((WARN_COUNT++))
    fi
  done
  check_docker || true
  check_compose
  PROJECT_DIR="$(find_project_dir || true)"
  _info "Project dir: ${PROJECT_DIR:-not found}"
  check_viavds_container
  check_images "$PROJECT_DIR"
  check_networks_volumes
  check_nginx
  check_cloudflared
  check_webhook
  echo
  _info "SUMMARY:"
  _info " Project dir: ${PROJECT_DIR:-not found}"
  _info " Environment: $ENV"
  _info " Webhook host: ${WEBHOOK_HOST:-not set}"
  _info " Tunnel host: ${TUNNEL_HOST:-not set}"
  if (( ERR_COUNT > 0 )); then _err "Errors: $ERR_COUNT"; fi
  if (( WARN_COUNT > 0 )); then _warn "Warnings: $WARN_COUNT"; else _ok "No warnings"; fi
}

cmd_install() {
  _info "=== viavds INSTALL ==="
  do_install
  echo
  _info "FINAL SUMMARY:"
  _info "webhook-host: ${WEBHOOK_HOST:-not set}"
  _info "tunnel-host: ${TUNNEL_HOST:-not set}"
  _info "project dir: ${PROJECT_DIR:-not set}"
  if (( ERR_COUNT > 0 )); then _err "Errors: $ERR_COUNT (see above)"; fi
  if (( WARN_COUNT > 0 )); then _warn "Warnings: $WARN_COUNT"; else _ok "No warnings"; fi
}

########################################
# arg parsing
usage() {
  cat <<EOF
$SCRIPT_NAME v$VER

Usage:
  $SCRIPT_NAME [command] [options]

Commands:
  status                 Run diagnostics (default)
  install                Install viavds (auto-detect local / public)

Options (install/status):
  --dir PATH             Project directory (default: \$HOME/viavds)
  --repo URL             Git repository to clone (default: $REPO_URL)
  --branch BRANCH        Repo branch (default: $BRANCH)
  --webhook-host HOST    Hostname for webhook/API endpoint (e.g. wh.example.com)
  --tunnel-host HOST     Hostname for tunnel (e.g. ngrok.example.com)
  --cf-token TOKEN       Cloudflare API token (optional, advanced)
  --port N               Service port (default: $PORT)
  --mkcert               (local) install and run mkcert to generate certs for webhook-host
  --cf-tunnel            prepare cloudflared config
  --install-docker       allow installing docker (ignored on WSL/macos unless --yes and Windows winget available)
  --install-nginx        allow installing nginx (server mode)
  --yes                  non-interactive: auto-accept prompts and allow certain automated installs
  --dry-run              show actions without executing
  --verbose              verbose mode (echo commands and output)
  --log-file FILE        append logs to FILE
  -h, --help             show this help

Examples:
  $SCRIPT_NAME status
  $SCRIPT_NAME install --dir /opt/viavds --webhook-host wh.vianl.loc --tunnel-host ngrok.vianl.loc --mkcert --cf-tunnel --yes --verbose

EOF
  exit 0
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|install) CMD="$1"; shift;;
    --dir) PROJECT_DIR="$2"; shift 2;;
    --repo) REPO_URL="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --webhook-host) WEBHOOK_HOST="$2"; shift 2;;
    --tunnel-host) TUNNEL_HOST="$2"; shift 2;;
    --cf-token) CF_TOKEN="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --mkcert) DO_MKCERT=true; shift;;
    --cf-tunnel) DO_CFTUNNEL=true; TUNNEL_HOST="${TUNNEL_HOST:-ngrok.vianl.loc}"; shift;;
    --install-docker) ALLOW_INSTALL_DOCKER=true; shift;;
    --install-nginx) ALLOW_INSTALL_NGINX=true; shift;;
    --yes) ASSUME_YES=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --verbose) VERBOSE=true; shift;;
    --log-file) LOG_FILE="$2"; shift 2;;
    -h|--help) usage;;
    *)
      _err "Unknown arg: $1"
      usage
      ;;
  esac
done

# Validate log file (try to create or fallback)
if [[ -n "$LOG_FILE" ]]; then
  # try to create parent directory if needed
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! touch "$LOG_FILE" 2>/dev/null; then
    _warn "Cannot write to $LOG_FILE; falling back to /tmp/viavds-install.log"
    LOG_FILE="/tmp/viavds-install.log"
    touch "$LOG_FILE" 2>/dev/null || true
  fi
  _info "Logfile: $LOG_FILE"
fi

# Execute requested command
case "$CMD" in
  status) cmd_status;;
  install) cmd_install;;
  *) usage;;
esac

exit 0

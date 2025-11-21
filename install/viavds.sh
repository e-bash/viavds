#!/usr/bin/env bash
# viavds.sh -- unified installer & status tool for viavds
# Version: 0.9.0
# - single-file installer: status | install
# - WSL-safe: will not try to apt-install Docker Engine on WSL/macOS
# - cloudflared installation via GitHub API fallback
# - optional Docker Desktop (Windows) install via winget (requires --yes)
# - mkcert support, nginx vhost generation, hosts file helper
# - non-interactive flags supported: --yes, --dry-run, --verbose
#
# Usage examples:
#   curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh | bash -s -- status
#   curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh | bash -s -- install --dir /home/serge/viavds --webhook-host wh.vianl.loc --tunnel-host ngrok.vianl.loc --mkcert --cf-tunnel --yes
#
set -euo pipefail
IFS=$'\n\t'

# metadata
VER="0.9.0"
SCRIPT_NAME="$(basename "$0")"

# colors
_info(){ printf "\e[1;34m%s\e[0m\n" "$*"; }
_ok(){ printf "\e[1;32m%s\e[0m\n" "$*"; }
_warn(){ printf "\e[1;33m%s\e[0m\n" "$*"; }
_err(){ printf "\e[1;31m%s\e[0m\n" "$*" >&2; }

usage(){
  cat <<EOF
$SCRIPT_NAME v$VER

Usage:
  $SCRIPT_NAME [command] [options]

Commands:
  status                 Run diagnostics (default)
  install                Install viavds (auto-detect local / public)

Options (install/status):
  --dir PATH             Project directory (auto-detect if missing)
  --repo URL             Git repository to clone (default https://github.com/e-bash/viavds.git)
  --branch BRANCH        Repo branch (default main)
  --webhook-host HOST    Hostname for webhook/API endpoint (e.g. wh.example.com)
  --tunnel-host HOST     Hostname for tunnel (e.g. ngrok.example.com)
  --cf-token TOKEN       Cloudflare API token (optional, only for advanced)
  --port N               Service port (default: 14127)
  --mkcert               (local) install and run mkcert to generate certs for webhook-host
  --cf-tunnel            prepare cloudflared config
  --install-docker       allow installing docker (ignored on WSL/macos unless --yes and Windows winget available)
  --install-nginx        allow installing nginx (server mode)
  --yes                  non-interactive: auto-accept prompts and allow certain automated installs
  --dry-run              show actions without executing
  --verbose              verbose mode
  -h, --help             show this help

Examples:
  $SCRIPT_NAME status
  $SCRIPT_NAME install --dir /opt/viavds --webhook-host wh.vianl.loc --tunnel-host ngrok.vianl.loc --mkcert --cf-tunnel --yes

EOF
  exit 0
}

# auto-elevate to root if not root (many ops require root)
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    _err "This script requires root privileges (or sudo)."
    exit 1
  fi
fi

# defaults
CMD="status"
PROJECT_DIR=""
REPO_URL="https://github.com/e-bash/viavds.git"
BRANCH="main"
WEBHOOK_HOST=""
TUNNEL_HOST=""
CF_TOKEN=""
PORT=14127
DO_MKCERT=false
DO_CFTUNNEL=false
ALLOW_INSTALL_DOCKER=false
ALLOW_INSTALL_NGINX=false
ASSUME_YES=false
DRY_RUN=false
VERBOSE=false

# counters
WARN_COUNT=0
ERR_COUNT=0

# Utilities
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
run_cmd(){
  if $DRY_RUN; then
    echo "[DRYRUN] $*"
    return 0
  fi
  if $VERBOSE; then
    _info "+ $*"; eval "$@"
  else
    eval "$@" >/dev/null 2>&1
  fi
}

# pkg manager autodetect
detect_pkg_manager(){
  PKG_MANAGER="unknown"
  PKG_INSTALL_CMD=""
  PKG_UPDATE_CMD=""
  if has_cmd brew; then
    PKG_MANAGER="brew"; PKG_INSTALL_CMD="brew install"; PKG_UPDATE_CMD="brew update"
  elif has_cmd apt-get; then
    PKG_MANAGER="apt"; PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends"; PKG_UPDATE_CMD="apt-get update -qq"
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"; PKG_INSTALL_CMD="dnf install -y -q"; PKG_UPDATE_CMD="dnf makecache -q"
  elif has_cmd yum; then
    PKG_MANAGER="yum"; PKG_INSTALL_CMD="yum install -y -q"; PKG_UPDATE_CMD="yum makecache -q"
  elif has_cmd pacman; then
    PKG_MANAGER="pacman"; PKG_INSTALL_CMD="pacman -S --noconfirm --quiet"; PKG_UPDATE_CMD="pacman -Sy --noconfirm"
  elif has_cmd apk; then
    PKG_MANAGER="apk"; PKG_INSTALL_CMD="apk add --no-cache -q"; PKG_UPDATE_CMD="apk update -q"
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"; PKG_INSTALL_CMD="zypper install -y -q"; PKG_UPDATE_CMD="zypper refresh -q"
  else
    PKG_MANAGER="unknown"
  fi
}

pkg_install(){
  # pkg_install pkg1 pkg2 ...
  if [[ "$PKG_MANAGER" == "unknown" ]]; then
    _warn "Package manager not detected; cannot install packages automatically"
    ((WARN_COUNT++))
    return 1
  fi
  local pkgs=( "$@" )
  _info "Installing: ${pkgs[*]} (using $PKG_MANAGER)"
  if $DRY_RUN; then
    echo "[DRYRUN] $PKG_INSTALL_CMD ${pkgs[*]}"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt|dnf|yum|pacman|apk|zypper) run_cmd $PKG_UPDATE_CMD || true;;
  esac
  if ! run_cmd $PKG_INSTALL_CMD "${pkgs[@]}"; then
    _err "Failed to install packages: ${pkgs[*]}"
    ((ERR_COUNT++)); return 1
  fi
  _ok "Installed: ${pkgs[*]}"
  return 0
}

# find project dir heuristics
PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )
find_project_dir(){
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

# port listening check
is_port_listening(){
  local port="$1"
  if has_cmd ss; then ss -ltn | grep -q ":$port" && return 0 || return 1
  elif has_cmd netstat; then netstat -lnt | grep -q ":$port" && return 0 || return 1
  fi
  return 2
}

# detect environment: local (wsl/mac/other) or public
detect_environment(){
  # WSL detection
  if [[ -f /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo "local (wsl)"; return 0; fi
  # macOS
  if [[ "$(uname -s)" == "Darwin" ]]; then echo "local (macos)"; return 0; fi
  # public detection via public IP
  local pubip=""
  if has_cmd curl; then pubip=$(curl -fsS --max-time 2 https://ifconfig.co || true); fi
  if [[ -z "$pubip" ]]; then echo "local"; return 0; fi
  if [[ "$pubip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then echo "local"; return 0; fi
  echo "public"; return 0
}

# cloudflared download via GitHub API (robust)
cloudflared_download_and_install(){
  local arch
  arch=$(uname -m)
  local file_arch
  case "$arch" in
    x86_64|amd64) file_arch="amd64";;
    aarch64|arm64) file_arch="arm64";;
    armv7l) file_arch="armv7";;
    *) file_arch="amd64";;
  esac
  _info "Detected arch: $arch -> asset arch: $file_arch"

  # need jq and curl
  for c in curl jq; do
    if ! has_cmd "$c"; then
      if [[ "$PKG_MANAGER" != "unknown" ]]; then
        pkg_install "$c" || _warn "Failed to install $c"
      else
        _warn "$c is required to download cloudflared automatically. Please install it manually."
        return 1
      fi
    fi
  done

  _info "Fetching latest release data from GitHub API..."
  local api_json
  if ! api_json=$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest"); then
    _err "Failed to fetch release metadata from GitHub API"
    return 1
  fi

  local asset_url
  # prefer tgz assets with linux and arch in name
  asset_url=$(printf "%s" "$api_json" | jq -r --arg arch "$file_arch" \
    '.assets[] | select(.name|test("linux.*" + $arch) and (.name|test("\\.tgz$") or .name|test("\\.tar.gz$"))) | .browser_download_url' \
    | head -n1)

  if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
    _warn "No matching tgz asset found by API (arch=$file_arch). Listing available assets:"
    printf "%s\n" "$api_json" | jq -r '.assets[] | "\(.name) \(.browser_download_url)"'
    ((WARN_COUNT++))
    return 1
  fi

  _info "Downloading cloudflared asset: $asset_url"
  local tmpf="/tmp/cloudflared-$$.tgz"
  if ! curl -fsSL "$asset_url" -o "$tmpf"; then
    _err "Download failed for $asset_url"
    rm -f "$tmpf" || true
    return 1
  fi

  _info "Extracting and installing cloudflared to /usr/local/bin"
  tar -C /tmp -xzf "$tmpf"
  if [[ -f /tmp/cloudflared ]]; then
    mv /tmp/cloudflared /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    rm -f "$tmpf"
    _ok "cloudflared installed to /usr/local/bin/cloudflared"
    return 0
  else
    _err "Unexpected archive format: cloudflared binary not found after extract"
    ls -lah /tmp | sed -n '1,120p' || true
    return 1
  fi
}

# mkcert installation helpers
install_mkcert(){
  if has_cmd mkcert; then _ok "mkcert already installed"; return 0; fi
  case "$PKG_MANAGER" in
    brew)
      run_cmd brew install mkcert nss || true
      ;;
    apt)
      pkg_install libnss3-tools || true
      local url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-$(uname -m)-linux"
      run_cmd curl -fsSL -o /usr/local/bin/mkcert "$url" || true
      run_cmd chmod +x /usr/local/bin/mkcert || true
      ;;
    *)
      _warn "mkcert install for $PKG_MANAGER not implemented; please install mkcert manually"
      return 1
      ;;
  esac
  _ok "mkcert installed (or placed in /usr/local/bin)"
}

generate_mkcert_for_host(){
  local host="$1"
  local certdir="/etc/viavds/certs"
  mkdir -p "$certdir"
  run_cmd mkcert -install || true
  run_cmd mkcert -key-file "$certdir/$host-key.pem" -cert-file "$certdir/$host.pem" "$host" || true
  _ok "mkcert: certificate generated for $host in $certdir"
}

# nginx config helpers
configure_nginx_for_host(){
  local host="$1"; local proxy_port="$2"
  local confdir="/etc/nginx/sites-available"; local enabled="/etc/nginx/sites-enabled"
  mkdir -p "$confdir" "$enabled"
  local conf="$confdir/viavds-$host.conf"
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
  ln -sf "$conf" "$enabled/viavds-$host.conf"
  run_cmd nginx -t || true
  run_cmd systemctl reload nginx || true
  _ok "nginx configured for $host -> 127.0.0.1:$proxy_port"
}

configure_nginx_with_tls(){
  local host="$1"; local proxy_port="$2"
  local confdir="/etc/nginx/sites-available"; local enabled="/etc/nginx/sites-enabled"; local certdir="/etc/viavds/certs"
  mkdir -p "$confdir" "$enabled" "$certdir"
  local conf="$confdir/viavds-$host.conf"
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
  ln -sf "$conf" "$enabled/viavds-$host.conf"
  run_cmd nginx -t || true
  run_cmd systemctl reload nginx || true
  _ok "nginx with TLS configured for $host"
}

# prepare cloudflared config skeleton
prepare_cloudflared_config(){
  local tunnel_name="$1"; local tunnel_port="$2"; local hostname="$3"
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/config.yml <<EOF
tunnel: $tunnel_name
credentials-file: /etc/cloudflared/$tunnel_name.json

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$tunnel_port
  - service: http_status:404
EOF
  chown -R root:root /etc/cloudflared || true
  _ok "Prepared /etc/cloudflared/config.yml ingress for $hostname -> 127.0.0.1:$tunnel_port"
}

# hosts helper (adds local hosts so wh.vianl.loc resolves locally)
add_hosts_entry(){
  local host="$1"
  local ip="${2:-127.0.0.1}"
  if grep -qE "^[^#]*\s+$host(\s|$)" /etc/hosts 2>/dev/null; then
    _info "Host $host already present in /etc/hosts"
    return 0
  fi
  echo "$ip $host" >> /etc/hosts
  _ok "Added /etc/hosts entry: $ip $host"
}

# docker checks
check_docker(){
  if ! has_cmd docker; then
    _warn "docker: not installed"
    ((WARN_COUNT++))
    DOCKER_PRESENT=false; DOCKER_RUNNING=false; return 1
  fi
  DOCKER_PRESENT=true
  if pgrep -x dockerd >/dev/null 2>&1 || (has_cmd systemctl && systemctl is-active --quiet docker); then
    _ok "docker daemon: running"
    DOCKER_RUNNING=true
  else
    _warn "docker daemon: not running"
    DOCKER_RUNNING=false
    ((WARN_COUNT++))
  fi
}

check_compose(){
  if has_cmd docker && docker compose version >/dev/null 2>&1; then _ok "docker compose: present"
  else _warn "docker compose (v2) not present"; ((WARN_COUNT++)); fi
}

check_viavds_container(){
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then
    _warn "viavds container: check skipped (docker not present)"; ((WARN_COUNT++)); return
  fi
  local info
  info=$(docker ps --filter "name=viavds" --format "name={{.Names}} status={{.Status}} ports={{.Ports}}" | head -n1 || true)
  if [[ -n "$info" ]]; then _ok "viavds container: $info"; return 0; fi
  info=$(docker ps -a --filter "name=viavds" --format "name={{.Names}} status={{.Status}}" | head -n1 || true)
  if [[ -n "$info" ]]; then _warn "viavds container present but stopped: $info"; ((WARN_COUNT++)); else _warn "viavds container not found"; ((WARN_COUNT++)); fi
}

check_images(){
  local dir="$1"
  if [[ -z "$dir" || ! -f "$dir/docker-compose.yml" ]]; then _warn "Images: skip (no compose file)"; ((WARN_COUNT++)); return; fi
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then _warn "Images: skipped (docker not present)"; ((WARN_COUNT++)); return; fi
  local imgs; imgs=( $(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true) )
  if [[ ${#imgs[@]} -eq 0 ]]; then _warn "Images: none declared in compose"; ((WARN_COUNT++)); return; fi
  for im in "${imgs[@]}"; do
    if docker image inspect "$im" >/dev/null 2>&1; then _ok "Image present: $im"; else _warn "Image missing: $im"; ((WARN_COUNT++)); fi
  done
}

check_networks_volumes(){
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then _warn "Networks & volumes: skipped (docker not present)"; ((WARN_COUNT++)); return; fi
  if [[ "${DOCKER_RUNNING:-false}" != true ]]; then _warn "Networks & volumes: docker not running; skip detailed checks"; ((WARN_COUNT++)); return; fi
  _info "Docker networks:"; docker network ls --format "  {{.Name}}" || true
  _info "Docker volumes:"; docker volume ls --format "  {{.Name}}" || true
}

check_nginx(){
  if has_cmd nginx; then
    if nginx -t >/dev/null 2>&1; then _ok "nginx config OK"; else _err "nginx config error"; ((ERR_COUNT++)); fi
  else _warn "nginx: not installed"; ((WARN_COUNT++)); fi
}

check_cloudflared(){
  if has_cmd cloudflared; then
    cloudflared --version 2>/dev/null || true
    if systemctl is-active --quiet cloudflared 2>/dev/null; then _ok "cloudflared: running"; else _warn "cloudflared: installed but not running"; ((WARN_COUNT++)); fi
  else _warn "cloudflared: not installed"; ((WARN_COUNT++)); fi
}

check_webhook(){
  if is_port_listening "$PORT"; then _ok "port $PORT: listening"; else _warn "port $PORT: not listening"; ((WARN_COUNT++)); fi
  if has_cmd curl; then
    if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then _ok "health endpoint OK"; else _warn "health endpoint not responding"; ((WARN_COUNT++)); fi
  else _warn "curl missing: cannot test health endpoint"; ((WARN_COUNT++)); fi
}

# installer main routine
do_install(){
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  local ENV
  ENV=$(detect_environment)
  _info "Environment detected: $ENV"

  # if local WSL or macOS -> avoid apt-installing docker engine
  if [[ "$ENV" == local* ]]; then
    _info "Local environment detected ($ENV) — Docker Engine installation via package manager will be skipped."
    if $ALLOW_INSTALL_DOCKER; then
      _warn "--install-docker was requested but will be skipped for local environment. On WSL/macOS please install Docker Desktop and enable integration."
    fi
  fi

  # ensure basic tools
  pkg_install curl git ca-certificates jq || true
  pkg_install qrencode || true

  # cloudflared install (if requested or missing)
  if ! has_cmd cloudflared; then
    if cloudflared_download_and_install; then _ok "cloudflared installed"; else _warn "cloudflared install failed (see above)"; fi
  else _ok "cloudflared present"; fi

  # mkcert
  if $DO_MKCERT; then
    install_mkcert || _warn "mkcert install failed"
  fi

  # project dir
  if [[ -z "$PROJECT_DIR" ]]; then PROJECT_DIR="/opt/viavds"; fi
  mkdir -p "$PROJECT_DIR"

  # clone repo (prefer https)
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    _info "Project already present at $PROJECT_DIR"
  else
    _info "Cloning repository $REPO_URL -> $PROJECT_DIR"
    if ! run_cmd git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$PROJECT_DIR"; then
      _warn "git clone failed; continuing if you have local sources"
    fi
  fi

  # docker sanity check
  if ! has_cmd docker; then
    if [[ "$ENV" == "local (wsl)" ]] && $ASSUME_YES; then
      # try to install Docker Desktop on Windows using winget if available (best-effort)
      if has_cmd powershell.exe && (powershell.exe -Command "Get-Command winget" >/dev/null 2>&1); then
        _info "Attempting to install Docker Desktop on Windows via winget (requires Windows & winget). This may take a while."
        # run winget via powershell (not automatic if interactive required)
        if $DRY_RUN; then
          echo "[DRYRUN] powershell.exe -Command 'winget install -e --id Docker.DockerDesktop -h'"
        else
          powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "winget install -e --id Docker.DockerDesktop -h" || _warn "winget install failed or requires user interaction"
          # after install, require user to enable WSL integration
          _info "Please enable WSL integration in Docker Desktop settings, then run 'wsl --shutdown' and retry."
        fi
      else
        _warn "Automatic Docker Desktop install via winget is not available. Please install Docker Desktop on Windows manually."
      fi
    else
      _warn "Docker is not installed. On public servers we can attempt installation with --install-docker if desired."
      ((WARN_COUNT++))
    fi
  else
    _ok "docker present"
  fi

  # docker compose note
  if has_cmd docker && ! docker compose version >/dev/null 2>&1; then _warn "docker compose v2 plugin not available"; fi

  # mkcert cert generation and nginx config
  if $DO_MKCERT && [[ -n "$WEBHOOK_HOST" ]]; then
    generate_mkcert_for_host "$WEBHOOK_HOST" || _warn "mkcert failed"
    configure_nginx_with_tls "$WEBHOOK_HOST" "$PORT" || _warn "nginx TLS config failed"
    add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"
  elif [[ -n "$WEBHOOK_HOST" ]]; then
    if has_cmd nginx; then configure_nginx_for_host "$WEBHOOK_HOST" "$PORT"; add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"; else _warn "nginx not installed; skipping vhost creation"; fi
  fi

  if [[ -n "$TUNNEL_HOST" ]]; then
    local tname="viavds-$(hostname -s)-$(date +%s)"
    prepare_cloudflared_config "$tname" "$PORT" "$TUNNEL_HOST"
    _info "Prepared cloudflared config. Next interactive steps:"
    echo
    echo "  1) As a non-root user run: cloudflared tunnel login"
    echo "     Use activate_url <url> to print activation URL + QR in terminal."
    echo
    echo "  2) Then create tunnel and route DNS:"
    echo "     cloudflared tunnel create $tname"
    echo "     cloudflared tunnel route dns $tname $TUNNEL_HOST"
    echo
    echo "  3) Move credential JSON to /etc/cloudflared and enable service:"
    echo "     sudo mv ~/.cloudflared/$tname.json /etc/cloudflared/$tname.json"
    echo "     sudo systemctl enable --now cloudflared"
    echo
  fi

  # docker-compose up if we have docker and compose and compose file
  if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    if has_cmd docker && docker compose version >/dev/null 2>&1; then
      _info "Starting docker compose in $PROJECT_DIR"
      run_cmd bash -c "cd $PROJECT_DIR && docker compose up -d --build" || _warn "docker compose up failed"
    else
      _warn "Skipping docker compose start: docker/docker-compose not ready"
    fi
  else
    _warn "docker-compose.yml not found in $PROJECT_DIR; skipping docker compose start"
  fi

  _ok "Install sequence finished (check summary below)."
}

# status command
cmd_status(){
  _info "=== viavds STATUS CHECK ==="
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  local ENV; ENV=$(detect_environment)
  _info "Environment: $ENV"
  for c in curl jq git; do
    if has_cmd "$c"; then _ok "$c: ok"; else _warn "$c: missing"; ((WARN_COUNT++)); fi
  done
  check_docker || true
  check_compose
  PROJECT_DIR=$(find_project_dir || true)
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

cmd_install(){
  _info "=== viavds INSTALL ==="
  do_install
  echo
  _info "FINAL SUMMARY:"
  _info "webhook-host: ${WEBHOOK_HOST:-not set}"
  _info "tunnel-host: ${TUNNEL_HOST:-not set}"
  _info "project dir: ${PROJECT_DIR:-not set}"
  if (( ERR_COUNT > 0 )); then _err "Errors: $ERR_COUNT (see logs)"; fi
  if (( WARN_COUNT > 0 )); then _warn "Warnings: $WARN_COUNT"; else _ok "No warnings"; fi
}

# simple activate_url helper (prints url + QR via qrencode if present)
activate_url(){
  local url
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then url="$1"; else url="$(cat - 2>/dev/null)"; fi
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  printf '\nДля активации сервиса перейдите по ссылке %s\n\n' "$url"
  if has_cmd qrencode; then
    qrencode -o - -t UTF8 "$url" 2>/dev/null || qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null || true
    printf '\n'
  fi
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
    --cf-tunnel) DO_CFTUNNEL=true; shift;;
    --install-docker) ALLOW_INSTALL_DOCKER=true; shift;;
    --install-nginx) ALLOW_INSTALL_NGINX=true; shift;;
    --yes) ASSUME_YES=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --verbose) VERBOSE=true; shift;;
    -h|--help) usage;;
    *) _err "Unknown arg: $1"; usage;;
  esac
done

case "$CMD" in
  status) cmd_status;;
  install) cmd_install;;
  *) usage;;
esac

exit 0

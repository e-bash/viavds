#!/usr/bin/env bash
# viavds.sh -- diagnostics & unified installer for viavds
# v0.5.0
set -euo pipefail
IFS=$'\n\t'

VER="0.5.0"
SCRIPT_NAME=$(basename "$0")

# Colors
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
  --cf-token TOKEN       Cloudflare API token (optional)
  --cf-account ID        Cloudflare account id (optional)
  --port N               Service port (default: 14127)
  --mkcert               (local) install and run mkcert to generate certs for webhook-host
  --cf-tunnel            prepare cloudflared client (local) or service (public)
  --install-docker       allow installing docker if missing
  --install-nginx        allow installing nginx if missing
  --yes                  non-interactive: auto-accept prompts
  --dry-run              show actions without executing
  --verbose              verbose mode
  -h, --help             show this help
EOF
  exit 0
}

# Auto-elevate
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    _err "This script requires root privileges (or sudo)."
    exit 1
  fi
fi

# Defaults
CMD="status"
PROJECT_DIR=""
REPO_URL="https://github.com/e-bash/viavds.git"
BRANCH="main"
WEBHOOK_HOST=""
TUNNEL_HOST=""
CF_TOKEN=""
CF_ACCOUNT=""
PORT=14127
DO_MKCERT=false
DO_CFTUNNEL=false
ALLOW_INSTALL_DOCKER=false
ALLOW_INSTALL_NGINX=false
DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# Counters
WARN_COUNT=0
ERR_COUNT=0

# Helpers
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
run_cmd(){
  if $DRY_RUN; then
    echo "[DRYRUN] $*"
    return 0
  fi
  if $VERBOSE; then
    echo "+ $*"
    eval "$@"
  else
    eval "$@" >/dev/null 2>&1 || return $?
  fi
}

PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )

# Activate URL helper (prints URL + QR if qrencode available)
activate_url() {
  local url
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then url="$1"; else url="$(cat - 2>/dev/null)"; fi
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  printf '\nДля активации сервиса перейдите по ссылке %s\n\n' "$url"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o - -t UTF8 "$url" 2>/dev/null || qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null
    printf '\n'
  fi
}

# pkg manager detection (sets PKG_MANAGER, PKG_INSTALL_CMD, PKG_UPDATE_CMD, PKG_QUIET_OPTS)
detect_pkg_manager(){
  PKG_MANAGER="unknown"
  PKG_INSTALL_CMD=""
  PKG_UPDATE_CMD=""
  PKG_QUIET_INSTALL=""
  if has_cmd brew; then
    PKG_MANAGER="brew"
    PKG_INSTALL_CMD="brew install"
    PKG_UPDATE_CMD="brew update"
    PKG_QUIET_INSTALL=""
  elif has_cmd apt-get; then
    PKG_MANAGER="apt"
    PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends"
    PKG_UPDATE_CMD="apt-get update -qq"
    PKG_QUIET_INSTALL="-y -qq"
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"
    PKG_INSTALL_CMD="dnf install -y -q"
    PKG_UPDATE_CMD="dnf makecache -q"
  elif has_cmd yum; then
    PKG_MANAGER="yum"
    PKG_INSTALL_CMD="yum install -y -q"
    PKG_UPDATE_CMD="yum makecache -q"
  elif has_cmd pacman; then
    PKG_MANAGER="pacman"
    PKG_INSTALL_CMD="pacman -S --noconfirm --quiet"
    PKG_UPDATE_CMD="pacman -Sy --noconfirm"
  elif has_cmd apk; then
    PKG_MANAGER="apk"
    PKG_INSTALL_CMD="apk add --no-cache -q"
    PKG_UPDATE_CMD="apk update -q"
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"
    PKG_INSTALL_CMD="zypper install -y -q"
    PKG_UPDATE_CMD="zypper refresh -q"
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
  # update first when apt/dnf/pacman
  case "$PKG_MANAGER" in
    apt|dnf|yum|pacman|apk|zypper)
      run_cmd $PKG_UPDATE_CMD || true
      ;;
  esac
  if ! run_cmd $PKG_INSTALL_CMD "${pkgs[@]}"; then
    _err "Failed to install packages: ${pkgs[*]}"
    ((ERR_COUNT++))
    return 1
  fi
  _ok "Installed: ${pkgs[*]}"
  return 0
}

# find project dir
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
  # search upward
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

is_port_listening(){
  local port="$1"
  if has_cmd ss; then
    ss -ltn | grep -q ":$port" && return 0 || return 1
  elif has_cmd netstat; then
    netstat -lnt | grep -q ":$port" && return 0 || return 1
  fi
  return 2
}

# detect env (wsl/local/public)
detect_environment(){
  # WSL
  if [[ -f /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    echo "local (wsl)"
    return 0
  fi
  # macOS
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "local (macos)"; return 0
  fi
  local pubip=""
  if has_cmd curl; then
    pubip=$(curl -fsS --max-time 2 https://ifconfig.co || true)
  fi
  if [[ -z "$pubip" ]]; then
    echo "local"; return 0
  fi
  # private ranges -> consider local
  if [[ "$pubip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then
    echo "local"; return 0
  fi
  echo "public"; return 0
}

# --------- checks (status) ----------
check_basic_tools(){
  for cmd in curl jq git; do
    if has_cmd "$cmd"; then
      _ok "$cmd: ok"
    else
      _warn "$cmd: missing"
      ((WARN_COUNT++))
    fi
  done
}

check_docker(){
  if ! has_cmd docker; then
    _warn "docker: not installed"
    ((WARN_COUNT++))
    DOCKER_PRESENT=false; DOCKER_RUNNING=false; return 1
  fi
  DOCKER_PRESENT=true
  docker --version 2>/dev/null || true
  if has_cmd systemctl && systemctl is-active --quiet docker; then
    _ok "docker daemon: running"
    DOCKER_RUNNING=true
  else
    if pgrep -x dockerd >/dev/null 2>&1; then
      _ok "docker daemon: running (no systemd)"
      DOCKER_RUNNING=true
    else
      _warn "docker daemon: not running"
      DOCKER_RUNNING=false
      ((WARN_COUNT++))
    fi
  fi
}

check_compose(){
  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    _ok "docker compose: present"
  else
    _warn "docker compose (v2) not present"
    ((WARN_COUNT++))
  fi
}

check_viavds_container(){
  if ! $DOCKER_PRESENT; then
    _warn "viavds container: check skipped (docker not present)"
    ((WARN_COUNT++)); return
  fi
  local info
  info=$(docker ps --filter "name=viavds" --format "name={{.Names}} status={{.Status}} ports={{.Ports}}" | head -n1 || true)
  if [[ -n "$info" ]]; then
    _ok "viavds container: $info"
  else
    info=$(docker ps -a --filter "name=viavds" --format "name={{.Names}} status={{.Status}}" | head -n1 || true)
    if [[ -n "$info" ]]; then
      _warn "viavds container present but stopped: $info"
      ((WARN_COUNT++))
    else
      _warn "viavds container not found"
      ((WARN_COUNT++))
    fi
  fi
}

check_images(){
  local dir="$1"
  if [[ -z "$dir" ]]; then
    _warn "Images: skip (no compose file)"
    ((WARN_COUNT++)); return
  fi
  if ! $DOCKER_PRESENT; then
    _warn "Images: skipped (docker not present)"; ((WARN_COUNT++)); return
  fi
  # get images from compose
  local imgs; imgs=( $(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true) )
  if [[ ${#imgs[@]} -eq 0 ]]; then
    _warn "Images: none declared in compose"
    ((WARN_COUNT++)); return
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

check_networks_volumes(){
  if ! $DOCKER_PRESENT; then
    _warn "Networks & volumes: skipped (docker not present)"; ((WARN_COUNT++)); return
  fi
  if ! $DOCKER_RUNNING; then
    _warn "Networks & volumes: docker not running; skip detailed checks"; ((WARN_COUNT++)); return
  fi
  _info "Docker networks:"
  docker network ls --format "  {{.Name}}" || true
  _info "Docker volumes:"
  docker volume ls --format "  {{.Name}}" || true
}

check_nginx(){
  if has_cmd nginx; then
    if nginx -t >/dev/null 2>&1; then _ok "nginx config OK"; else _err "nginx config error"; ((ERR_COUNT++)); fi
  else
    _warn "nginx: not installed"; ((WARN_COUNT++))
  fi
}

check_cloudflared(){
  if has_cmd cloudflared; then
    cloudflared --version 2>/dev/null || true
    if systemctl is-active --quiet cloudflared; then _ok "cloudflared: running"; else _warn "cloudflared: installed but not running"; ((WARN_COUNT++)); fi
  else
    _warn "cloudflared: not installed"; ((WARN_COUNT++))
  fi
}

check_webhook(){
  if is_port_listening "$PORT"; then _ok "port $PORT: listening"; else _warn "port $PORT: not listening"; ((WARN_COUNT++)); fi
  if has_cmd curl; then
    if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then _ok "health endpoint OK"; else _warn "health endpoint not responding"; ((WARN_COUNT++)); fi
  else
    _warn "curl missing: cannot test health endpoint"; ((WARN_COUNT++))
  fi
}

# ---------- install helpers ----------
install_cloudflared_binary(){
  # Download latest cloudflared binary and install to /usr/local/bin
  _info "Installing cloudflared binary..."
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="amd64";;
    aarch64|arm64) arch="arm64";;
    *) arch="amd64";;
  esac
  local tmpdir
  tmpdir=$(mktemp -d)
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.tgz"
  if ! run_cmd curl -fsSL "$url" -o "$tmpdir/cloudflared.tgz"; then
    _err "Failed to download cloudflared from $url"; ((ERR_COUNT++)); rm -rf "$tmpdir"; return 1
  fi
  run_cmd tar -C "$tmpdir" -xzf "$tmpdir/cloudflared.tgz" || true
  run_cmd mv "$tmpdir/cloudflared" /usr/local/bin/ || true
  run_cmd chmod +x /usr/local/bin/cloudflared || true
  rm -rf "$tmpdir"
  _ok "cloudflared installed to /usr/local/bin/cloudflared"
}

install_mkcert(){
  if has_cmd mkcert; then _ok "mkcert already installed"; return 0; fi
  _info "Installing mkcert..."
  case "$PKG_MANAGER" in
    brew) run_cmd brew install mkcert nss || true;;
    apt) pkg_install libnss3-tools || true; run_cmd wget -qO /tmp/mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-$(uname -m)-linux && chmod +x /tmp/mkcert && mv /tmp/mkcert /usr/local/bin/mkcert || true;;
    *) _warn "Please install mkcert manually for your OS"; return 1;;
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

configure_nginx_for_host(){
  local host="$1"
  local proxy_port="$2"
  local confdir="/etc/nginx/sites-available"
  local enabled="/etc/nginx/sites-enabled"
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
  local host="$1"
  local proxy_port="$2"
  local confdir="/etc/nginx/sites-available"
  local enabled="/etc/nginx/sites-enabled"
  local certdir="/etc/viavds/certs"
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

# ---------- cloudflared helper: prepare config (not automatic CF API) ----------
prepare_cloudflared_config(){
  local tunnel_name="$1"
  local tunnel_port="$2"
  local hostname="$3"
  mkdir -p /etc/cloudflared
  # minimal config.yml with ingress rule
  cat > /etc/cloudflared/config.yml <<EOF
tunnel: $tunnel_name
credentials-file: /etc/cloudflared/$tunnel_name.json

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$tunnel_port
  - service: http_status:404
EOF
  _ok "Prepared /etc/cloudflared/config.yml ingress for $hostname -> 127.0.0.1:$tunnel_port"
  chown -R root:root /etc/cloudflared || true
}

# ---------- installer main ----------
do_install(){
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"

  local ENV
  ENV=$(detect_environment)
  _info "Environment detected: $ENV"

  # install minimal tools
  pkg_install curl git ca-certificates jq || true
  # qrencode required per your request
  pkg_install qrencode || true

  # install docker if allowed/required
  if ! has_cmd docker; then
    if $ALLOW_INSTALL_DOCKER || $ASSUME_YES; then
      _info "Installing docker (auto)..."
      case "$PKG_MANAGER" in
        apt)
          run_cmd apt-get update -qq || true
          run_cmd apt-get install -y -qq ca-certificates gnupg lsb-release || true
          run_cmd mkdir -p /etc/apt/keyrings || true
          run_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
          run_cmd echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null || true
          run_cmd apt-get update -qq || true
          run_cmd apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
          ;;
        brew)
          run_cmd brew install --cask docker || true
          ;;
        apk)
          pkg_install docker docker-compose || true
          ;;
        *)
          _warn "Automatic docker install not implemented for $PKG_MANAGER; please install docker manually"
          ;;
      esac
      run_cmd systemctl enable --now docker || true
    else
      _warn "docker not installed; use --install-docker or --yes to allow installation"
      ((WARN_COUNT++))
    fi
  else
    _ok "docker already present"
  fi

  # docker compose
  if ! has_cmd docker || ! docker compose version >/dev/null 2>&1; then
    _warn "docker compose missing or not functional; ensure docker compose v2 plugin is installed"
    ((WARN_COUNT++))
  fi

  # mkcert (local only)
  if $DO_MKCERT; then
    install_mkcert || _warn "mkcert install failed"
  fi

  # install cloudflared binary
  if ! has_cmd cloudflared; then
    install_cloudflared_binary || _warn "cloudflared install failed"
  else
    _ok "cloudflared already installed"
  fi

  # clone repo if needed
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ ! -d "$PROJECT_DIR" ]]; then
      mkdir -p "$PROJECT_DIR"
    fi
  else
    # default install path:
    PROJECT_DIR="/opt/viavds"
  fi

  if [[ -d "$PROJECT_DIR/.git" ]]; then
    _info "Project already cloned at $PROJECT_DIR"
  else
    _info "Cloning repository $REPO_URL -> $PROJECT_DIR"
    run_cmd git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$PROJECT_DIR" || _warn "git clone failed"
  fi

  # mkcert certificates generation for webhook-host (local)
  if $DO_MKCERT && [[ -n "$WEBHOOK_HOST" ]]; then
    generate_mkcert_for_host "$WEBHOOK_HOST" || _warn "mkcert generation failed"
    configure_nginx_with_tls "$WEBHOOK_HOST" "$PORT" || _warn "nginx TLS config failed"
  elif [[ -n "$WEBHOOK_HOST" ]]; then
    configure_nginx_for_host "$WEBHOOK_HOST" "$PORT" || _warn "nginx config failed"
  fi

  # cloudflared tunnel prepare
  if [[ -n "$TUNNEL_HOST" ]]; then
    # We'll prepare config and then instruct user to 'cloudflared tunnel create' and 'cloudflared tunnel route dns'
    local tname="viavds-$(hostname -s)-$(date +%s)"
    prepare_cloudflared_config "$tname" "$PORT" "$TUNNEL_HOST"
    _info "To create and run the tunnel, run (as non-root user with cloudflared):"
    echo
    echo "  # Login (interactive - will open browser / give activation URL):"
    echo "  cloudflared tunnel login"
    echo
    echo "  # Create tunnel (example):"
    echo "  cloudflared tunnel create $tname"
    echo
    echo "  # Move credentials to /etc/cloudflared/ and configure systemd, or use cloudflared service install"
    echo "  # Example to route DNS (requires cloudflared login & permissions):"
    echo "  cloudflared tunnel route dns $tname $TUNNEL_HOST"
    echo
    # we can capture login URL by running cloudflared login in - but login normally attempts to open browser.
    if ! has_cmd cloudflared; then
      _warn "cloudflared CLI not found to perform login"
    else
      _info "You can run cloudflared login now to get an activation link (will print URL)."
      _info "If you want me to run it now, run the script with --yes and interactive shell."
    fi
    # print an activation URL hint (if cloudflared provides one interactive)
    _info "When cloudflared prints an activation URL, use the following to display QR:"
    echo "  activate_url <url>"
  fi

  # run docker compose
  if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    _info "Starting docker-compose in $PROJECT_DIR"
    run_cmd bash -c "cd $PROJECT_DIR && docker compose up -d --build" || _warn "docker compose up failed"
  else
    _warn "docker-compose.yml not found in $PROJECT_DIR; skipping docker compose start"
  fi

  _ok "Install sequence finished (check summary below)."
}

# ---------- main status and install ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|install) CMD="$1"; shift;;
    --dir) PROJECT_DIR="$2"; shift 2;;
    --repo) REPO_URL="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --webhook-host) WEBHOOK_HOST="$2"; shift 2;;
    --tunnel-host) TUNNEL_HOST="$2"; shift 2;;
    --cf-token) CF_TOKEN="$2"; shift 2;;
    --cf-account) CF_ACCOUNT="$2"; shift 2;;
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

cmd_status(){
  _info "=== viavds status ==="
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  ENV=$(detect_environment)
  _info "Environment: $ENV"
  check_basic_tools
  check_docker
  check_compose
  PROJECT_DIR=$(find_project_dir || true)
  _info "Project dir: ${PROJECT_DIR:-not found}"
  check_viavds_container
  check_images "$PROJECT_DIR"
  check_networks_volumes
  check_nginx
  check_cloudflared
  check_webhook
  # summary
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
  _info "=== viavds install ==="
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  do_install
  # final summary
  echo
  _info "FINAL SUMMARY:"
  _info "webhook-host: ${WEBHOOK_HOST:-not set}"
  _info "tunnel-host: ${TUNNEL_HOST:-not set}"
  _info "project dir: ${PROJECT_DIR}"
  if (( ERR_COUNT > 0 )); then _err "Errors: $ERR_COUNT (see logs)"; fi
  if (( WARN_COUNT > 0 )); then _warn "Warnings: $WARN_COUNT"; else _ok "No warnings"; fi
}

case "$CMD" in
  status) cmd_status;;
  install) cmd_install;;
  *) usage;;
esac

exit 0

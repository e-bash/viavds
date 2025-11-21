#!/usr/bin/env bash
# viavds.sh -- unified installer & status tool for viavds
# Version: 1.2.0
# Key fixes:
#  - retry logic for apt update/install and downloads (mirror sync handling)
#  - robust verification of downloaded binaries (mkcert, cloudflared)
#  - avoid root-owned project files: git clone runs as invoking user
#  - helpful guidance and optional auto usermod docker group
#  - print all command output (no >/dev/null)
#  - better handling of log-file permission fallback
#
set -euo pipefail
IFS=$'\n\t'

VER="1.2.0"
SCRIPT_NAME="$(basename "$0")"

########################################
# logging / output
LOG_FILE=""
VERBOSE=false
DRY_RUN=false
SUDO_USER="$USER"
_info(){ printf "\e[1;34m%s\e[0m\n" "$*"; }
_ok(){ printf "\e[1;32m%s\e[0m\n" "$*"; }
_warn(){ printf "\e[1;33m%s\e[0m\n" "$*"; }
_err(){ printf "\e[1;31m%s\e[0m\n" "$*" >&2; }

log() {
  local msg="$*"
  printf '%s\n' "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$msg" >>"$LOG_FILE" 2>&1 || true
  fi
}

run_cmd() {
  # Execute a command showing it first if verbose. Do not hide stdout/stderr.
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
    eval "$cmd"
    return $?
  fi
}

# Retry helper: run command up to N times with delay
retry() {
  # retry <tries> <delay_seconds> <command...>
  local tries="$1"; shift
  local delay="$1"; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    if [[ $i -ge $tries ]]; then
      return 1
    fi
    log "Command failed, retrying in ${delay}s... ($i/$tries)"
    sleep "$delay"
  done
  return 0
}

########################################
# defaults & flags
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
# helper: detect WSL
is_wsl() {
  [[ -f /proc/version ]] && grep -qi 'microsoft' /proc/version 2>/dev/null || return 1
}

# helper: run a command as the original invoking (non-root) user if script run with sudo
run_as_user() {
  if [[ -n "${SUDO_USER-}" && "$(id -u)" -eq 0 ]]; then
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
detect_pkg_manager() {
  PKG_MANAGER="unknown"
  if command -v brew >/dev/null 2>&1; then
    PKG_MANAGER="brew"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  fi
  log "Detected package manager: $PKG_MANAGER"
}

pkg_install() {
  local pkgs=( "$@" )
  if [[ "$PKG_MANAGER" == "unknown" ]]; then
    _warn "No package manager detected; cannot auto-install: ${pkgs[*]}"
    ((WARN_COUNT++)); return 1
  fi
  _info "Installing: ${pkgs[*]} (using $PKG_MANAGER)"
  case "$PKG_MANAGER" in
    apt)
      # retry apt-get update due to mirror sync issues
      retry 3 5 sudo apt-get update || _warn "apt-get update failed after retries"
      retry 3 5 sudo apt-get install -y "${pkgs[@]}" || { _err "Failed apt-get install ${pkgs[*]}"; ((ERR_COUNT++)); return 1; }
      ;;
    dnf) retry 3 5 sudo dnf install -y "${pkgs[@]}" || { _err "dnf install failed"; ((ERR_COUNT++)); return 1; } ;;
    yum) retry 3 5 sudo yum install -y "${pkgs[@]}" || { _err "yum install failed"; ((ERR_COUNT++)); return 1; } ;;
    pacman) retry 3 5 sudo pacman -S --noconfirm "${pkgs[@]}" || { _err "pacman install failed"; ((ERR_COUNT++)); return 1; } ;;
    apk) retry 3 5 sudo apk add --no-cache "${pkgs[@]}" || { _err "apk add failed"; ((ERR_COUNT++)); return 1; } ;;
    brew) run_cmd "brew install ${pkgs[*]}" || true ;;
  esac
  _ok "Installed: ${pkgs[*]}"
}

########################################
# project dir heuristics
PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )
find_project_dir() {
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then echo "$PROJECT_DIR"; return 0; else _warn "--dir provided but no docker-compose.yml found"; ((WARN_COUNT++)); fi
  fi
  for d in "${PROJECT_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" ]]; then echo "$(cd "$d" && pwd)"; return 0; fi
  done
  local cur="$PWD"
  while [[ "$cur" != "/" ]]; do
    if [[ -f "$cur/docker-compose.yml" ]]; then echo "$cur"; return 0; fi
    cur=$(dirname "$cur")
  done
  echo ""; return 1
}

########################################
is_port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then ss -ltn | grep -qE "[:.]${port}\>" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then netstat -lnt | grep -qE "[:.]${port}\>" && return 0 || return 1
  fi
  return 2
}

detect_environment() {
  if is_wsl; then echo "local (wsl)"; return 0; fi
  if [[ "$(uname -s)" == "Darwin" ]]; then echo "local (macos)"; return 0; fi
  local pubip=""
  if command -v curl >/dev/null 2>&1; then pubip=$(curl -fsS --max-time 3 https://ifconfig.co || true); fi
  if [[ -z "$pubip" ]]; then echo "local"; return 0; fi
  if [[ "$pubip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then echo "local"; return 0; fi
  echo "public"; return 0
}

########################################
# download-and-verify helper
download_and_verify() {
  # download_and_verify <url> <tmpfile> <min_bytes>
  local url="$1"; local tmpf="$2"; local min_bytes="${3:-10240}"
  # use -f to fail on HTTP errors
  if ! retry 3 3 curl -fL -o "$tmpf" "$url"; then
    _err "curl failed for $url"
    return 1
  fi
  # check size
  if [[ ! -s "$tmpf" ]]; then _err "Downloaded file empty: $tmpf"; return 1; fi
  local sz
  sz=$(stat -c%s "$tmpf" 2>/dev/null || echo 0)
  if [[ "$sz" -lt "$min_bytes" ]]; then
    # Try to detect HTML/Not Found
    if grep -Iq '<html\|not found\|404\|error' "$tmpf" 2>/dev/null; then
      _err "Downloaded content looks like HTML or error page (size $sz bytes)"
      return 1
    fi
    _warn "Downloaded file small ($sz bytes) — may be incorrect"
    # still allow if min_bytes explicitly small
  fi
  return 0
}

########################################
# cloudflared installation
cloudflared_install() {
  log "Attempting to install cloudflared..."
  if command -v cloudflared >/dev/null 2>&1; then _ok "cloudflared present: $(cloudflared --version 2>&1 || true)"; return 0; fi

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    local codename=""
    if command -v lsb_release >/dev/null 2>&1; then codename="$(lsb_release -cs || true)"; fi
    if [[ -z "$codename" && -f /etc/os-release ]]; then . /etc/os-release && codename="${VERSION_CODENAME:-}"; fi
    if [[ -n "$codename" ]]; then
      _info "Trying Cloudflare apt repo for: $codename"
      retry 3 3 curl -fL -o /tmp/cloudflare-pubkey.gpg https://pkg.cloudflareclient.com/pubkey.gpg || true
      if [[ -f /tmp/cloudflare-pubkey.gpg ]]; then
        sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-client-archive-keyring.gpg /tmp/cloudflare-pubkey.gpg || true
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-client-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
        retry 3 5 sudo apt-get update || _warn "apt-get update after adding cloudflare repo failed"
        if retry 2 3 sudo apt-get install -y cloudflared; then _ok "cloudflared installed via apt"; return 0; fi
        _warn "cloudflared apt package not available for ${codename} or failed; fallback to binary"
      fi
    else
      _warn "Cannot determine distro codename; skipping apt repo approach"
    fi
  fi

  # fallback to binary
  local arch=$(uname -m)
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
  if ! download_and_verify "$url" "$tmpf" 10240; then
    _err "Failed to download cloudflared binary reliably"
    return 1
  fi
  sudo mv "$tmpf" /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
  if command -v cloudflared >/dev/null 2>&1; then _ok "cloudflared installed: $(cloudflared --version 2>&1 || true)"; return 0; fi
  _err "cloudflared install failed"
  return 1
}

########################################
# mkcert install & generate
install_mkcert() {
  if command -v mkcert >/dev/null 2>&1; then _ok "mkcert already installed: $(mkcert --version 2>&1 || true)"; return 0; fi
  _info "Installing mkcert..."
  local arch=$(uname -m)
  local url=""
  if [[ "$(uname -s)" == "Darwin" ]]; then
    url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-darwin-amd64"
  else
    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-amd64"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-arm64"
    else url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-linux-amd64"; fi
  fi
  local tmpf="/tmp/mkcert-$$.bin"
  if ! download_and_verify "$url" "$tmpf" 10240; then
    _err "mkcert download failed or returned non-binary content"
    return 1
  fi
  sudo mv "$tmpf" /usr/local/bin/mkcert
  sudo chmod +x /usr/local/bin/mkcert
  _ok "mkcert placed to /usr/local/bin/mkcert"
}

generate_mkcert_for_host() {
  local host="$1"
  local certdir="/etc/viavds/certs"
  run_cmd "sudo mkdir -p \"$certdir\""
  run_cmd "sudo chown root:root \"$certdir\" || true"
  run_cmd "sudo chmod 0755 \"$certdir\""

  if is_wsl; then
    _warn "Detected WSL. For Windows browsers: install mkcert in Windows and run 'mkcert -install' there as well."
    ((WARN_COUNT++))
  fi

  # run mkcert -install as non-root invoking user
  if ! run_as_user "mkcert -install"; then
    _warn "mkcert -install failed or returned non-zero (trust store may not be set up)."
  fi

  # generate certs as root (so they are placed in /etc)
  if ! run_cmd "sudo mkcert -key-file \"$certdir/$host-key.pem\" -cert-file \"$certdir/$host.pem\" \"$host\""; then
    _err "mkcert failed to generate certs for $host"
    ((ERR_COUNT++))
  else
    _ok "mkcert: certificate generated for $host in $certdir"
  fi
}

########################################
# nginx helpers
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

add_hosts_entry() {
  local host="$1"; local ip="${2:-127.0.0.1}"
  if grep -qE "^[^#]*\s+$host(\s|$)" /etc/hosts 2>/dev/null; then _info "Host $host already present in /etc/hosts"; return 0; fi
  run_cmd "sudo sh -c 'echo \"$ip $host\" >> /etc/hosts'"
  _ok "Added /etc/hosts entry: $ip $host"
}

########################################
# docker checks
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then _warn "docker: not installed"; ((WARN_COUNT++)); DOCKER_PRESENT=false; DOCKER_RUNNING=false; return 1; fi
  DOCKER_PRESENT=true
  if (pgrep -x dockerd >/dev/null 2>&1) || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker); then
    _ok "docker daemon: running"; DOCKER_RUNNING=true
  else
    _warn "docker daemon: not running or accessible"; DOCKER_RUNNING=false; ((WARN_COUNT++))
  fi
}

########################################
# checks for compose / images / etc.
check_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then _ok "docker compose: present"; else _warn "docker compose (v2) not present"; ((WARN_COUNT++)); fi
}

check_viavds_container() {
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then _warn "viavds container: check skipped (docker not present)"; ((WARN_COUNT++)); return; fi
  local info
  info=$(docker ps --filter "name=viavds" --format "name={{.Names}} status={{.Status}} ports={{.Ports}}" | head -n1 || true)
  if [[ -n "$info" ]]; then _ok "viavds container: $info"; return 0; fi
  info=$(docker ps -a --filter "name=viavds" --format "name={{.Names}} status={{.Status}}" | head -n1 || true)
  if [[ -n "$info" ]]; then _warn "viavds container present but stopped: $info"; ((WARN_COUNT++)); else _warn "viavds container not found"; ((WARN_COUNT++)); fi
}

check_images() {
  local dir="$1"
  if [[ -z "$dir" || ! -f "$dir/docker-compose.yml" ]]; then _warn "Images: skip (no compose file)"; ((WARN_COUNT++)); return; fi
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then _warn "Images: skipped (docker not present)"; ((WARN_COUNT++)); return; fi
  local imgs; IFS=$'\n' read -r -d '' -a imgs < <(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true; printf '\0')
  if [[ ${#imgs[@]} -eq 0 ]]; then _warn "Images: none declared in compose"; ((WARN_COUNT++)); return; fi
  for im in "${imgs[@]}"; do
    if docker image inspect "$im" >/dev/null 2>&1; then _ok "Image present: $im"; else _warn "Image missing: $im"; ((WARN_COUNT++)); fi
  done
}

check_networks_volumes() {
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then _warn "Networks & volumes: skipped (docker not present)"; ((WARN_COUNT++)); return; fi
  if [[ "${DOCKER_RUNNING:-false}" != true ]]; then _warn "Networks & volumes: docker not running; skip detailed checks"; ((WARN_COUNT++)); return; fi
  log "Docker networks:"; docker network ls --format "  {{.Name}}"
  log "Docker volumes:"; docker volume ls --format "  {{.Name}}"
}

check_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then _ok "nginx config OK"; else _err "nginx config error"; ((ERR_COUNT++)); fi
  else _warn "nginx: not installed"; ((WARN_COUNT++)); fi
}

check_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then cloudflared --version 2>&1 || true; if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cloudflared 2>/dev/null; then _ok "cloudflared: running"; else _warn "cloudflared: installed but not running"; ((WARN_COUNT++)); fi else _warn "cloudflared: not installed"; ((WARN_COUNT++)); fi
}

check_webhook() {
  if is_port_listening "$PORT"; then _ok "port $PORT: listening"; else _warn "port $PORT: not listening"; ((WARN_COUNT++)); fi
  if command -v curl >/dev/null 2>&1; then
    if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then _ok "health endpoint OK"; else _warn "health endpoint not responding"; ((WARN_COUNT++)); fi
  else _warn "curl missing: cannot test health endpoint"; ((WARN_COUNT++)); fi
}

########################################
# activation URL / QR
activate_url() {
  local url
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then url="$1"; else url="$(cat - 2>/dev/null || true)"; fi
  url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
  printf '\nДля активации сервиса перейдите по ссылке %s\n\n' "$url"
  if command -v qrencode >/dev/null 2>&1; then qrencode -o - -t UTF8 "$url" 2>/dev/null || qrencode -o - -t ANSIUTF8 "$url" 2>/dev/null || true; printf '\n'; fi
}

cloudflared_login_interactive() {
  if ! command -v cloudflared >/dev/null 2>&1; then _err "cloudflared not installed"; return 1; fi
  _info "Running 'cloudflared tunnel login' as non-root user — this usually prints a URL and may open a browser."
  run_as_user "cloudflared tunnel login" || { _warn "cloudflared tunnel login returned non-zero; run it interactively as invoking user."; return 1; }
  _ok "cloudflared login finished (check your browser or terminal for the activation URL)."
  return 0
}

########################################
# main installer
do_install() {
  detect_pkg_manager
  log "Package manager: $PKG_MANAGER"
  local ENV; ENV="$(detect_environment)"; log "Environment detected: $ENV"
  if [[ "$ENV" == local* ]]; then _info "Local environment detected ($ENV) — will avoid installing Docker Engine automatically."; fi

  # ensure core packages
  log "Ensuring basic tools: curl git ca-certificates jq"
  pkg_install curl git ca-certificates jq || _warn "Some packages could not be installed automatically."

  # qrencode optional
  pkg_install qrencode || true

  # cloudflared
  if ! command -v cloudflared >/dev/null 2>&1; then
    if cloudflared_install; then _ok "cloudflared installed"; else _warn "cloudflared install failed"; ((WARN_COUNT++)); fi
  else _ok "cloudflared present: $(cloudflared --version 2>&1 || true)"; fi

  # mkcert if requested
  if $DO_MKCERT; then
    install_mkcert || _warn "mkcert install failed"
  fi

  # project dir
  if [[ -z "$PROJECT_DIR" ]]; then PROJECT_DIR="$HOME/viavds"; fi
  _info "Project directory: $PROJECT_DIR"
  run_cmd "mkdir -p \"$PROJECT_DIR\""

  # clone as non-root invoking user
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    _info "Project already present at $PROJECT_DIR"
  else
    _info "Cloning repository $REPO_URL branch $BRANCH -> $PROJECT_DIR"
    run_as_user "git clone --depth 1 --branch \"$BRANCH\" \"$REPO_URL\" \"$PROJECT_DIR\"" || { _warn "git clone failed"; ((WARN_COUNT++)); }
  fi

  # If project dir owned by root but we were invoked via sudo, optionally chown back to user
  if [[ -n "${SUDO_USER-}" ]]; then
    if [[ "$(stat -c '%U' "$PROJECT_DIR")" == "root" ]]; then
      if $ASSUME_YES; then
        log "Fixing ownership: chown -R $SUDO_USER:$SUDO_USER $PROJECT_DIR"
        sudo chown -R "$SUDO_USER":"$SUDO_USER" "$PROJECT_DIR" || _warn "chown failed"
      else
        _warn "Project dir $PROJECT_DIR is owned by root. Consider running: sudo chown -R $SUDO_USER:$SUDO_USER $PROJECT_DIR"
        ((WARN_COUNT++))
      fi
    fi
  fi

  # docker checks
  check_docker || true
  if [[ "${DOCKER_PRESENT:-false}" != true ]]; then
    _warn "Docker not present. On server installs you can pass --install-docker (not automatic on WSL)."
  else
    # if docker present but permission denied likely on socket
    if [[ "${DOCKER_RUNNING:-false}" == false ]]; then
      _warn "Docker daemon not accessible. If you see 'permission denied' when running docker, add your user to 'docker' group:"
      _info "  sudo usermod -aG docker $SUDO_USER  # then re-login or run 'newgrp docker'"
      if $ASSUME_YES && [[ -n "${SUDO_USER-}" ]]; then
        log "Auto-adding $SUDO_USER to docker group (because --yes)"
        sudo usermod -aG docker "$SUDO_USER" || _warn "usermod failed; you may need to run it manually"
        _info "After adding, re-login or run: newgrp docker"
      fi
    fi
  fi

  # mkcert certs + nginx
  if $DO_MKCERT && [[ -n "$WEBHOOK_HOST" ]]; then
    generate_mkcert_for_host "$WEBHOOK_HOST" || _warn "mkcert reported issues"
    if command -v nginx >/dev/null 2>&1; then configure_nginx_with_tls "$WEBHOOK_HOST" "$PORT" || _warn "nginx TLS config failed"; else _warn "nginx not installed; skipping vhost creation"; fi
    add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"
  elif [[ -n "$WEBHOOK_HOST" ]]; then
    if command -v nginx >/dev/null 2>&1; then configure_nginx_for_host "$WEBHOOK_HOST" "$PORT"; add_hosts_entry "$WEBHOOK_HOST" "127.0.0.1"; else _warn "nginx not installed; skipping vhost creation"; fi
  fi

  if [[ -n "$TUNNEL_HOST" || -n "$DO_CFTUNNEL" ]]; then
    local tname="viavds-$(hostname -s)-$(date +%s)"
    prepare_cloudflared_config "$tname" "$PORT" "${TUNNEL_HOST:-ngrok.vianl.loc}"
    log "Prepared cloudflared config. Next steps (run as non-root user):"
    echo
    echo "  1) Run: cloudflared tunnel login"
    echo "     If cloudflared prints an activation URL, you can capture and show QR with: activate_url <url>"
    echo
    echo "  2) Create tunnel:"
    echo "     cloudflared tunnel create $tname"
    echo "     cloudflared tunnel route dns $tname ${TUNNEL_HOST:-ngrok.vianl.loc}"
    echo
    echo "  3) Move credential and enable service (as root):"
    echo "     sudo mv ~/.cloudflared/$tname.json /etc/cloudflared/$tname.json"
    echo "     sudo systemctl enable --now cloudflared"
    echo
  fi

  # docker compose up (try as non-root)
  if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      _info "Starting docker compose in $PROJECT_DIR (as non-root user if possible)"
      if [[ -n "${SUDO_USER-}" && "$(id -u)" -eq 0 ]]; then
        run_as_user "cd \"$PROJECT_DIR\" && docker compose up -d --build"
      else
        run_cmd "cd \"$PROJECT_DIR\" && docker compose up -d --build"
      fi
    else _warn "Skipping docker compose start: docker or compose not ready"; fi
  else _warn "docker-compose.yml not found in $PROJECT_DIR; skipping compose start"; fi

  _ok "Install sequence finished."
}

########################################
# status and cmd handlers
cmd_status() {
  _info "=== viavds STATUS CHECK ==="
  detect_pkg_manager
  _info "Package manager: ${PKG_MANAGER:-unknown}"
  local ENV; ENV="$(detect_environment)"; _info "Environment: $ENV"
  for c in curl jq git; do if command -v "$c" >/dev/null 2>&1; then _ok "$c: ok"; else _warn "$c: missing"; ((WARN_COUNT++)); fi; done
  check_docker || true
  check_compose
  PROJECT_DIR="$(find_project_dir || true)"; _info "Project dir: ${PROJECT_DIR:-not found}"
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
# args / usage
usage() {
  cat <<EOF
$SCRIPT_NAME v$VER

Usage:
  $SCRIPT_NAME [command] [options]

Commands:
  status                 Run diagnostics (default)
  install                Install viavds (auto-detect local / public)

Options:
  --dir PATH             Project directory (default: \$HOME/viavds)
  --repo URL             Git repo (default: $REPO_URL)
  --branch BRANCH        Repo branch (default: $BRANCH)
  --webhook-host HOST    Hostname for webhook/API endpoint
  --tunnel-host HOST     Hostname for tunnel
  --cf-token TOKEN       Cloudflare token (advanced)
  --port N               Service port (default: $PORT)
  --mkcert               Install and run mkcert
  --cf-tunnel            Prepare cloudflared config
  --install-docker       Allow installing docker (skipped on WSL/macOS)
  --install-nginx        Allow installing nginx
  --yes                  non-interactive: auto-accept prompts
  --dry-run              show actions without executing
  --verbose              verbose (show commands + outputs)
  --log-file FILE        append logs to FILE
  -h, --help             show help

Examples:
  curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh | bash -s -- status
  curl -fsSL https://raw.githubusercontent.com/e-bash/viavds/master/install/viavds.sh \
    | bash -s -- install --dir "$HOME/viavds" --webhook-host wh.vianl.loc --tunnel-host ngrok.vianl.loc --mkcert --cf-tunnel --yes --verbose

EOF
  exit 0
}

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
    *) _err "Unknown arg: $1"; usage;;
  esac
done

# log file validation
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! touch "$LOG_FILE" 2>/dev/null; then
    _warn "Cannot write to $LOG_FILE; falling back to /tmp/viavds-install.log"
    LOG_FILE="/tmp/viavds-install.log"; touch "$LOG_FILE" 2>/dev/null || true
  fi
  _info "Logfile: $LOG_FILE"
fi

case "$CMD" in
  status) cmd_status;;
  install) cmd_install;;
  *) usage;;
esac

exit 0

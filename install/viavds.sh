#!/usr/bin/env bash
# viavds.sh -- diagnostics & installer scaffold for viavds
# Updated: package manager detection + status output
set -euo pipefail
IFS=$'\n\t'

VER="0.4.0"
SCRIPT_NAME=$(basename "$0")

# Colors and helpers
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
  status             Run diagnostics (default)
  install-public     Install viavds on a public VDS (scaffold)
  install-local      Install viavds for local development (scaffold)

Options:
  --dir PATH         Project directory (auto-detect if missing)
  --port N           Service port (default: 14127)
  --dry-run          Show actions without running
  --yes              Non-interactive
  -v,--verbose       Verbose mode
  -h,--help          Show help
EOF
  exit 0
}

# Auto-elevate to root if possible
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    _err "Root privileges required."
    exit 1
  fi
fi

# Defaults
CMD="status"
PROJECT_DIR=""
PORT=14127
DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# Counters for summary
WARN_COUNT=0
ERR_COUNT=0

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
run(){
  if $DRY_RUN; then
    echo "[DRYRUN] $*"
  else
    if $VERBOSE; then echo "+ $*"; fi
    eval "$*"
  fi
}

PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )

# -----------------------------
# Package manager detection
# Sets:
#   PKG_MANAGER (brew/apt/dnf/yum/pacman/apk/zypper/unknown)
#   PKG_INSTALL_CMD (e.g. apt-get install -y)
#   PKG_UPDATE_CMD  (e.g. apt-get update)
# -----------------------------
detect_pkg_manager(){
  PKG_MANAGER="unknown"
  PKG_INSTALL_CMD=""
  PKG_UPDATE_CMD=""
  if has_cmd brew; then
    PKG_MANAGER="brew"
    PKG_INSTALL_CMD="brew install"
    PKG_UPDATE_CMD="brew update"
  elif has_cmd apt-get; then
    PKG_MANAGER="apt"
    PKG_INSTALL_CMD="apt-get install -y"
    PKG_UPDATE_CMD="apt-get update"
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"
    PKG_INSTALL_CMD="dnf install -y"
    PKG_UPDATE_CMD="dnf makecache"
  elif has_cmd yum; then
    PKG_MANAGER="yum"
    PKG_INSTALL_CMD="yum install -y"
    PKG_UPDATE_CMD="yum makecache"
  elif has_cmd pacman; then
    PKG_MANAGER="pacman"
    PKG_INSTALL_CMD="pacman -S --noconfirm"
    PKG_UPDATE_CMD="pacman -Sy"
  elif has_cmd apk; then
    PKG_MANAGER="apk"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_UPDATE_CMD="apk update"
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"
    PKG_INSTALL_CMD="zypper install -y"
    PKG_UPDATE_CMD="zypper refresh"
  else
    PKG_MANAGER="unknown"
  fi
}

# ----------------------------------------
# ARG PARSER
# ----------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|install-public|install-local)
      CMD="$1"; shift;;
    --dir)
      PROJECT_DIR="$2"; shift 2;;
    --port)
      PORT="$2"; shift 2;;
    --dry-run)
      DRY_RUN=true; shift;;
    --yes)
      ASSUME_YES=true; shift;;
    -v|--verbose)
      VERBOSE=true; shift;;
    -h|--help)
      usage;;
    *)
      _err "Unknown argument: $1"
      usage;;
  esac
done

# ----------------------------------------
# FIND PROJECT DIR
# ----------------------------------------
find_project_dir(){
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
      echo "$PROJECT_DIR"; return
    else
      _warn "Provided --dir does not contain docker-compose.yml"
      ((WARN_COUNT++))
    fi
  fi

  for d in "${PROJECT_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" ]]; then
      echo "$(cd "$d" && pwd)"
      return
    fi
  done

  local cur="$PWD"
  while [[ "$cur" != "/" ]]; do
    if [[ -f "$cur/docker-compose.yml" ]]; then
      echo "$cur"
      return
    fi
    cur=$(dirname "$cur")
  done

  echo ""
}

# ----------------------------------------
# PORT CHECK
# ----------------------------------------
is_port_listening(){
  local port="$1"
  if has_cmd ss; then
    ss -ltn | grep -q ":$port" && return 0 || return 1
  elif has_cmd netstat; then
    netstat -lnt | grep -q ":$port" && return 0 || return 1
  fi
  return 2
}

# ----------------------------------------
# Environment detection (improved)
# - If running in WSL -> local
# - Else try public IP; if private or empty -> local
# ----------------------------------------
detect_environment(){
  # WSL detection
  if [[ -f /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    echo "local (wsl)"
    return
  fi

  local pubip=""
  if has_cmd curl; then
    pubip=$(curl -fsS --max-time 2 https://ifconfig.co || true)
  fi

  if [[ -z "$pubip" ]]; then
    echo "local"
    return
  fi

  if [[ "$pubip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then
    echo "local"
  else
    echo "public"
  fi
}

# ----------------------------------------
# DOCKER CHECKS (conditional)
# ----------------------------------------
check_docker(){
  if ! has_cmd docker; then
    _warn "Docker: not installed"
    ((WARN_COUNT++))
    DOCKER_PRESENT=false
    DOCKER_RUNNING=false
    return
  fi
  DOCKER_PRESENT=true
  docker --version 2>/dev/null || true
  if has_cmd systemctl; then
    if systemctl is-active --quiet docker; then
      _ok "Docker: running"
      DOCKER_RUNNING=true
    else
      _warn "Docker: installed but not running"
      DOCKER_RUNNING=false
      ((WARN_COUNT++))
    fi
  else
    if pgrep -x dockerd >/dev/null 2>&1; then
      _ok "Docker: running (no systemd)"
      DOCKER_RUNNING=true
    else
      _warn "Docker: installed but dockerd not found"
      DOCKER_RUNNING=false
      ((WARN_COUNT++))
    fi
  fi
}

check_compose(){
  if ! $DOCKER_PRESENT; then
    _warn "Docker Compose: skipped (docker not present)"
    ((WARN_COUNT++))
    return
  fi
  if docker compose version >/dev/null 2>&1; then
    _ok "Docker Compose: available"
  else
    _warn "Docker Compose: not available (docker compose)"
    ((WARN_COUNT++))
  fi
}

# ----------------------------------------
# CONTAINER CHECK (conditional)
# ----------------------------------------
check_viavds_container(){
  if ! $DOCKER_PRESENT; then
    _warn "viavds container: skipped (docker not present)"
    ((WARN_COUNT++))
    VIAVDS_SUMMARY="skipped"
    return
  fi

  local r
  r=$(docker ps --filter "name=viavds" --format "{{.Names}}||{{.Status}}||{{.Ports}}" || true)
  if [[ -n "$r" ]]; then
    _ok "viavds container: running -> ${r}"
    VIAVDS_SUMMARY="running -> ${r}"
    return
  fi

  local a
  a=$(docker ps -a --filter "name=viavds" --format "{{.Names}}||{{.Status}}" || true)
  if [[ -n "$a" ]]; then
    _warn "viavds container: present but not running -> ${a}"
    VIAVDS_SUMMARY="present but not running -> ${a}"
    ((WARN_COUNT++))
    return
  fi

  _warn "viavds container: not found"
  VIAVDS_SUMMARY="not found"
  ((WARN_COUNT++))
}

# ----------------------------------------
# IMAGE CHECK (conditional)
# ----------------------------------------
check_images(){
  local dir="$1"
  if [[ -z "$dir" ]]; then
    _warn "Images: skipped (no compose file)"
    ((WARN_COUNT++))
    return
  fi

  if ! $DOCKER_PRESENT; then
    _warn "Images: skipped (docker not present)"
    ((WARN_COUNT++))
    return
  fi

  local imgs
  imgs=( $(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true) )
  if [[ ${#imgs[@]} -eq 0 ]]; then
    _warn "Images: no explicit image entries in compose"
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

# ----------------------------------------
# NETWORKS/VOLUMES (conditional)
# ----------------------------------------
check_networks_volumes(){
  if ! $DOCKER_PRESENT; then
    _warn "Networks & volumes: skipped (docker not present)"
    ((WARN_COUNT++))
    return
  fi
  if ! $DOCKER_RUNNING; then
    _warn "Networks & volumes: docker not running, skip detailed checks"
    ((WARN_COUNT++))
    return
  fi

  _info "Existing docker networks:"
  if ! docker network ls --format "  {{.Name}}" >/dev/null 2>&1; then
    _err "Failed to list docker networks"
    ((ERR_COUNT++))
  else
    docker network ls --format "  {{.Name}}" || true
  fi

  _info "Existing docker volumes:"
  if ! docker volume ls --format "  {{.Name}}" >/dev/null 2>&1; then
    _err "Failed to list docker volumes"
    ((ERR_COUNT++))
  else
    docker volume ls --format "  {{.Name}}" || true
  fi
}

# ----------------------------------------
# NGINX
# ----------------------------------------
check_nginx(){
  if ! has_cmd nginx; then
    _warn "nginx: not installed"
    ((WARN_COUNT++))
    return
  fi
  if nginx -t >/dev/null 2>&1; then
    _ok "nginx config: OK"
  else
    _err "nginx config: PROBLEM (run nginx -t)"
    ((ERR_COUNT++))
  fi

  if [[ -d /etc/nginx/sites-enabled ]]; then
    _info "nginx vhosts (sites-enabled):"
    ls -1 /etc/nginx/sites-enabled || true
  else
    nginx -T 2>/dev/null | sed -n '1,120p' || true
  fi
}

# ----------------------------------------
# CLOUDFLARED
# ----------------------------------------
check_cloudflared(){
  if ! has_cmd cloudflared; then
    _warn "cloudflared: not installed"
    ((WARN_COUNT++))
    return
  fi
  cloudflared --version 2>/dev/null || true
  if systemctl is-active --quiet cloudflared; then
    _ok "cloudflared: running"
  else
    _warn "cloudflared: installed but not running"
    ((WARN_COUNT++))
  fi
}

# ----------------------------------------
# WEBHOOK (health)
# ----------------------------------------
check_webhook(){
  if is_port_listening "$PORT"; then
    _ok "port $PORT: listening"
  else
    _warn "port $PORT: NOT listening"
    ((WARN_COUNT++))
  fi

  if ! has_cmd curl; then
    _warn "health check skipped: curl not installed"
    ((WARN_COUNT++))
    return
  fi

  if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    _ok "webhook handler: health OK (127.0.0.1:$PORT/health)"
  else
    _warn "webhook handler: no response on 127.0.0.1:$PORT/health"
    ((WARN_COUNT++))
  fi
}

# ----------------------------------------
# OTHER checks
# ----------------------------------------
check_git(){
  if has_cmd git; then
    _ok "git: installed"
  else
    _warn "git: not installed"
    ((WARN_COUNT++))
  fi
}

check_disk(){
  _info "Disk usage (root & docker path):"
  df -h --total | sed -n '1,8p' || true
  if [[ -d /var/lib/docker ]]; then
    du -sh /var/lib/docker 2>/dev/null || true
  fi
}

# ----------------------------------------
# SUMMARY printer
# ----------------------------------------
print_summary(){
  echo
  _info "SUMMARY:"
  _info " Project dir: ${PROJECT_DIR:-(not found)}"
  _info " Environment: ${ENV_TYPE:-unknown}"
  _info " Package manager: ${PKG_MANAGER:-unknown}"
  if [[ "${PKG_MANAGER:-unknown}" != "unknown" ]]; then
    _info " Package install cmd: ${PKG_INSTALL_CMD}"
    _info " Package update cmd:  ${PKG_UPDATE_CMD}"
  fi
  if $DOCKER_PRESENT 2>/dev/null; then
    _info " Docker: present"
    [[ $DOCKER_RUNNING == true ]] && _info " Docker daemon: running" || _warn " Docker daemon: not running"
  else
    _warn " Docker: not present"
  fi
  _info " viavds container: ${VIAVDS_SUMMARY:-(not checked)}"
  _info " Webhook port $PORT listening: $( is_port_listening $PORT && echo yes || echo no )"
  echo
  if (( ERR_COUNT > 0 )); then
    _err "Errors: $ERR_COUNT"
  fi
  if (( WARN_COUNT > 0 )); then
    _warn "Warnings: $WARN_COUNT"
  else
    _ok "No warnings"
  fi
}

# ----------------------------------------
# MAIN - status
# ----------------------------------------
cmd_status(){
  _info "=== VIAVDS STATUS CHECK ==="

  # detect package manager early
  detect_pkg_manager

  ENV_TYPE=$(detect_environment)
  _info "Environment detected: $ENV_TYPE"

  # Docker
  check_docker

  # Compose
  check_compose

  # Find project dir
  PROJECT_DIR=$(find_project_dir)
  if [[ -n "$PROJECT_DIR" ]]; then
    _info "Project directory: $PROJECT_DIR"
  else
    _warn "Project directory: not found (specify with --dir /path/to/viavds)"
    ((WARN_COUNT++))
  fi

  # Container
  check_viavds_container

  # Images
  check_images "$PROJECT_DIR"

  # Networks & volumes
  check_networks_volumes

  # nginx
  check_nginx

  # cloudflared
  check_cloudflared

  # webhook
  check_webhook

  # misc
  check_git
  check_disk

  # summary
  print_summary

  if (( ERR_COUNT > 0 )); then
    _err "STATUS: FAIL (errors found)"
    exit 2
  elif (( WARN_COUNT > 0 )); then
    _warn "STATUS: WARN (see summary)"
    exit 1
  else
    _ok "STATUS: OK"
    exit 0
  fi
}

cmd_install_public(){
  _warn "(install-public mode not implemented yet)"
}

cmd_install_local(){
  _warn "(install-local mode not implemented yet)"
}

# ----------------------------------------
# dispatch
# ----------------------------------------
case "$CMD" in
  status) cmd_status;;
  install-public) cmd_install_public;;
  install-local) cmd_install_local;;
  *) usage;;
esac

exit 0

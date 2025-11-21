#!/usr/bin/env bash
# viavds.sh -- diagnostics & installer scaffold for viavds
set -euo pipefail
IFS=$'\n\t'

VER="0.2.1"
SCRIPT_NAME=$(basename "$0")

# Colors
_info(){ printf "\e[1;34m%s\e[0m\n" "$*"; }
_ok(){ printf "\e[1;32m%s\e[0m\n" "$*"; }
_warn(){ printf "\e[1;33m%s\e[0m\n" "$*"; }
_err(){ printf "\e[1;31m%s\e[0m\n" "$*\n" >&2; }

usage(){
  cat <<EOF
$SCRIPT_NAME v$VER

Usage:
  $SCRIPT_NAME [command] [options]

Commands:
  status             Run diagnostics (default)
  install-public     Install viavds on a public VDS (scaffold)
  install-local      Install viavads for local development (scaffold)

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

# Auto-elevate to root (like nginx_env_check.sh)
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

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
run(){ if $DRY_RUN; then echo "[DRYRUN] $*"; else if $VERBOSE; then echo "+ $*"; fi; eval "$*"; fi }

PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "$HOME/viavds" )

# --- ARGUMENT PARSER ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|install-public|install-local)
      CMD="$1"; shift;;
    --dir) PROJECT_DIR="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --yes) ASSUME_YES=true; shift;;
    -v|--verbose) VERBOSE=true; shift;;
    -h|--help) usage;;
    *) _err "Unknown argument: $1"; usage;;
  esac
done

# --- FIND PROJECT DIR ---
find_project_dir(){
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
      echo "$PROJECT_DIR"; return
    fi
    _warn "Provided --dir does not contain docker-compose.yml"
  fi

  for d in "${PROJECT_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" ]]; then
      echo "$(cd "$d" && pwd)"
      return
    fi
  done

  echo ""
}

# --- PORT CHECK ---
is_port_listening(){
  local port="$1"
  if has_cmd ss; then
    ss -lnt | grep -q ":$port" && return 0 || return 1
  elif has_cmd netstat; then
    netstat -lnt | grep -q ":$port" && return 0 || return 1
  fi
  return 2
}

# --- DOCKER CHECKS ---
check_docker(){
  if ! has_cmd docker; then echo "not installed"; return; fi
  docker --version 2>/dev/null || true
  if has_cmd systemctl; then
    systemctl is-active --quiet docker && echo "running" || echo "installed (not running)"
  else
    pgrep -x dockerd >/dev/null && echo "running(no systemd)" || echo "installed(not running)"
  fi
}

check_compose(){
  if docker compose version >/dev/null 2>&1; then
    docker compose version
  else
    echo "not installed"
  fi
}

# --- CONTAINER CHECK ---
check_viavds_container(){
  if ! has_cmd docker; then echo "docker missing"; return; fi
  local r=$(docker ps --filter "name=viavds" --format "{{.Status}}|{{.Ports}}")
  if [[ -n "$r" ]]; then
    echo "running|$r"; return
  fi
  local a=$(docker ps -a --filter "name=viavds" --format "{{.Status}}")
  if [[ -n "$a" ]]; then
    echo "stopped|$a"; return
  fi
  echo "absent"
}

# --- IMAGE CHECK ---
check_images(){
  local dir="$1"
  if [[ -z "$dir" ]]; then echo "no compose file"; return; fi
  local imgs=( $(awk '/image:/ {print $2}' "$dir/docker-compose.yml") )
  if [[ ${#imgs[@]} -eq 0 ]]; then echo "no images in compose"; return; fi

  for im in "${imgs[@]}"; do
    if docker image inspect "$im" >/dev/null 2>&1; then
      echo "  OK: $im"
    else
      echo "  MISSING: $im"
    fi
  done
}

# --- NETWORK & VOLUMES ---
check_networks_volumes(){
  echo "Networks:"; docker network ls --format "  {{.Name}}" || true
  echo "Volumes:"; docker volume ls --format "  {{.Name}}" || true
}

# --- NGINX ---
check_nginx(){
  if ! has_cmd nginx; then echo "nginx missing"; return; fi
  nginx -t >/dev/null 2>&1 && echo "nginx config OK" || echo "nginx config ERROR"
}

# --- CLOUDFLARED ---
check_cloudflared(){
  if ! has_cmd cloudflared; then echo "not installed"; return; fi
  cloudflared --version
  systemctl is-active --quiet cloudflared && echo "running" || echo "installed (not running)"
}

# --- WEBHOOK ---
check_webhook(){
  if is_port_listening "$PORT"; then echo "port $PORT listening"; else echo "port $PORT NOT listening"; fi
  if has_cmd curl && curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "health OK"
  else
    echo "health FAIL"
  fi
}

# --- MAIN STATUS ---
cmd_status(){
  _info "=== VIAVDS STATUS CHECK ==="

  # ENV detection
  if has_cmd curl; then
    PUBIP=$(curl -fsS --max-time 2 https://ifconfig.co || true)
    if [[ -n "$PUBIP" ]]; then ENV="public"; else ENV="local"; fi
  else
    ENV="unknown"
  fi
  _info "Environment: $ENV"

  echo; _info "Docker:"
  DOCKER_STATUS=$(check_docker); echo "$DOCKER_STATUS"
  echo; _info "Docker Compose:"; check_compose

  echo; _info "Project directory:"
  PROJECT_DIR=$(find_project_dir)
  echo "${PROJECT_DIR:-not found}"

  echo; _info "viavds container:"
  check_viavds_container

  echo; _info "Images:"; check_images "$PROJECT_DIR"
  echo; _info "Networks & volumes:"; check_networks_volumes

  echo; _info "nginx:"; check_nginx
  echo; _info "cloudflared:"; check_cloudflared

  echo; _info "Webhook handler:"
  check_webhook

  echo; _ok "STATUS COMPLETE."
}

cmd_install_public(){ _warn "(install-public mode not implemented yet)" }
cmd_install_local(){ _warn "(install-local mode not implemented yet)" }

# DISPATCH
case "$CMD" in
  status) cmd_status;;
  install-public) cmd_install_public;;
  install-local) cmd_install_local;;
  *) usage;;
esac

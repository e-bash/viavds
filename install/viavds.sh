#!/usr/bin/env bash
# viavds.sh -- diagnostics & installer scaffold for viavds
# Mode implemented: status (default, run without args)
# Other modes (install-public / install-local) are scaffolded.
set -euo pipefail
IFS=$'\n\t'

VER="0.2.0"
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
  status             Run diagnostics (default)
  install-public     Install viavds on a public VDS (scaffold)
  install-local      Install viavds for local development (scaffold)

Options:
  --dir PATH         Path to project (searches for docker-compose.yml) (default: auto)
  --port N           Port for service (default: 14127)
  --hostname NAME    Hostname (for install)
  --dry-run          Show actions but do not execute
  --yes              Non-interactive (accept defaults)
  -v,--verbose       Verbose output
  -h,--help          Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME status --dir /opt/viavds --verbose
EOF
  exit 0
}

# Auto-elevate to root if possible (like nginx_env_check.sh used)
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    _err "This script requires root privileges (sudo not available)."
    exit 1
  fi
fi

# Defaults
CMD="status"
PROJECT_DIRS=( "." "/opt/viavds" "/srv/viavds" "/home/deploy/viavds" "$HOME/viavds" )
PROJECT_DIR=""
PORT=14127
DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# helpers
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
run(){ if $DRY_RUN; then echo "[DRYRUN] $*"; else if $VERBOSE; echo "+ $*"; fi; eval "$*"; }

# argument parser
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
    *) echo "Unknown arg: $1"; usage;;
  esac
done

# find project directory (docker-compose.yml)
find_project_dir(){
  if [[ -n "$PROJECT_DIR" ]]; then
    if [[ -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/docker-compose.yaml" ]]; then
      echo "$PROJECT_DIR"
      return 0
    else
      _warn "Provided --dir does not contain docker-compose.yml: $PROJECT_DIR"
    fi
  fi
  for d in "${PROJECT_DIRS[@]}"; do
    if [[ -f "$d/docker-compose.yml" || -f "$d/docker-compose.yaml" ]]; then
      echo "$(cd "$d" && pwd)"
      return 0
    fi
  done
  # fallback: check cwd upward
  cur="$PWD"
  while [[ "$cur" != "/" ]]; do
    if [[ -f "$cur/docker-compose.yml" || -f "$cur/docker-compose.yaml" ]]; then
      echo "$cur"
      return 0
    fi
    cur=$(dirname "$cur")
  done
  # not found
  echo ""
  return 1
}

# utility: check port occupancy
is_port_listening(){
  local port="$1"
  if has_cmd ss; then
    ss -ltn "( sport = :$port )" >/dev/null 2>&1 && return 0 || return 1
  elif has_cmd netstat; then
    netstat -ltn | awk '{print $4}' | grep -E "[:.]$port$" >/dev/null 2>&1 && return 0 || return 1
  else
    return 2
  fi
}

# docker checks
check_docker(){
  if has_cmd docker; then
    docker --version 2>/dev/null || true
    if has_cmd systemctl; then
      if systemctl is-active --quiet docker; then
        echo "running"
      else
        echo "installed (not running)"
      fi
    else
      # no systemd
      pgrep -x dockerd >/dev/null 2>&1 && echo "running (no systemd)" || echo "installed (daemon not found)"
    fi
  else
    echo "not installed"
  fi
}

check_docker_compose(){
  # prefer v2 (docker compose)
  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    docker compose version 2>/dev/null || true
  elif has_cmd docker-compose; then
    echo "docker-compose (v1) available"
  else
    echo "not installed"
  fi
}

# container checks
check_viavds_container(){
  if ! has_cmd docker; then
    echo "docker not available"
    return 10
  fi
  local running
  running=$(docker ps --filter "name=viavds" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | head -n1 || true)
  if [[ -n "$running" ]]; then
    printf "running\t%s\n" "$running"
    return 0
  fi
  local all
  all=$(docker ps -a --filter "name=viavds" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | head -n1 || true)
  if [[ -n "$all" ]]; then
    printf "present_not_running\t%s\n" "$all"
    return 1
  fi
  echo "not_found"
  return 2
}

# images/networks/volumes
check_required_images(){
  # try to detect images from docker-compose if project dir available
  local dir="$1"
  local imgs=()
  if [[ -n "$dir" && -f "$dir/docker-compose.yml" ]]; then
    # extract image names or service names (best-effort)
    imgs=( $(awk '/image:/ {print $2}' "$dir/docker-compose.yml" || true) )
    # also consider build: -> use service name with local build
  fi
  if [[ ${#imgs[@]} -eq 0 ]]; then
    echo "no manifest images detected (skipping detailed image check)"
    return 0
  fi
  echo "expected images from compose:"
  for im in "${imgs[@]}"; do
    if [[ -z "$im" ]]; then continue; fi
    if docker image inspect "$im" >/dev/null 2>&1; then
      echo "  OK: $im"
    else
      echo "  MISSING: $im"
    fi
  done
}

check_networks_volumes(){
  # heuristic expected names
  local dir="$1"
  if [[ -n "$dir" && -f "$dir/docker-compose.yml" ]]; then
    # try to parse volumes: and networks:
    echo "Parsing docker-compose for networks/volumes (best-effort)..."
    awk '/^networks:/{flag=1;next} /^volumes:/{vflag=1;flag=0} flag && /^[[:space:]]+[a-zA-Z0-9_\-]+:/{gsub(/[: ]/,"",$1); print "network:"$1}' "$dir/docker-compose.yml" || true
    awk '/^volumes:/{flag=1;next} flag && /^[[:space:]]+[a-zA-Z0-9_\-]+:/{gsub(/[: ]/,"",$1); print "volume:"$1}' "$dir/docker-compose.yml" || true
  else
    echo "No docker-compose.yml found -> skip networks/volumes parse"
    return 0
  fi
  # list existing
  echo "Existing docker networks:"
  docker network ls --format "table {{.Name}}\t{{.Driver}}"
  echo "Existing docker volumes:"
  docker volume ls --format "table {{.Name}}"
}

# nginx/vhost checks (basic)
check_nginx_vhosts(){
  if ! has_cmd nginx; then
    echo "nginx: not installed"
    return 0
  fi
  # config test
  if nginx -t >/dev/null 2>&1; then
    echo "nginx: config OK"
  else
    echo "nginx: config PROBLEM (run nginx -t)"
  fi
  # list server_names from enabled sites (Debian layout) or nginx -T
  if [[ -d /etc/nginx/sites-enabled ]]; then
    echo "nginx vhosts (sites-enabled):"
    for f in /etc/nginx/sites-enabled/*; do
      [[ -f "$f" ]] || continue
      echo "  + $f"
      grep -E "server_name|listen" -n "$f" || true
    done
  else
    echo "nginx - showing server blocks (nginx -T parsing):"
    nginx -T 2>/dev/null | awk '/server \{/{p=1} p{print} /}/ && p{p=0}' | sed -n '1,120p' || true
  fi
  # check if any vhost proxypass to 127.0.0.1:$PORT (hint)
  if nginx -T 2>/dev/null | grep -E "proxy_pass .*(127\.0\.0\.1|localhost):$PORT" >/dev/null 2>&1; then
    echo "Found nginx proxy_pass to 127.0.0.1:$PORT"
  fi
}

# cloudflared checks
check_cloudflared(){
  if ! has_cmd cloudflared; then
    echo "cloudflared: not installed"
    return 0
  fi
  cloudflared --version 2>/dev/null || true
  if systemctl is-active --quiet cloudflared; then
    echo "cloudflared: running (systemd)"
    # try list tunnels
    cloudflared tunnel list 2>/dev/null || true
  else
    echo "cloudflared: installed but not running"
  fi
}

# webhook handler check
check_webhook_handler(){
  local addr="127.0.0.1:$PORT"
  # check port listening on host first
  if is_port_listening "$PORT"; then
    echo "port $PORT: listening on host"
  else
    echo "port $PORT: not listening on host"
  fi
  # try curl to health endpoint
  if has_cmd curl; then
    if curl -sS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      echo "webhook handler: OK (127.0.0.1:$PORT/health)"
    else
      echo "webhook handler: no response on 127.0.0.1:$PORT/health"
    fi
  else
    echo "curl: not installed, cannot test handler endpoint"
  fi
}

# Disk check
check_disk(){
  echo "Disk usage (root & docker):"
  df -h --total | sed -n '1,8p'
  if [[ -d /var/lib/docker ]]; then
    du -sh /var/lib/docker 2>/dev/null || true
  fi
}

# git check (for install modes)
check_git(){
  if has_cmd git; then
    git --version || true
  else
    echo "git: not installed"
  fi
}

# summary helper
summary_output(){
  echo
  _info "SUMMARY"
  echo " Project dir: ${PROJECT_DIR:-(not found)}"
  echo " Environment: $ENV_TYPE"
  echo " Docker: $DOCKER_STATUS"
  echo " Docker compose: $DOCKER_COMPOSE_STATUS"
  echo " viavds container: $VIAVDS_STATUS"
  echo " webhook port $PORT listening: $( is_port_listening $PORT && echo yes || echo no )"
  echo
}

# main: status
cmd_status(){
  _info "viavds status check (v$VER)"
  echo

  # detect env
  ENV_TYPE="local"
  # try to get public ip quickly
  if has_cmd curl; then
    PUBIP=$(curl -fsS --max-time 3 https://ifconfig.co || true)
  else
    PUBIP=""
  fi
  if [[ -n "$PUBIP" && ! "$PUBIP" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1]) ]]; then
    ENV_TYPE="public"
  fi
  _info "Environment detected: $ENV_TYPE (public IP: ${PUBIP:-none})"

  echo
  _info "Checking core dependencies..."
  DOCKER_STATUS=$(check_docker)
  _info "Docker: $DOCKER_STATUS"
  DOCKER_COMPOSE_STATUS=$(check_docker_compose)
  _info "Docker Compose: $DOCKER_COMPOSE_STATUS"

  echo
  _info "Project directory detection..."
  PROJECT_DIR=$(find_project_dir || true)
  if [[ -n "$PROJECT_DIR" ]]; then
    _info "Found project dir: $PROJECT_DIR"
  else
    _warn "docker-compose.yml not found in common locations. To specify: --dir /path/to/viavds"
  fi

  echo
  _info "Checking viavds container..."
  VIAVDS_STATUS_RAW=$(check_viavds_container || true)
  VIAVDS_STATUS="$VIAVDS_STATUS_RAW"
  _info "viavds: $VIAVDS_STATUS"

  echo
  _info "Checking docker images (from compose if present)..."
  if [[ -n "$PROJECT_DIR" ]]; then
    check_required_images "$PROJECT_DIR"
  else
    _info "No project dir -> skipping image presence checks"
  fi

  echo
  _info "Checking docker networks & volumes..."
  if [[ -n "$PROJECT_DIR" ]]; then
    check_networks_volumes "$PROJECT_DIR"
  else
    _info "No project dir -> listing existing networks/volumes"
    docker network ls --format "table {{.Name}}\t{{.Driver}}" || true
    docker volume ls --format "table {{.Name}}" || true
  fi

  echo
  _info "Nginx / vhosts check..."
  check_nginx_vhosts

  echo
  _info "cloudflared check..."
  check_cloudflared

  echo
  _info "Webhook handler (health endpoint) check..."
  check_webhook_handler

  echo
  _info "Other checks..."
  check_git
  check_disk

  summary_output

  _ok "Status check finished."
}

# placeholder scaffolds
cmd_install_public(){
  _warn "install-public not implemented yet. See install_viavds.sh and install_cloudflared.sh for reference."
  _info "install scripts available at:"
  echo " - install_viavds.sh (installer scaffold)"
  echo " - install_cloudflared.sh (cloudflared installer)"
  _info "You can review them in the repo."
}

cmd_install_local(){
  _warn "install-local not implemented yet."
  _info "It will prepare mkcert, docker-compose.override, local nginx config, etc."
}

# dispatch
case "$CMD" in
  status) cmd_status ;;
  install-public) cmd_install_public ;;
  install-local) cmd_install_local ;;
  *) usage ;;
esac

exit 0

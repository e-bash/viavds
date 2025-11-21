#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install_viavds.sh — installer for e-bash/viavds
# Supports: Debian/Ubuntu (apt)
#
# Usage example:
# curl -sSL "https://raw.githubusercontent.com/<you>/viavds/main/install/install_viavds.sh" \
#   | sudo bash -s -- \
#     --wh wh.viakz.ru \
#     --ngrok ngrok.viakz.ru \
#     --email admin@viakz.ru \
#     --repo https://github.com/e-bash/viavds.git \
#     --postgres-password VeryStrongPass \
#     [--cf-token XXXXXX]
#
# Notes:
#  - For Cloudflare DNS challenge, provide --cf-token (needs Zone:DNS:Edit scope for the zone).
#  - Script is written for Debian/Ubuntu. For other distros adjust package manager.
#  - cloudflared login is interactive and must be executed manually (instructions printed).
#  - The script creates swap file if RAM < 3GB.

info(){ printf "\n[INFO] %s\n" "$*"; }
ok(){ printf "\n[OK] %s\n" "$*"; }
err(){ printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# Defaults
WH=""
NGROK=""
EMAIL=""
REPO="https://github.com/e-bash/viavds.git"
POSTGRES_PASSWORD=""
INSTALL_DIR="/opt/viavds"
CF_TOKEN=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wh) WH="$2"; shift 2;;
    --ngrok) NGROK="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --postgres-password) POSTGRES_PASSWORD="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --cf-token) CF_TOKEN="$2"; shift 2;;
    --help|-h) cat <<EOF
Usage: $0 --wh wh.example.tld --ngrok ngrok.example.tld --email admin@example.tld --repo <git_url> --postgres-password <pass> [--cf-token <cloudflare_token>]
EOF
      exit 0;;
    *) err "Unknown parameter: $1";;
  esac
done

# Validate
if [[ -z "$WH" || -z "$NGROK" || -z "$EMAIL" || -z "$POSTGRES_PASSWORD" ]]; then
  err "Missing required parameters. Example:
  $0 --wh wh.viakz.ru --ngrok ngrok.viakz.ru --email admin@viakz.ru --repo https://github.com/e-bash/viavds.git --postgres-password VeryStrongPass"
fi

info "Installer params:
  WH=$WH
  NGROK=$NGROK
  EMAIL=$EMAIL
  REPO=$REPO
  INSTALL_DIR=$INSTALL_DIR
  CF_TOKEN=${CF_TOKEN:+(provided)}"

if [[ $EUID -ne 0 ]]; then
  err "Run script as root (sudo)."
fi

# Create deploy user if missing
if ! id -u deploy >/dev/null 2>&1; then
  info "Creating user 'deploy'..."
  useradd -m -s /bin/bash deploy
  passwd -l deploy || true
  mkdir -p /home/deploy/.ssh
  chown -R deploy:deploy /home/deploy
fi

# 1. update & base packages
info "apt update/upgrade and installing base packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y curl git apt-transport-https ca-certificates gnupg lsb-release software-properties-common unzip dnsutils

# 2. Docker
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
else
  info "Docker already installed."
fi

# docker compose plugin
if ! docker compose version >/dev/null 2>&1; then
  info "Installing docker compose plugin..."
  apt-get update -y
  apt-get install -y docker-compose-plugin || true
fi

# Add deploy to docker group
usermod -aG docker deploy || true

# 3. nginx & certbot (+ optional cloudflare plugin)
info "Installing nginx and certbot..."
apt-get install -y nginx
apt-get install -y certbot python3-certbot-nginx || true
if [[ -n "$CF_TOKEN" ]]; then
  info "Installing certbot plugin for Cloudflare DNS..."
  apt-get install -y python3-certbot-dns-cloudflare || true
fi

# 4. cloudflared
info "Installing cloudflared..."
CURL_DEB="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
curl -sSL "$CURL_DEB" -o /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb || apt-get -f install -y

# 5. small swap if <3GB
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( TOTAL_MB < 3000 )); then
  if [[ ! -f /swapfile ]]; then
    info "Creating 2GB swap (RAM ${TOTAL_MB}MB)..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap created."
  else
    info "Swap already exists."
  fi
fi

# 6. Clone repo
info "Cloning repo $REPO into $INSTALL_DIR..."
if [[ -d "$INSTALL_DIR" ]]; then
  info "$INSTALL_DIR exists — pulling latest..."
  cd "$INSTALL_DIR"
  git pull || true
else
  git clone "$REPO" "$INSTALL_DIR"
fi
chown -R deploy:deploy "$INSTALL_DIR"

cd "$INSTALL_DIR"

# 7. ensure docker-compose.yml (create if missing) — updated to use WH and NGROK placeholders
if [[ ! -f docker-compose.yml ]]; then
  info "No docker-compose.yml found — creating a default one."
  cat > docker-compose.yml <<YAML
version: '3.8'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: viavds
      POSTGRES_USER: viavds
      POSTGRES_PASSWORD: "__POSTGRES_PASSWORD__"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U viavds"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  viavds:
    build: .
    environment:
      DATABASE_URL: postgres://viavds:__POSTGRES_PASSWORD__@postgres:5432/viavds
      PORT: 14127
      NODE_ENV: production
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "14127:14127"
    volumes:
      - ./:/app
    restart: unless-stopped

volumes:
  pgdata:
YAML
  sed -i "s|__POSTGRES_PASSWORD__|$POSTGRES_PASSWORD|g" docker-compose.yml
  ok "Default docker-compose.yml created."
else
  info "Using docker-compose.yml from repo."
fi

# 8. ensure Dockerfile
if [[ ! -f Dockerfile ]]; then
  info "No Dockerfile — creating minimal Dockerfile."
  cat > Dockerfile <<'DOCK'
FROM node:18-alpine
WORKDIR /app
COPY package.json yarn.lock ./
RUN apk add --no-cache python3 make g++ curl git && \
    if [ -f yarn.lock ]; then npm i -g yarn && yarn install --frozen-lockfile; else npm ci; fi
COPY . .
RUN if [ -f package.json ] && grep -q build package.json; then npm run build || true; fi
ENV NODE_ENV=production
EXPOSE 14127
CMD ["node", "src/app.js"]
DOCK
  ok "Dockerfile created."
fi

# 9. create .env if not exists
ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  info "Creating .env..."
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=14127
HOST=0.0.0.0

DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_NAME=viavds
DATABASE_USER=viavds
DATABASE_PASS=$POSTGRES_PASSWORD

WORKER_BATCH_SIZE=20
WORKER_LOOP_DELAY_MS=500
WORKER_MAX_ATTEMPTS=5
WORKER_BACKOFF_MS=2000

RETENTION_DAYS=30
CLEANUP_INTERVAL_MINUTES=1440

BASIC_AUTH_USER=admin
BASIC_AUTH_PASS=ChangeMe123!
HMAC_SECRET=ChangeMeSuperSecret

MAX_PAYLOAD_SIZE=5242880

CLOUDFLARE_TUNNEL_NAME=main-vds

LOG_LEVEL=info
EOF
  chown deploy:deploy "$ENV_FILE"
  ok ".env created at $ENV_FILE"
else
  info ".env exists — leaving it."
fi

# 10. nginx site for WH (only) and lightweight for NGROK (HTTP only)
NG_AV="/etc/nginx/sites-available"
NG_EN="/etc/nginx/sites-enabled"
mkdir -p "$NG_AV" "$NG_EN"
SITE_WH="$NG_AV/$WH"
SITE_NG="$NG_AV/$NGROK"

info "Creating nginx config for $WH (proxy to container) and $NGROK (simple proxy if needed)..."

cat > "$SITE_WH" <<NGWH
server {
    listen 80;
    server_name $WH;

    location / {
        proxy_pass http://127.0.0.1:14127;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
    }
}
NGWH

cat > "$SITE_NG" <<NGNG
server {
    listen 80;
    server_name $NGROK;

    location / {
        return 200 'ngrok endpoint on this host (use Cloudflare Tunnel routing)';
    }
}
NGNG

ln -sf "$SITE_WH" "$NG_EN/$WH"
ln -sf "$SITE_NG" "$NG_EN/$NGROK"

mkdir -p "/var/www/$WH/html"
chown -R www-data:www-data "/var/www/$WH"

nginx -t
systemctl reload nginx || systemctl restart nginx
ok "nginx configured for $WH and $NGROK (HTTP)."

# 11. DNS check
SERVER_IP=$(curl -sS https://ifconfig.co || curl -sS https://icanhazip.com || echo "")
resolve4(){ host -4 "$1" 2>/dev/null | awk '/has address/ {print $4; exit}' || echo ""; }
RES_WH=$(resolve4 "$WH")
RES_NG=$(resolve4 "$NGROK")

info "Server IP: $SERVER_IP"
info "$WH resolves to: ${RES_WH:-(none)}"
info "$NGROK resolves to: ${RES_NG:-(none)}"

# 12. Obtain certs: if CF token provided -> dns-cloudflare, else try HTTP challenge only if DNS resolves to server
CERT_OK=false
if [[ -n "$CF_TOKEN" ]]; then
  info "Using Cloudflare DNS challenge (certbot-dns-cloudflare). Preparing credentials..."
  CF_CRED="/root/.secrets/certbot/cloudflare.ini"
  mkdir -p "$(dirname "$CF_CRED")"
  cat > "$CF_CRED" <<CFC
dns_cloudflare_api_token = $CF_TOKEN
CFC
  chmod 600 "$CF_CRED"
  info "Requesting certificates for $WH and $NGROK via DNS challenge..."
  certbot certonly --noninteractive --agree-tos --email "$EMAIL" --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" -d "$WH" -d "$NGROK" || true
  if [[ -f "/etc/letsencrypt/live/$WH/fullchain.pem" || -f "/etc/letsencrypt/live/$NGROK/fullchain.pem" ]]; then
    ok "Certificates obtained via Cloudflare DNS."
    CERT_OK=true
    systemctl reload nginx || true
  else
    err "Certbot (DNS) failed — check /var/log/letsencrypt/*"
  fi
else
  if [[ "$RES_WH" == "$SERVER_IP" && "$RES_NG" == "$SERVER_IP" ]]; then
    info "Obtaining certificates using certbot --nginx (HTTP challenge) for $WH and $NGROK..."
    certbot --nginx -n --agree-tos --redirect --hsts -m "$EMAIL" -d "$WH" -d "$NGROK" || true
    if [[ -f "/etc/letsencrypt/live/$WH/fullchain.pem" ]]; then
      ok "Certificates obtained via certbot (HTTP)."
      CERT_OK=true
    else
      info "certbot did not produce certificates (maybe already present or failed). Check logs."
    fi
  else
    info "Skipping certbot HTTP challenge because domain(s) not pointed to this server. Use --cf-token for DNS challenge or run certbot later."
  fi
fi

# 13. Create cloudflared systemd unit (will run tunnel run <name> after deploy does login)
CF_SERVICE="/etc/systemd/system/cloudflared-tunnel.service"
if [[ ! -f "$CF_SERVICE" ]]; then
  info "Creating cloudflared systemd unit (cloudflared-tunnel.service)."
  cat > "$CF_SERVICE" <<CFU
[Unit]
Description=Cloudflare Tunnel
After=network-online.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/home/deploy
Environment=HOME=/home/deploy
ExecStart=/usr/bin/cloudflared tunnel run --no-autoupdate main-vds
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
CFU
  systemctl daemon-reload
  ok "cloudflared unit created (login required to create credentials file)."
fi

# 14. Start docker stack
info "Building and starting docker-compose stack..."
chown -R deploy:deploy "$INSTALL_DIR"
cd "$INSTALL_DIR"
docker compose build --no-cache || true
docker compose up -d
ok "Docker compose started."

# 15. Basic checks
sleep 5
info "Docker containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

info "Checking viavds health http://127.0.0.1:14127/health"
if curl -sSf http://127.0.0.1:14127/health >/dev/null 2>&1; then
  ok "viavds responded OK"
else
  info "viavds health failed or endpoint missing — check logs: docker compose logs -f viavds"
fi

# 16. Final instructions
cat <<FIN

Готово. Дальнейшие ручные шаги:

1) Cloudflared tunnel setup (interactive):
   sudo su - deploy
   cloudflared tunnel login      # откроет браузер, авторизуйся
   cloudflared tunnel create main-vds
   cloudflared tunnel route dns main-vds $NGROK
   sudo systemctl enable --now cloudflared-tunnel.service

   После route dns: ngrok.<zone> будет направлен на tunnel; затем можно запускать на локали cloudflared с credentials чтобы пробрасывать локальные порты.

2) Если certbot пропустил серт. (DNS не указывает), то:
   - при переключении A-записей доменов на IP сервера выполните:
     sudo certbot --nginx -d $WH -d $NGROK -m $EMAIL --agree-tos

   - либо повторно запустите скрипт с --cf-token <token> чтобы сделать DNS-challenge.

3) Полезные команды:
   cd $INSTALL_DIR
   docker compose logs -f
   docker compose up -d --build

4) Локальная разработка:
   - Для wh: настроить wh.<zone>.loc в /etc/hosts и mkcert сертификаты, проксировать локальный nginx -> 127.0.0.1:14127.
   - Для публичного проброса локали используйте cloudflared credentials, созданные на VDS.

FIN

ok "Installer finished. При проблемах пришли выводы: 'docker ps' и 'docker compose logs -f viavds' — помогу дебажить."

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Defaults (можно переопределить аргументами)
HOSTNAME="ngrok.vianl.ru"
PORT="14127"
TUNNEL_NAME="viavds"

usage() {
  cat <<EOF
Usage: sudo bash install_cloudflared.sh [--hostname <host>] [--port <port>] [--tunnel-name <name>]

Installs cloudflared (if missing), logs into Cloudflare, creates/uses a tunnel, adds DNS route,
writes /etc/cloudflared/config.yml and installs cloudflared as a systemd service.

Requires: sudo privileges, curl, dpkg
EOF
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --tunnel-name) TUNNEL_NAME="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

echo "------"
echo "Install Cloudflared & create tunnel"
echo "Hostname: $HOSTNAME"
echo "Port: $PORT"
echo "Tunnel name: $TUNNEL_NAME"
echo "------"

# ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script needs to be run with sudo/root."
  echo "Run: sudo bash $0 --hostname $HOSTNAME --port $PORT --tunnel-name $TUNNEL_NAME"
  exit 1
fi

# ensure curl exists
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found, installing..."
  apt-get update
  apt-get install -y curl ca-certificates
fi

# 1) install cloudflared via GitHub releases (works regardless repository presence)
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "amd64" ]]; then
  ASSET_NAME='cloudflared-linux-amd64.deb'
elif [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
  ASSET_NAME='cloudflared-linux-arm64.deb'
else
  echo "Unsupported architecture: $ARCH"
  exit 1
fi

echo "Detecting latest cloudflared release for $ASSET_NAME..."
API_URL="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "$ASSET_NAME" | head -n1 | cut -d '"' -f4)

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "ERROR: couldn't find cloudflared asset for $ASSET_NAME. You can install manually."
  exit 1
fi

echo "Download URL: $DOWNLOAD_URL"

TMPDEB="/tmp/cloudflared.deb"
echo "Downloading cloudflared to $TMPDEB ..."
curl -L -o "$TMPDEB" "$DOWNLOAD_URL"

echo "Installing cloudflared..."
dpkg -i "$TMPDEB" || apt-get install -f -y

rm -f "$TMPDEB"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "ERROR: cloudflared not installed."
  exit 1
fi

echo "cloudflared installed: $(cloudflared --version || true)"

# 2) cloudflared login (interactive)
echo
echo "Now we will run: cloudflared tunnel login"
echo "This will print a URL. Open it in your browser, login to Cloudflare and authorize access to your account/zones."
echo "Press ENTER to continue..."
read -r

cloudflared tunnel login || {
  echo "cloudflared tunnel login failed or was cancelled. Please run 'cloudflared tunnel login' manually as the same user and re-run this script."
  exit 1
}

# after login, credentials placed in ~/.cloudflared (or /root/.cloudflared if run as root)
CRED_DIR="/root/.cloudflared"
mkdir -p "$CRED_DIR"

# 3) create or find existing tunnel
echo "Creating tunnel named '$TUNNEL_NAME' (if it exists, we'll try to find its ID)..."
set +e
CREATE_OUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
CREATE_RC=$?
set -e
if [[ $CREATE_RC -eq 0 ]]; then
  # parse ID from create output like: "Created tunnel <name> with id <id>"
  TUNNEL_ID=$(echo "$CREATE_OUT" | grep -Eo '[0-9a-fA-F-]{36}' | head -n1)
  echo "Tunnel created: ID=$TUNNEL_ID"
else
  echo "Tunnel create returned non-zero status. Attempting to find existing tunnel by name..."
  # try to find existing tunnel id via list
  # cloudflared tunnel list prints a table; parse it
  TUNNEL_ID=$(cloudflared tunnel list --no-header 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2==name{print $1}' | head -n1 || true)
  if [[ -z "$TUNNEL_ID" ]]; then
    # fallback: try to parse from plain list output
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep -F "$TUNNEL_NAME" | awk '{print $1}' | head -n1 || true)
  fi
  if [[ -z "$TUNNEL_ID" ]]; then
    echo "ERROR: Could not create or find tunnel '$TUNNEL_NAME'. Output:"
    echo "$CREATE_OUT"
    exit 1
  else
    echo "Found existing tunnel: ID=$TUNNEL_ID"
  fi
fi

CRED_FILE="$CRED_DIR/$TUNNEL_ID.json"
# cloudflared creates credential file in ~/<user>/.cloudflared/<id>.json; if run as root, it's /root/.cloudflared
if [[ ! -f "$CRED_FILE" ]]; then
  # try to find it in home cloudflared dir
  FOUND=$(ls -1 ~/.cloudflared/*.json 2>/dev/null | head -n1 || true)
  if [[ -n "$FOUND" ]]; then
    CRED_FILE="$FOUND"
  fi
fi

echo "Using credentials file: $CRED_FILE"

# 4) create config.yml
CFG_PATH="/etc/cloudflared"
CFG_FILE="$CFG_PATH/config.yml"
mkdir -p "$CFG_PATH"

cat > "$CFG_FILE" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME
    service: http://localhost:$PORT
  - service: http_status:404
EOF

echo "Wrote config to $CFG_FILE:"
cat "$CFG_FILE"

# 5) create DNS route (CNAME)
echo "Creating DNS route for $HOSTNAME -> tunnel $TUNNEL_NAME (this will create a CNAME in Cloudflare)"
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || {
  echo "Warning: cloudflared tunnel route dns failed. You may not have permission to create DNS records or the record already exists. Please run manually:"
  echo "  cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME"
}

# 6) install systemd service (cloudflared)
echo "Installing cloudflared as a systemd service (this creates a service that uses /etc/cloudflared/config.yml)"
cloudflared service install || {
  echo "Warning: cloudflared service install failed. You can try to run:"
  echo "  sudo cloudflared --config $CFG_FILE run"
  echo "or install the service manually."
}

# 7) enable + start service
systemctl enable --now cloudflared || {
  echo "Warning: failed to enable/start cloudflared service. Check 'systemctl status cloudflared' for details."
}

echo
echo "Done. Tunnel should be running. Status:"
systemctl status cloudflared --no-pager

echo
echo "You can test from any external machine / browser:"
echo "https://$HOSTNAME/health"
echo
echo "If you want to see logs run:"
echo "sudo journalctl -u cloudflared -f"

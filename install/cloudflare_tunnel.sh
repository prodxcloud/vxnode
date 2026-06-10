#!/usr/bin/env bash
# =============================================================================
#  cloudflare_tunnel.sh — expose vxnode over HTTPS via a free Cloudflare Tunnel
#                         (Linux)
#
#  Installs cloudflared, authenticates to your Cloudflare account, creates a
#  named tunnel, points a hostname's DNS at it, and runs the tunnel. Cloudflare
#  terminates TLS with a managed cert — no open inbound ports, no Let's Encrypt.
#
#  Requires: a Cloudflare account with the target zone (e.g. vxcloud.io) added.
#
#  USAGE
#    bash cloudflare_tunnel.sh                          # uses defaults below
#    HOSTNAME=node1.example.com PORT=8744 bash cloudflare_tunnel.sh
#    RUN_AS_SERVICE=1 bash cloudflare_tunnel.sh         # install as a systemd service
#
#  macOS:   use cloudflare_tunnel_macos.sh
#  Windows: use cloudflare_tunnel.ps1
# =============================================================================
set -euo pipefail

# ── Config (env overrides) ─────────────────────────────────────────────────
TUNNEL_NAME="${TUNNEL_NAME:-vxnode}"
HOSTNAME="${HOSTNAME:-node1.vxcloud.io}"          # public hostname for the node
PORT="${PORT:-8744}"                              # local vxnode API port
RUN_AS_SERVICE="${RUN_AS_SERVICE:-0}"             # 1 = install as systemd service
LOCAL_URL="http://localhost:${PORT}"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ echo -e "${C_B}[cf-tunnel]${C_N} $*"; }
ok(){   echo -e "${C_G}[cf-tunnel] ✓${C_N} $*"; }
warn(){ echo -e "${C_Y}[cf-tunnel] !${C_N} $*"; }
die(){  echo -e "${C_R}[cf-tunnel] ✗${C_N} $*" >&2; exit 1; }

# ── 1 · Install cloudflared (Cloudflare apt repo) ──────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
    info "Installing cloudflared…"
    if command -v apt-get >/dev/null 2>&1; then
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        sudo apt-get update -y
        sudo apt-get install -y cloudflared
    else
        # Distro-agnostic fallback: grab the static binary for this arch.
        case "$(uname -m)" in
            x86_64|amd64) CF_ARCH=amd64 ;;
            aarch64|arm64) CF_ARCH=arm64 ;;
            armv7l) CF_ARCH=arm ;;
            *) die "Unsupported arch $(uname -m) — install cloudflared manually." ;;
        esac
        sudo curl -fsSL -o /usr/local/bin/cloudflared \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        sudo chmod +x /usr/local/bin/cloudflared
    fi
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
else
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -1)"
fi

# ── 2 · Authenticate (opens a browser to pick the zone; writes cert.pem) ───
if [ ! -f "${HOME}/.cloudflared/cert.pem" ]; then
    info "Logging in to Cloudflare (a browser window will open)…"
    cloudflared tunnel login
else
    ok "Already authenticated (~/.cloudflared/cert.pem present)."
fi

# ── 3 · Create the named tunnel (idempotent) ───────────────────────────────
if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
    ok "Tunnel '$TUNNEL_NAME' already exists."
else
    info "Creating tunnel '$TUNNEL_NAME'…"
    cloudflared tunnel create "$TUNNEL_NAME"
fi

# ── 4 · Route the hostname's DNS to the tunnel ─────────────────────────────
info "Routing DNS  $HOSTNAME  →  tunnel '$TUNNEL_NAME'…"
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || \
    warn "DNS route may already exist (or the zone for $HOSTNAME isn't in this account)."

# ── 5 · Run the tunnel ─────────────────────────────────────────────────────
if [ "$RUN_AS_SERVICE" = "1" ]; then
    # Persist a config so the systemd service knows what to serve, then install.
    CFG_DIR="/etc/cloudflared"
    sudo mkdir -p "$CFG_DIR"
    TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}')"
    sudo tee "$CFG_DIR/config.yml" >/dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${HOME}/.cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: ${HOSTNAME}
    service: ${LOCAL_URL}
  - service: http_status:404
EOF
    info "Installing cloudflared as a systemd service…"
    sudo cloudflared service install || true
    sudo systemctl enable --now cloudflared
    ok "Service running. Cloudflare now serves https://${HOSTNAME}"
    info "Logs:  sudo journalctl -u cloudflared -f"
else
    ok "Starting tunnel in the foreground. Cloudflare will serve https://${HOSTNAME}"
    info "(Ctrl-C to stop; re-run with RUN_AS_SERVICE=1 to keep it up across reboots.)"
    exec cloudflared tunnel run --url "$LOCAL_URL" "$TUNNEL_NAME"
fi

#!/usr/bin/env bash
# =============================================================================
#  cloudflare_tunnel_macos.sh — expose vxnode over HTTPS via a free Cloudflare
#                               Tunnel (macOS)
#
#  macOS variant of cloudflare_tunnel.sh. Installs cloudflared via Homebrew,
#  authenticates, creates a named tunnel, points a hostname's DNS at it, and
#  runs the tunnel (foreground, or as a launchd-managed brew service).
#  Cloudflare terminates TLS with a managed cert — no open inbound ports.
#
#  Requires: Homebrew (https://brew.sh) and a Cloudflare account with the
#  target zone (e.g. vxcloud.io) added.
#
#  USAGE
#    bash cloudflare_tunnel_macos.sh
#    HOSTNAME=node1.example.com PORT=8744 bash cloudflare_tunnel_macos.sh
#    RUN_AS_SERVICE=1 bash cloudflare_tunnel_macos.sh    # run via `brew services`
# =============================================================================
set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-vxnode}"
HOSTNAME="${HOSTNAME:-node1.vxcloud.io}"
PORT="${PORT:-8744}"
RUN_AS_SERVICE="${RUN_AS_SERVICE:-0}"
LOCAL_URL="http://localhost:${PORT}"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ printf "${C_B}[cf-tunnel]${C_N} %s\n" "$*"; }
ok(){   printf "${C_G}[cf-tunnel] ✓${C_N} %s\n" "$*"; }
warn(){ printf "${C_Y}[cf-tunnel] !${C_N} %s\n" "$*"; }
die(){  printf "${C_R}[cf-tunnel] ✗${C_N} %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || warn "This script targets macOS; for Linux use cloudflare_tunnel.sh."

# ── 1 · Install cloudflared via Homebrew ───────────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh and re-run."
    info "Installing cloudflared via Homebrew…"
    brew install cloudflared
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
else
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -1)"
fi

# ── 2 · Authenticate (opens a browser; writes cert.pem) ────────────────────
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
    CFG_DIR="${HOME}/.cloudflared"
    TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}')"
    cat > "$CFG_DIR/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CFG_DIR}/${TUNNEL_ID}.json
ingress:
  - hostname: ${HOSTNAME}
    service: ${LOCAL_URL}
  - service: http_status:404
EOF
    info "Starting cloudflared as a brew service (launchd, survives logout)…"
    brew services restart cloudflared 2>/dev/null || brew services start cloudflared
    ok "Service running. Cloudflare now serves https://${HOSTNAME}"
    info "Logs:  brew services info cloudflared   ·   tail -f ~/Library/Logs/cloudflared.log"
else
    ok "Starting tunnel in the foreground. Cloudflare will serve https://${HOSTNAME}"
    info "(Ctrl-C to stop; re-run with RUN_AS_SERVICE=1 to keep it up via launchd.)"
    exec cloudflared tunnel run --url "$LOCAL_URL" "$TUNNEL_NAME"
fi

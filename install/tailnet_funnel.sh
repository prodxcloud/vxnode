#!/usr/bin/env bash
# =============================================================================
#  tailnet_funnel.sh — expose vxnode publicly over HTTPS via Tailscale Funnel
#                      (Linux)
#
#  Installs Tailscale, joins your tailnet, and turns on Funnel so the local
#  vxnode API is reachable on the public internet over HTTPS (Tailscale
#  auto-issues the TLS cert). No Cloudflare account or DNS record needed —
#  Tailscale prints a `*.ts.net` hostname you register the node with.
#
#  Prereq: in the Tailscale admin console, enable HTTPS certificates and the
#  Funnel node attribute for this machine (https://tailscale.com/kb/1223/funnel).
#
#  USAGE
#    sudo bash tailnet_funnel.sh                 # uses defaults below
#    sudo PORT=8744 bash tailnet_funnel.sh
#
#  macOS:   use tailnet_funnel_macos.sh
#  Windows: use tailnet_funnel.ps1
# =============================================================================
set -euo pipefail

# ── Config (env overrides) ─────────────────────────────────────────────────
PORT="${PORT:-8744}"                  # local vxnode API port to expose
TS_AUTHKEY="${TS_AUTHKEY:-}"          # optional: unattended join (tskey-auth-…)

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ echo -e "${C_B}[tailnet]${C_N} $*"; }
ok(){   echo -e "${C_G}[tailnet] ✓${C_N} $*"; }
warn(){ echo -e "${C_Y}[tailnet] !${C_N} $*"; }
die(){  echo -e "${C_R}[tailnet] ✗${C_N} $*" >&2; exit 1; }

# ── 1 · Install Tailscale on the host running vxnode ───────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
    info "Installing Tailscale…"
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed: $(tailscale version 2>/dev/null | head -1)"
else
    ok "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
fi

# ── 2 · Bring the node onto your tailnet ───────────────────────────────────
if tailscale status >/dev/null 2>&1; then
    ok "Already logged in to a tailnet."
else
    info "Joining your tailnet…"
    if [ -n "$TS_AUTHKEY" ]; then
        sudo tailscale up --authkey "$TS_AUTHKEY"
    else
        info "(a browser link will be printed — open it to authenticate)"
        sudo tailscale up
    fi
fi

# ── 3 · Expose the vxnode API publicly with Funnel (HTTPS auto-issued) ─────
info "Enabling Tailscale Funnel on port ${PORT}…"
sudo tailscale funnel --bg "$PORT"

# ── 4 · Report the public hostname to register with vxcloud ────────────────
FQDN="$(tailscale status --json 2>/dev/null | grep -oE '"DNSName"[ ]*:[ ]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)\.?"$/\1/' | sed 's/\.$//')"
echo ""
if [ -n "$FQDN" ]; then
    ok "vxnode is now public at:  https://${FQDN}"
else
    ok "Funnel is on. Tailscale printed your public hostname above, e.g.:"
fi
info "  e.g.  https://node1.<your-tailnet>.ts.net"
info "Use that hostname when registering the node with vxcloud (app.vxcloud.io)."
info "Check / turn off:   sudo tailscale funnel status   ·   sudo tailscale funnel --${PORT} off"

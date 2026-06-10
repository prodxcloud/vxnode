#!/usr/bin/env bash
# =============================================================================
#  tailnet_funnel_macos.sh — expose vxnode publicly over HTTPS via Tailscale
#                            Funnel (macOS)
#
#  macOS variant of tailnet_funnel.sh. Installs the Tailscale CLI via Homebrew,
#  registers the background system daemon, joins your tailnet, and turns on
#  Funnel so the local vxnode API is reachable on the public internet over
#  HTTPS (Tailscale auto-issues the TLS cert).
#
#  Note: the Mac App Store / standalone Tailscale.app is GUI-only and does NOT
#  ship the `tailscale`/`tailscaled` CLI used here. This script uses the
#  Homebrew `tailscale` formula + a system daemon, which exposes the CLI.
#
#  Prereq: enable HTTPS certificates and the Funnel node attribute for this
#  machine in the admin console (https://tailscale.com/kb/1223/funnel).
#
#  USAGE
#    sudo bash tailnet_funnel_macos.sh
#    sudo PORT=8744 bash tailnet_funnel_macos.sh
# =============================================================================
set -euo pipefail

PORT="${PORT:-8744}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ printf "${C_B}[tailnet]${C_N} %s\n" "$*"; }
ok(){   printf "${C_G}[tailnet] ✓${C_N} %s\n" "$*"; }
warn(){ printf "${C_Y}[tailnet] !${C_N} %s\n" "$*"; }
die(){  printf "${C_R}[tailnet] ✗${C_N} %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || warn "This script targets macOS; for Linux use tailnet_funnel.sh."

# ── 1 · Install the Tailscale CLI via Homebrew ─────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh and re-run."
    info "Installing Tailscale CLI via Homebrew…"
    brew install tailscale
    ok "Tailscale installed: $(tailscale version 2>/dev/null | head -1)"
else
    ok "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
fi

# ── 2 · Register the system daemon (so tailscaled runs in the background) ──
if ! sudo launchctl list 2>/dev/null | grep -q com.tailscale.tailscaled; then
    info "Installing the tailscaled system daemon…"
    sudo tailscaled install-system-daemon
    ok "tailscaled daemon installed."
else
    ok "tailscaled daemon already running."
fi

# ── 3 · Bring the node onto your tailnet ───────────────────────────────────
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

# ── 4 · Expose the vxnode API publicly with Funnel (HTTPS auto-issued) ─────
info "Enabling Tailscale Funnel on port ${PORT}…"
sudo tailscale funnel --bg "$PORT"

# ── 5 · Report the public hostname to register with vxcloud ────────────────
FQDN="$(tailscale status --json 2>/dev/null | grep -oE '"DNSName"[ ]*:[ ]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)\.?"$/\1/' | sed 's/\.$//')"
echo ""
if [ -n "$FQDN" ]; then
    ok "vxnode is now public at:  https://${FQDN}"
else
    ok "Funnel is on. Tailscale printed your public hostname above."
fi
info "  e.g.  https://node1.<your-tailnet>.ts.net"
info "Use that hostname when registering the node with vxcloud (app.vxcloud.io)."
info "Check / turn off:   sudo tailscale funnel status   ·   sudo tailscale funnel --${PORT} off"

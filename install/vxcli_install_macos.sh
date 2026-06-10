#!/usr/bin/env bash
# =============================================================================
#  vxcli_install_macos.sh — install the vxcloud CLI (vxcli) on macOS
#
#  macOS variant of vxcli_install.sh. Works on both Apple Silicon (arm64) and
#  Intel (amd64) — the upstream installer auto-detects the architecture.
#
#  Prefers Homebrew when available (cleanest upgrade/uninstall path); otherwise
#  falls back to the official curl|sh installer, which drops the binary in
#  ~/.local/bin. Three aliases are installed: `vxcli`, `vx`, `vxcloud`.
#
#  Docs:  https://vxcloud.io/pages/web/self-hosted/   ·   https://vxcloud.io/download/cli
#
#  USAGE
#    bash vxcli_install_macos.sh
#    curl -fsSL https://vxcloud.io/download/cli/install.sh | sh   # upstream one-liner
#
#  Verify:  vxcli version
# =============================================================================
set -euo pipefail

INSTALLER_URL="${VXCLI_INSTALLER_URL:-https://vxcloud.io/download/cli/install.sh}"
BREW_FORMULA="${VXCLI_BREW_FORMULA:-vxcloud/tap/vxcli}"   # set VXCLI_BREW_FORMULA= to skip brew
INSTALL_BIN="${HOME}/.local/bin"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ printf "${C_B}[vxcli]${C_N} %s\n" "$*"; }
ok(){   printf "${C_G}[vxcli] ✓${C_N} %s\n" "$*"; }
warn(){ printf "${C_Y}[vxcli] !${C_N} %s\n" "$*"; }
die(){  printf "${C_R}[vxcli] ✗${C_N} %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || warn "This script targets macOS; for Linux use vxcli_install.sh."

if command -v vxcli >/dev/null 2>&1; then
    ok "vxcli already installed: $(vxcli version 2>/dev/null | head -1 || echo present)"
    info "Re-running to pick up any newer build…"
fi

installed_via=""

# ── Path 1: Homebrew (if present and a tap formula is configured) ──────────
if [ -n "$BREW_FORMULA" ] && command -v brew >/dev/null 2>&1; then
    info "Homebrew detected — installing via: brew install $BREW_FORMULA"
    if brew install "$BREW_FORMULA" 2>/dev/null; then
        installed_via="brew"
        ok "Installed via Homebrew."
    else
        warn "Homebrew install failed (tap may not be published) — falling back to the curl installer."
    fi
fi

# ── Path 2: official curl|sh installer ─────────────────────────────────────
if [ -z "$installed_via" ]; then
    command -v curl >/dev/null 2>&1 || die "curl not found. Install Xcode CLT (xcode-select --install) or Homebrew first."
    info "Installing vxcli from ${INSTALLER_URL} …"
    curl -fsSL "$INSTALLER_URL" | sh || die "vxcli install failed — see output above."
    installed_via="curl"

    # Ensure ~/.local/bin is on PATH (zsh is the macOS default shell).
    if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_BIN"; then
        export PATH="$INSTALL_BIN:$PATH"
        for rc in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
            [ -f "$rc" ] || touch "$rc"
            grep -q '.local/bin' "$rc" 2>/dev/null && continue
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        done
        info "Added $INSTALL_BIN to PATH (open a new terminal to pick it up)."
    fi

    # Gatekeeper: a freshly downloaded binary can carry the quarantine flag,
    # which triggers "cannot be opened because the developer cannot be verified".
    # Strip it so vxcli runs without a manual System Settings → Privacy override.
    if [ -f "$INSTALL_BIN/vxcli" ]; then
        xattr -d com.apple.quarantine "$INSTALL_BIN/vxcli" 2>/dev/null || true
    fi
fi

# ── Verify ─────────────────────────────────────────────────────────────────
if command -v vxcli >/dev/null 2>&1; then
    ok "Installed ($installed_via): $(vxcli version 2>/dev/null | head -1 || echo 'vxcli (version output empty)')"
    info "Aliases ready: vxcli · vx · vxcloud"
    info "Next:  vxcli login   then   vxcli node list"
else
    warn "vxcli installed but not on this shell's PATH yet."
    warn "Run:  export PATH=\"$INSTALL_BIN:\$PATH\"   (or open a new terminal)"
    exit 1
fi

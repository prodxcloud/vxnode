#!/usr/bin/env bash
# =============================================================================
#  vxcli_install.sh — install the vxcloud CLI (vxcli) on Linux
#
#  Pulls the prebuilt vxcli binary (amd64/arm64) from the public download
#  channel and puts it on your PATH. No Go toolchain, no build from source —
#  this is the same installer the vxnode container uses internally
#  (see tenant_setup.sh §"vxcli (vxcloud CLI) inside container").
#
#  Three aliases are installed for the same binary: `vxcli`, `vx`, `vxcloud`.
#
#  Docs:  https://vxcloud.io/pages/web/self-hosted/   ·   https://vxcloud.io/download/cli
#
#  USAGE
#    bash vxcli_install.sh                 # install for the current user
#    curl -fsSL https://vxcloud.io/download/cli/install.sh | sh   # upstream one-liner
#
#  Verify:  vxcli version
# =============================================================================
set -euo pipefail

# ── Config (env overrides) ─────────────────────────────────────────────────
INSTALLER_URL="${VXCLI_INSTALLER_URL:-https://vxcloud.io/download/cli/install.sh}"
INSTALL_BIN="${HOME}/.local/bin"

# ── Colored output ─────────────────────────────────────────────────────────
C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ echo -e "${C_B}[vxcli]${C_N} $*"; }
ok(){   echo -e "${C_G}[vxcli] ✓${C_N} $*"; }
warn(){ echo -e "${C_Y}[vxcli] !${C_N} $*"; }
die(){  echo -e "${C_R}[vxcli] ✗${C_N} $*" >&2; exit 1; }

# ── Already installed? ─────────────────────────────────────────────────────
if command -v vxcli >/dev/null 2>&1; then
    ok "vxcli already installed: $(vxcli version 2>/dev/null | head -1 || echo present)"
    info "Re-running the installer to pick up any newer build…"
fi

# ── Need a downloader ──────────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
    DL=(curl -fsSL)
elif command -v wget >/dev/null 2>&1; then
    DL=(wget -qO-)
else
    die "Neither curl nor wget found. Install one and re-run (e.g. sudo apt-get install -y curl)."
fi

# ── Run the upstream installer (drops the binary in ~/.local/bin) ──────────
info "Installing vxcli from ${INSTALLER_URL} …"
"${DL[@]}" "$INSTALLER_URL" | sh || die "vxcli install failed — see output above."

# ── Make sure ~/.local/bin is on PATH for future shells ────────────────────
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_BIN"; then
    export PATH="$INSTALL_BIN:$PATH"
    for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        grep -q '.local/bin' "$rc" 2>/dev/null && continue
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
    done
    info "Added $INSTALL_BIN to PATH (open a new shell, or: export PATH=\"$INSTALL_BIN:\$PATH\")"
fi

# ── Optional: system-wide symlinks if /usr/local/bin is writable ───────────
# Mirrors the container install — exposes vxcli on PATH for non-login shells.
if [ -x "$INSTALL_BIN/vxcli" ]; then
    for name in vxcli vx vxcloud; do
        if command -v sudo >/dev/null 2>&1; then
            sudo ln -sf "$INSTALL_BIN/vxcli" "/usr/local/bin/$name" 2>/dev/null || true
        elif [ -w /usr/local/bin ]; then
            ln -sf "$INSTALL_BIN/vxcli" "/usr/local/bin/$name" 2>/dev/null || true
        fi
    done
fi

# ── Verify ─────────────────────────────────────────────────────────────────
if command -v vxcli >/dev/null 2>&1; then
    ok "Installed: $(vxcli version 2>/dev/null | head -1 || echo 'vxcli (version output empty)')"
    info "Aliases ready: vxcli · vx · vxcloud"
    info "Next:  vxcli login   then   vxcli node list"
else
    warn "vxcli installed to $INSTALL_BIN but not yet on this shell's PATH."
    warn "Run:  export PATH=\"$INSTALL_BIN:\$PATH\"   (or open a new terminal)"
    exit 1
fi

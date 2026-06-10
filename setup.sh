#!/bin/bash
# =============================================================================
#  vxnode — setup.sh   (one-shot installer / orchestrator)
#
#  WHAT IT DOES
#    Runs, in order:
#      1) tenant_prerequisites.sh   — Docker, system packages, registry auth
#      2) tenant_setup.sh           — deploy vxnode container + nginx + tools
#    …either on THIS machine (local) or on a remote VM over SSH.
#
#  HOW TO USE
#    1. Clone this repo onto any machine (your laptop, a bastion, or the VM).
#    2. Fill in the VM CREDENTIALS block below:
#         - Remote VM?    -> set SSH_HOST + SSH_USER + (SSH_PASSWORD or SSH_KEY).
#         - This machine? -> leave SSH_HOST EMPTY (installs locally).
#    3. Run:  chmod +x setup.sh && ./setup.sh
#
#  Requires next to this script: tenant_prerequisites.sh, tenant_setup.sh
#  On the machine you RUN this from: bash, ssh, tar (+ sshpass if using a password).
# =============================================================================

# ##########################################################################
# #  FILL THIS IN  —  VM CREDENTIALS                                       #
# ##########################################################################
#
#   Leave SSH_HOST EMPTY  -> install on THIS machine (local).
#   Set SSH_HOST          -> install on that VM over SSH.
#   Authenticate with EITHER a password OR a key (fill whichever you use).
#
SSH_HOST=""                 # VM public IP / hostname.    EMPTY = local install
SSH_USER="ubuntu"           # SSH username (e.g. ubuntu, root, azureuser)
SSH_PASSWORD=""             # SSH password   (needs `sshpass` on this machine)
SSH_KEY=""                  # OR path to a private key (.pem). Leave blank if using a password
SSH_PORT="22"               # SSH port (default 22)

# ##########################################################################
# #  OPTIONAL — usually leave as-is                                        #
# ##########################################################################
# Domain/email are only needed if you want the node served over HTTPS on a
# real domain; leave blank to let tenant_setup.sh use its defaults.
DOMAIN=""                   # optional. bare hostname, e.g. node1.example.com
EMAIL=""                    # optional. email for Let's Encrypt SSL
# Docker Hub creds are DEMO values for the image pull — leave as-is.
DOCKER_USERNAME="vxcloud"   # demo
DOCKER_PAT=""               # demo (leave blank)
APP_PORT=""                 # optional. node API port (default 8744)

# ##########################################################################
# #  END FILL-IN — nothing to edit below this line                        #
# ##########################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREREQ_SH="tenant_prerequisites.sh"
SETUP_SH="tenant_setup.sh"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ echo -e "${C_B}[setup]${C_N} $*"; }
ok(){   echo -e "${C_G}[setup] OK${C_N} $*"; }
warn(){ echo -e "${C_Y}[setup] !${C_N} $*"; }
die(){  echo -e "${C_R}[setup] x${C_N} $*" >&2; exit 1; }

# -- Validate the bundle is intact --
[ -f "$SCRIPT_DIR/$PREREQ_SH" ] || die "$PREREQ_SH not found next to setup.sh ($SCRIPT_DIR)"
[ -f "$SCRIPT_DIR/$SETUP_SH" ]  || die "$SETUP_SH not found next to setup.sh ($SCRIPT_DIR)"

# -- Build the env passed to the tenant scripts (only the values that are set) --
# DOCKER_USERNAME always has a value, so these arrays/strings are never empty.
ENV_ARGS=("DOCKER_USERNAME=$DOCKER_USERNAME")
REMOTE_ENV="DOCKER_USERNAME='$DOCKER_USERNAME'"
add_env(){ # $1=name $2=value
    [ -n "$2" ] || return 0
    ENV_ARGS+=("$1=$2")
    REMOTE_ENV="$REMOTE_ENV $1='$2'"
}
add_env DOCKER_PAT "$DOCKER_PAT"
add_env DOMAIN     "$DOMAIN"
add_env EMAIL      "$EMAIL"
add_env APP_PORT   "$APP_PORT"

# =============================================================================
if [ -z "$SSH_HOST" ]; then
    # ----------------------------- LOCAL INSTALL -----------------------------
    info "SSH_HOST empty -> installing on THIS machine (local)."
    command -v sudo >/dev/null 2>&1 || die "sudo is required for a local install"

    info "Step 1/2 - prerequisites ($PREREQ_SH) ..."
    sudo "${ENV_ARGS[@]}" bash "$SCRIPT_DIR/$PREREQ_SH" || die "prerequisites failed"
    ok "prerequisites complete"

    info "Step 2/2 - vxnode setup ($SETUP_SH) ..."
    sudo "${ENV_ARGS[@]}" bash "$SCRIPT_DIR/$SETUP_SH" || die "tenant_setup failed"
    ok "vxnode installed on this machine"
else
    # ----------------------------- REMOTE INSTALL (SSH) ----------------------
    info "SSH_HOST=$SSH_HOST -> installing on remote VM as '$SSH_USER'."
    command -v ssh >/dev/null 2>&1 || die "ssh not found on this machine"
    command -v tar >/dev/null 2>&1 || die "tar not found on this machine"

    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -p "$SSH_PORT")

    # Choose auth: password (via sshpass) takes precedence if set, else key, else agent.
    if [ -n "$SSH_PASSWORD" ]; then
        command -v sshpass >/dev/null 2>&1 || die "SSH_PASSWORD is set but 'sshpass' is not installed on this machine.
       Install it:  Ubuntu/Debian: sudo apt-get install -y sshpass | macOS: brew install hudochenkov/sshpass/sshpass | Git-Bash: use SSH_KEY instead.
       Or clear SSH_PASSWORD and use SSH_KEY."
        SSH_BASE=(sshpass -p "$SSH_PASSWORD" ssh)
        SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
        REMOTE_SUDO="echo '$SSH_PASSWORD' | sudo -S -p ''"   # feed sudo the password (non-passwordless VMs)
    elif [ -n "$SSH_KEY" ]; then
        [ -f "$SSH_KEY" ] || die "SSH_KEY not found: $SSH_KEY"
        chmod 600 "$SSH_KEY" 2>/dev/null || true   # ssh rejects world-readable keys
        SSH_BASE=(ssh)
        SSH_OPTS+=(-i "$SSH_KEY")
        REMOTE_SUDO="sudo"                          # cloud VMs: passwordless sudo
    else
        SSH_BASE=(ssh)
        REMOTE_SUDO="sudo"
        warn "No SSH_PASSWORD or SSH_KEY set — relying on ssh-agent / default key."
    fi
    REMOTE="$SSH_USER@$SSH_HOST"
    REMOTE_DIR="/tmp/vxnode-install"

    info "Testing SSH connection to $REMOTE ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" 'true' >/dev/null 2>&1 \
        || die "SSH connection failed to $REMOTE (check host/user/password/key/port, and that the VM allows port $SSH_PORT)"
    ok "SSH reachable"

    info "Copying install bundle to $REMOTE:$REMOTE_DIR ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'" \
        || die "could not prepare $REMOTE_DIR on the VM"
    # tar this script's whole directory (the cloned bundle), minus git/log cruft,
    # and stream it over ssh — tenant_setup.sh references sibling files, so the
    # whole bundle must land on the VM, not just the two scripts.
    tar -czf - -C "$SCRIPT_DIR" --exclude='.git' --exclude='*.log' . \
        | "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" "tar -xzf - -C '$REMOTE_DIR'" \
        || die "bundle copy failed"
    ok "bundle copied"

    info "Step 1/2 - prerequisites on VM ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "cd '$REMOTE_DIR' && $REMOTE_SUDO $REMOTE_ENV bash $PREREQ_SH" \
        || die "remote prerequisites failed"
    ok "prerequisites complete on VM"

    info "Step 2/2 - vxnode setup on VM ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
        "cd '$REMOTE_DIR' && $REMOTE_SUDO $REMOTE_ENV bash $SETUP_SH" \
        || die "remote tenant_setup failed"
    ok "vxnode installed on $SSH_HOST"
fi

echo
ok "DONE."
info "Verify the node:"
info "   curl -fsS http://127.0.0.1:8744/api/v2/health   (on the VM — health)"
info "   docker exec vxcloud-vxnode vxcli version         (CLI inside the container)"

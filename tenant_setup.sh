#!/bin/bash

# =============================================================================
#
#  vxcloud Tenant Setup — Single-Script VM Provisioner
#
#  What it does:
#    1. Deploys vxcloud/vxnode:latest via embedded docker-compose
#    2. Installs Nginx as reverse proxy
#    3. Obtains real Let's Encrypt SSL certificate via Certbot
#    4. Configures HTTPS auto-redirect + auto-renewal
#
#  Prerequisites:
#    - Ubuntu 20.04 / 22.04 / 24.04 with Docker + Docker Compose already installed
#    - Root or sudo access
#    - DNS A record pointing the domain to this VM's IP BEFORE running
#    - Ports 80, 443, 8443, and 18789 open in security group / firewall
#
#  Usage:
#    chmod +x tenant_setup.sh
#    sudo ./tenant_setup.sh
#
#  Docker Hub login is AUTOMATIC (vxcloud/vxnode is a private image) — it runs
#  before any image pull. To override the baked-in service-account credentials,
#  pass them at runtime (recommended over editing this file):
#    sudo DOCKER_USERNAME=vxcloud DOCKER_PAT=dckr_pat_xxx ./tenant_setup.sh
#
#  Or with custom domain/email:
#    sudo DOMAIN="custom.vxcloud.space" EMAIL="joelwembo@outlook.com" ./tenant_setup.sh
#
#  Execution order:
#
#  tenant_setup.sh (run first)
#    ├── Deploys vxnode container → port 8744 (HTTP inside)
#    ├── Nginx: port 80 → 8744, port 443 (SSL) → 8744
#    ├── Nginx: port 8443 (SSL) → 127.0.0.1:8089   ← IDE (prepared, enabled after cert)
#    ├── Nginx: port 18789 (SSL) → 127.0.0.1:18790  ← OpenClaw (prepared, enabled after cert)
#    └── Certbot: gets cert for $DOMAIN, shares with all server blocks
#
#  openvscode-server-one-time-installer.sh (run second, optional)
#    └── Deploys openvscode container → 127.0.0.1:8089
#         (nginx already proxies https://$DOMAIN:8443 → here)
#
#  openclaw_vm_installer.sh (run third, optional)
#    └── Deploys OpenClaw gateway → 127.0.0.1:18790
#         (nginx already proxies https://$DOMAIN:18789 → here)
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — Override via environment variables if needed
# =============================================================================
DOMAIN="${DOMAIN:-bop9c2werwerd7c6b5a2.testprodxcloud.space}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"
if [[ "$DOMAIN" =~ [:/] ]] || [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "[ERROR] Invalid domain: '$DOMAIN' — must be a bare hostname (e.g. clo000c2werwer3f5a0b9e8d7c6b5a2.prodxcloud.space)"
    exit 1
fi
EMAIL="${EMAIL:-joelwembo@outlook.com}"
APP_PORT="${APP_PORT:-8744}"
IDE_PORT="${IDE_PORT:-8443}"
IDE_BACKEND_PORT="${IDE_BACKEND_PORT:-8089}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_BACKEND_PORT="${OPENCLAW_BACKEND_PORT:-18790}"
DOCKER_IMAGE="${DOCKER_IMAGE:-vxcloud/vxnode:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-vxcloud-vxnode}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/vxcloud}"

# ── Multi-arch auto-recovery fallback ──
# If pulling $DOCKER_IMAGE fails for THIS host's architecture (usual cause:
# :latest on the registry is momentarily single-arch amd64 while this is an
# arm64 / Graviton / Ampere VM), the script AUTOMATICALLY pulls this known
# multi-arch reference instead — a manifest LIST that includes amd64 + arm64 —
# and re-tags it locally as $DOCKER_IMAGE. Docker picks the correct arch from
# the list, so the same script "just works" on amd64 and arm64 with no manual
# steps. This is a SAFETY NET; the real fix is keeping :latest itself multi-arch
# (docker buildx ... --platform linux/amd64,linux/arm64 --push). Update this
# digest after each new prod multi-arch build, point it at a stable multi-arch
# tag, or set it empty to disable auto-recovery.
DOCKER_IMAGE_FALLBACK="${DOCKER_IMAGE_FALLBACK:-vxcloud/vxnode@sha256:c80c4c9fb6fb2bdf35ed8fad8c978cf1f12c7ab7dcded6dcbbaec769f40a1f6c}"

# ── Optional GitHub clones (non-essential to the core vxnode deploy) ──
# Both steps below clone from public github.com during provisioning:
#   INSTALL_BOOTSTRAP        -> shell-bootstrap-lite shell utilities (STEP 3b)
#   INSTALL_STUDIO_TEMPLATES -> va_studio_* templates             (STEP 3c)
# Set either to "false" to skip its git clone (e.g. air-gapped VMs, repo
# unreachable, or piped/stdin runs). Skipping them does NOT affect the vxnode
# container, Nginx, or SSL setup.
#   sudo INSTALL_BOOTSTRAP=false INSTALL_STUDIO_TEMPLATES=false ./tenant_setup.sh
INSTALL_BOOTSTRAP="${INSTALL_BOOTSTRAP:-true}"
INSTALL_STUDIO_TEMPLATES="${INSTALL_STUDIO_TEMPLATES:-true}"

# ── Docker Hub authentication ──
# vxcloud/vxnode is a PRIVATE Docker Hub repo, so we must authenticate before
# pulling the image. Defaults to the vxcloud service account; override at
# runtime instead of editing this file (keeps the token off disk):
#   sudo DOCKER_USERNAME=vxcloud DOCKER_PAT=dckr_pat_xxx ./tenant_setup.sh
DOCKER_USERNAME="${DOCKER_USERNAME:-vxcloud}"
DOCKER_PAT="${DOCKER_PAT:-}"

# Auto-size vxnode container resource limits for the host.
# Docker rejects --cpus > host CPU count, so default to 0.5 on a 1-vCPU box
# (leaves room for nginx + the openvscode container that runs on the same host).
# Override on bigger VMs: VXNODE_CPUS=2 VXNODE_MEMORY=1g ./tenant_setup.sh
_HOST_CPUS=$(nproc 2>/dev/null || echo 1)
if [ "${_HOST_CPUS}" -le 1 ]; then
    VXNODE_CPUS="${VXNODE_CPUS:-0.5}"
    VXNODE_MEMORY="${VXNODE_MEMORY:-384m}"
else
    VXNODE_CPUS="${VXNODE_CPUS:-1.0}"
    VXNODE_MEMORY="${VXNODE_MEMORY:-512m}"
fi

# =============================================================================
# COLORS & LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Wait for apt/dpkg lock (Ubuntu auto-updater can hold it)
wait_for_apt() {
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log_info "Waiting for dpkg lock (unattended-upgrades)..."
        sleep 5
    done
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Verify Docker is installed
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Install Docker first, then re-run this script."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin not found. Install docker-compose-plugin first."
    exit 1
fi

log_success "Docker: $(docker --version)"
log_success "Compose: $(docker compose version --short)"

# =============================================================================
# DOCKER HUB AUTHENTICATION  (must run BEFORE any image pull / deploy)
# =============================================================================
# vxcloud/vxnode is a private image. Authenticate now so the pull in STEP 3
# (and any other registry access) succeeds on a fresh VM. Token is piped via
# --password-stdin so it never appears in the process list. Non-fatal by
# design: if login fails we warn and continue (the image may already be cached
# locally), so this never breaks an in-progress or re-run deployment.
if [ -n "${DOCKER_PAT}" ]; then
    log_info "Authenticating to Docker Hub as '${DOCKER_USERNAME}' (private image)..."
    if printf '%s' "${DOCKER_PAT}" | docker login -u "${DOCKER_USERNAME}" --password-stdin >/dev/null 2>&1; then
        log_success "Docker Hub authenticated as '${DOCKER_USERNAME}'"
    else
        log_warn "Docker Hub login failed for '${DOCKER_USERNAME}' — continuing anyway"
        log_warn "If the image is private and not cached locally, the pull in STEP 3 will fail."
        log_warn "Re-run with valid creds: sudo DOCKER_USERNAME=... DOCKER_PAT=... ./tenant_setup.sh"
    fi
else
    log_warn "No DOCKER_PAT provided — skipping Docker Hub login (assuming public or cached image)"
fi

log_info "============================================"
log_info "  vxcloud Tenant Setup"
log_info "  Domain   : $DOMAIN"
log_info "  Email    : $EMAIL"
log_info "  Image    : $DOCKER_IMAGE"
log_info "  App Port : $APP_PORT"
log_info "  IDE Port : $IDE_PORT (HTTPS) -> $IDE_BACKEND_PORT (container, managed separately)"
log_info "  OC Port  : $OPENCLAW_PORT (HTTPS) -> $OPENCLAW_BACKEND_PORT (OpenClaw gateway, managed separately)"
log_info "  Host CPUs: ${_HOST_CPUS} -> vxnode limits: ${VXNODE_CPUS} CPU / ${VXNODE_MEMORY} RAM"
log_info "============================================"

# Verify DNS resolution points to this machine
VM_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com || curl -s --max-time 5 http://ifconfig.me || echo "unknown")
log_info "This VM's public IP: $VM_IP"

DNS_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || echo "unresolvable")
if [ "$DNS_IP" = "$VM_IP" ]; then
    log_success "DNS $DOMAIN -> $DNS_IP (matches this VM)"
elif [ "$DNS_IP" = "unresolvable" ] || [ -z "$DNS_IP" ]; then
    log_warn "Cannot resolve $DOMAIN yet. DNS may still be propagating."
    log_warn "Certbot will fail if DNS is not pointing here. Proceeding anyway..."
else
    log_warn "DNS $DOMAIN -> $DNS_IP but this VM is $VM_IP"
    log_warn "SSL certificate request may fail. Proceeding anyway..."
fi

# =============================================================================
# STEP 1: SYSTEM PACKAGES & PREREQUISITES
# =============================================================================
export DEBIAN_FRONTEND=noninteractive

log_info "Updating package lists..."
wait_for_apt
apt-get update

log_info "Installing base packages..."
wait_for_apt
apt-get install -y \
    ca-certificates curl wget gnupg lsb-release unzip \
    software-properties-common apt-transport-https dnsutils \
    vim jq lsof git
log_success "Base packages installed"

# ── Networking tools ──
log_info "Installing networking tools..."
wait_for_apt
apt-get install -y net-tools iputils-ping iproute2
log_success "Networking tools: netstat, ping, ip"

# ── Python 3 + pip ──
log_info "Installing Python 3 + pip..."
if ! command -v python3 &> /dev/null; then
    apt-get install -y python3 python3-pip python3-venv
else
    log_success "Python3 already installed: $(python3 --version)"
    apt-get install -y python3-pip python3-venv 2>/dev/null || true
fi
log_success "Python: $(python3 --version), pip: $(pip3 --version 2>/dev/null | awk '{print $2}' || echo 'installed')"

# ── Docker Compose v2 plugin ──
if docker compose version &> /dev/null; then
    log_success "Docker Compose already installed: $(docker compose version --short)"
else
    COMPOSE_VERSION="${COMPOSE_VERSION:-2.27.1}"
    log_info "Installing Docker Compose v${COMPOSE_VERSION}..."
    mkdir -p /usr/local/lib/docker/cli-plugins/
    wget -O /usr/local/lib/docker/cli-plugins/docker-compose \
        "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64"
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    log_success "Docker Compose installed: $(docker compose version --short)"
fi

# ── Verify all prerequisites ──
log_info "Verifying prerequisites..."
PREREQS_OK=true
for cmd in docker python3 pip3 curl wget jq vim lsof git netstat ping ip; do
    if command -v "$cmd" &> /dev/null; then
        log_success "  $cmd"
    else
        log_error "  $cmd — MISSING"
        PREREQS_OK=false
    fi
done

if [ "$PREREQS_OK" = false ]; then
    log_error "Some prerequisites are missing. Check the output above."
    exit 1
fi
log_success "All prerequisites verified"

# =============================================================================
# STEP 2: CREATE DEPLOYMENT DIRECTORY & EMBEDDED DOCKER-COMPOSE
# =============================================================================
log_info "Setting up deployment directory: $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR/generated"

# /app/generated is bind-mounted from $DEPLOY_DIR/generated. The hardened vxnode
# container (cap_drop: ALL, no-new-privileges) runs as a non-root user, so a
# root:root 755 host dir blocks `mkdir generated/<session-id>` inside the
# container with EACCES. VM_ACCESS_LEVEL_MAP.md documents this path as 777
# (per-request Terraform workspaces — runtime-writable). Enforce it on the host
# side so the bind mount inherits the documented permissions.
chmod 777 "$DEPLOY_DIR/generated"

cat > "$DEPLOY_DIR/docker-compose.yml" << COMPOSE_EOF
# =============================================================================
#  vxcloud vxnode — Production Container (managed by setup_tenant.sh)
#  SSL is handled by Nginx + Let's Encrypt on the host, NOT inside Docker.
# =============================================================================
services:

  vxnode:
    container_name: ${CONTAINER_NAME}
    image: ${DOCKER_IMAGE}
    restart: unless-stopped
    cpus: ${VXNODE_CPUS}
    mem_limit: ${VXNODE_MEMORY}
    environment:
      - GIN_MODE=release
      - PORT=${APP_PORT}
      # Fleet self-update: in-binary listener polls the channel JSON every 5
      # minutes and writes a trigger file under /app/generated/ when the
      # desired image digest differs from the running one. The host-side
      # vxnode-update.timer installed in STEP 7b reads that trigger and swaps
      # the container. Override per-VM:
      #   sudo VXNODE_AUTO_UPDATE=false ./tenant_setup.sh
      #   sudo VXNODE_UPDATE_CHANNEL_URL=https://vxcloud.io/download/vxnode/canary.json ./tenant_setup.sh
      - VXNODE_AUTO_UPDATE=${VXNODE_AUTO_UPDATE:-true}
      - VXNODE_UPDATE_CHANNEL_URL=${VXNODE_UPDATE_CHANNEL_URL:-https://vxcloud.io/download/vxnode/stable.json}
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${APP_PORT}/api/v2/health"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 5s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DEPLOY_DIR}/generated:/app/generated
    tmpfs:
      - /tmp:size=64M
    pids_limit: 100
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_EOF

log_success "docker-compose.yml created at $DEPLOY_DIR/"

# =============================================================================
# STEP 3: FREE PORT & DEPLOY CONTAINER
# =============================================================================
log_info "Checking for conflicts on port $APP_PORT..."

# Stop any existing container (compose down first, then fallback to direct stop)
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_warn "Existing container found — tearing down..."
    cd "$DEPLOY_DIR"
    docker compose down 2>/dev/null || true

    # Fallback: stop container directly if compose down didn't catch it
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Stopping leftover container: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi
fi

# Kill any non-docker process on the app port
if command -v lsof &> /dev/null; then
    PIDS=$(lsof -ti :"$APP_PORT" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        for PID in $PIDS; do
            PNAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
            if echo "$PNAME" | grep -qE "^(systemd|sshd|init)$"; then
                log_warn "Skipping critical process $PNAME (PID $PID)"
            else
                log_warn "Killing $PNAME (PID $PID) on port $APP_PORT"
                kill -9 "$PID" 2>/dev/null || true
            fi
        done
        sleep 2
    fi
fi

HOST_ARCH="$(uname -m)"
log_info "Pulling latest image: $DOCKER_IMAGE (host arch: ${HOST_ARCH})..."
if docker pull "$DOCKER_IMAGE"; then
    log_success "Image pulled from registry: $DOCKER_IMAGE"
elif [ -n "${DOCKER_IMAGE_FALLBACK}" ] && [ "${DOCKER_IMAGE_FALLBACK}" != "${DOCKER_IMAGE}" ] && docker pull "${DOCKER_IMAGE_FALLBACK}"; then
    # AUTO-RECOVERY: the normal pull failed — almost always because :latest on the
    # registry is currently single-arch amd64 while this is a ${HOST_ARCH} host.
    # DOCKER_IMAGE_FALLBACK is a multi-arch manifest LIST; docker just pulled the
    # variant matching this host. Re-tag it as $DOCKER_IMAGE so the rest of the
    # script (docker-compose, etc.) needs no changes.
    docker tag "${DOCKER_IMAGE_FALLBACK}" "${DOCKER_IMAGE}"
    log_warn "Registry '$DOCKER_IMAGE' had no ${HOST_ARCH} manifest — auto-recovered via multi-arch fallback:"
    log_warn "  pulled : ${DOCKER_IMAGE_FALLBACK}"
    log_warn "  tagged : ${DOCKER_IMAGE}  (${HOST_ARCH})"
    log_success "Using multi-arch fallback image for ${HOST_ARCH}"
elif docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    # Neither the registry tag nor the fallback was pullable, but an image with
    # this tag already exists locally (e.g. side-loaded via 'docker load') — use it.
    log_warn "Could not pull $DOCKER_IMAGE or the fallback — using the LOCAL image already on this host."
    log_warn "(Registry has no ${HOST_ARCH} manifest; using a locally present / side-loaded image.)"
else
    log_error "Could not obtain $DOCKER_IMAGE for this host's architecture (${HOST_ARCH})."
    log_error "Tried registry pull, multi-arch fallback (${DOCKER_IMAGE_FALLBACK:-none}), and a local image — all failed."
    case "$HOST_ARCH" in
        aarch64|arm64)
            log_error ""
            log_error "This ARM64 host has no usable image: registry '$DOCKER_IMAGE' is amd64-only AND the"
            log_error "multi-arch fallback could not be pulled (stale/GC'd digest, or Docker Hub auth failed)."
            log_error "Tenant VMs must NEVER build (source must not touch a tenant). Fix on your BUILD host:"
            log_error "  - Publish a multi-arch :latest:  docker buildx build --platform linux/amd64,linux/arm64 \\"
            log_error "      -t $DOCKER_IMAGE --build-arg MODE=prod --push ."
            log_error "  - Or point to a good fallback:  sudo DOCKER_IMAGE_FALLBACK=vxcloud/vxnode@sha256:<list> ./tenant_setup.sh"
            log_error "  - Or side-load: docker save <arm64-image>|gzip>x.tgz; copy here; gunzip -c x.tgz|docker load; re-run."
            ;;
        *)
            log_error "Check Docker Hub auth and that '$DOCKER_IMAGE' (or the fallback) has a ${HOST_ARCH} manifest."
            ;;
    esac
    exit 1
fi

log_info "Starting container via docker compose..."
cd "$DEPLOY_DIR"
docker compose up -d

# Wait for app to respond (fast poll — 2s intervals, 15 tries = 30s max)
log_info "Waiting for app to start..."
RETRIES=0
MAX_RETRIES=15
while [ $RETRIES -lt $MAX_RETRIES ]; do
    if curl -sf --max-time 2 "http://127.0.0.1:${APP_PORT}/api/v2/health" > /dev/null 2>&1; then
        log_success "App is up (took ~$((RETRIES * 2))s)"
        break
    fi
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -eq $MAX_RETRIES ]; then
        log_warn "App not responding after 30s — continuing anyway"
        docker logs "$CONTAINER_NAME" --tail 10 2>/dev/null || true
    fi
    sleep 2
done

# Smoke test — app serves plain HTTP inside Docker, SSL is on the host
if curl -sf --max-time 5 "http://127.0.0.1:${APP_PORT}/api/v2/health" > /dev/null 2>&1; then
    log_success "App responding on http://127.0.0.1:${APP_PORT}"
else
    log_warn "App not responding yet — nginx setup will proceed"
fi

# =============================================================================
# STEP 3b: BOOTSTRAP SHELL UTILITIES INTO CONTAINER  (optional GitHub clone)
# =============================================================================
BOOTSTRAP_REPO="https://github.com/prodxcloud/shell-bootstrap-lite.git"
CONTAINER_GENERATED="/app/generated"

if [ "$INSTALL_BOOTSTRAP" = true ]; then
    log_info "Cloning shell-bootstrap-lite into container ${CONTAINER_NAME}:${CONTAINER_GENERATED}/..."

    # Clone into a temp dir on the host, then copy into the running container
    TMPDIR_BOOTSTRAP=$(mktemp -d)
    if git clone --depth 1 "$BOOTSTRAP_REPO" "$TMPDIR_BOOTSTRAP/shell-bootstrap-lite"; then
        # Copy the packages/ folder into the container's /app/generated/packages/
        docker cp "$TMPDIR_BOOTSTRAP/shell-bootstrap-lite/packages" "${CONTAINER_NAME}:${CONTAINER_GENERATED}/packages"

        # Make all scripts executable inside the container
        docker exec "$CONTAINER_NAME" chmod -R +x "${CONTAINER_GENERATED}/packages/" 2>/dev/null || true

        log_success "Shell utilities installed in container at ${CONTAINER_GENERATED}/packages/"
        log_info "  Scripts available:"
        docker exec "$CONTAINER_NAME" ls -1 "${CONTAINER_GENERATED}/packages/" 2>/dev/null | while read -r f; do
            log_info "    ${CONTAINER_GENERATED}/packages/$f"
        done
    else
        log_warn "Failed to clone $BOOTSTRAP_REPO — skipping shell utilities"
    fi
    rm -rf "$TMPDIR_BOOTSTRAP"
else
    log_info "Skipping shell-bootstrap-lite clone (INSTALL_BOOTSTRAP=$INSTALL_BOOTSTRAP)"
fi

# =============================================================================
# STEP 3c: BOOTSTRAP STUDIO TEMPLATES INTO CONTAINER  (optional GitHub clone)
# =============================================================================
# Runs shared/studio/pull_studio_templates.sh (local, sibling of bin/) to
# fetch every public va_studio_* repo directly from github.com/vxcloud,
# then copies the populated folder into the container at
# /app/generated/studio/.
if [ "$INSTALL_STUDIO_TEMPLATES" = true ]; then
    # Resolve this script's own directory. BASH_SOURCE[0] is unset when the
    # script is piped to bash (e.g. `ssh vm 'bash -s' < tenant_setup.sh` or
    # `curl ... | bash`); `${BASH_SOURCE[0]:-$0}` supplies a fallback so
    # `set -u` doesn't abort, and the `|| echo ""` keeps `set -e` happy when the
    # directory can't be resolved (in which case the puller below won't exist
    # and we skip gracefully).
    TENANT_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
    STUDIO_SRC="$TENANT_SETUP_DIR/../shared/studio"
    STUDIO_PULLER="$STUDIO_SRC/pull_studio_templates.sh"
    CONTAINER_STUDIO="/app/generated/studio"

    if [[ -n "$TENANT_SETUP_DIR" && -f "$STUDIO_PULLER" ]]; then
        log_info "Running $STUDIO_PULLER (pulls public va_studio_* repos — may take a few minutes)..."
        if ( cd "$STUDIO_SRC" && bash ./pull_studio_templates.sh ); then
            log_success "Studio templates pulled on host"
        else
            log_warn "Some studio repos failed to pull — copying what was fetched"
        fi

        docker exec "$CONTAINER_NAME" mkdir -p "$CONTAINER_STUDIO" 2>/dev/null || true
        docker cp "$STUDIO_SRC/." "${CONTAINER_NAME}:${CONTAINER_STUDIO}/"

        log_success "Studio templates installed in container at ${CONTAINER_STUDIO}/"
        log_info "  Templates available (showing first 10):"
        docker exec "$CONTAINER_NAME" bash -c "ls -1d ${CONTAINER_STUDIO}/va_studio_* 2>/dev/null | head -n 10" | while read -r d; do
            log_info "    $d"
        done
        TEMPLATE_COUNT=$(docker exec "$CONTAINER_NAME" bash -c "ls -1d ${CONTAINER_STUDIO}/va_studio_* 2>/dev/null | wc -l" | tr -d ' \r')
        log_info "  Total templates: ${TEMPLATE_COUNT}"
    else
        log_warn "pull_studio_templates.sh not found at $STUDIO_PULLER — skipping studio templates"
        log_warn "(this is expected when the script is run standalone/piped without the repo tree alongside it)"
    fi
else
    log_info "Skipping studio templates clone (INSTALL_STUDIO_TEMPLATES=$INSTALL_STUDIO_TEMPLATES)"
fi

# =============================================================================
# STEP 4: INSTALL & CONFIGURE NGINX
# =============================================================================
log_info "Installing Nginx..."
wait_for_apt
apt-get install -y -qq nginx > /dev/null 2>&1
systemctl start nginx
systemctl enable nginx
log_success "Nginx installed"

NGINX_CONF="/etc/nginx/sites-available/vxcloud-tenant"
log_info "Writing Nginx reverse proxy config for $DOMAIN..."
cat > "$NGINX_CONF" << NGINX_EOF
# Managed by setup_tenant.sh — do not edit manually
# Certbot will modify this file to add SSL configuration

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';

        # Forward real client info
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # Timeouts (5 min for long-running provisioning requests)
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;

        # Buffering
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX_EOF

# Enable site, remove default, disable IDE/OpenClaw until cert exists (avoids nginx -t failure)
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/vxcloud-ide
rm -f /etc/nginx/sites-enabled/vxcloud-openclaw
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

# ── OpenVSCode Server (IDE) reverse proxy — same domain, port 8089 with SSL ──
# NOTE: SSL cert paths are placeholders; certbot populates them in STEP 5.
# This block is written early so nginx -t can validate structure.
NGINX_IDE_CONF="/etc/nginx/sites-available/vxcloud-ide"
log_info "Writing Nginx reverse proxy config for IDE on port $IDE_PORT..."
cat > "$NGINX_IDE_CONF" << NGINX_IDE_EOF
# Managed by setup_tenant.sh — OpenVSCode Server (IDE)
# Same domain as vxnode, different port ($IDE_PORT) with SSL

server {
    listen ${IDE_PORT} ssl;
    listen [::]:${IDE_PORT} ssl;
    server_name $DOMAIN;

    # SSL certs — shared with the main vxnode site (managed by certbot)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:${IDE_BACKEND_PORT};
        proxy_http_version 1.1;

        # ── Cross-origin iframe embedding ─────────────────────────────────
        # The dashboard (e.g. http://localhost:3000 in dev, app.vxcloud.com
        # in prod) embeds this IDE in an iframe. Without these two flags the
        # browser refuses to send openvscode-server's auth cookie on the
        # post-token redirect (cross-site SameSite=Lax block) and you get
        # "Forbidden" inside the iframe even though /?tkn=... validated fine.
        #
        # 1) Rewrite Set-Cookie attributes on the way out so cookies survive
        #    cross-origin iframe contexts. Requires HTTPS (we have certbot).
        proxy_cookie_flags ~ secure samesite=none;
        # 2) Strip openvscode-server's X-Frame-Options so the dashboard can
        #    actually embed the iframe in the first place.
        proxy_hide_header X-Frame-Options;

        # WebSocket support (critical for VS Code terminal/file watcher)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Forward real client info
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # Timeouts (long for terminal sessions)
        proxy_read_timeout 86400;
        proxy_connect_timeout 300;
        proxy_send_timeout 86400;

        # Buffering off for real-time editor
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX_IDE_EOF

# NOTE: IDE config uses SSL certs — don't enable until certbot has run (STEP 5)
log_info "IDE Nginx config written (will be enabled after SSL cert is obtained)"

# ── OpenClaw Gateway reverse proxy — same domain, port 18789 with SSL ──
NGINX_OPENCLAW_CONF="/etc/nginx/sites-available/vxcloud-openclaw"
log_info "Writing Nginx reverse proxy config for OpenClaw on port $OPENCLAW_PORT..."
cat > "$NGINX_OPENCLAW_CONF" << NGINX_OC_EOF
# Managed by setup_tenant.sh — OpenClaw Gateway
# Same domain as vxnode, different port ($OPENCLAW_PORT) with SSL

server {
    listen ${OPENCLAW_PORT} ssl;
    listen [::]:${OPENCLAW_PORT} ssl;
    server_name $DOMAIN;

    # SSL certs — shared with the main vxnode site (managed by certbot)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:${OPENCLAW_BACKEND_PORT};
        proxy_http_version 1.1;

        # ── Cross-origin iframe embedding (same reasoning as IDE block) ──
        # Allow the dashboard to embed the gateway UI in an iframe and let
        # any auth cookies travel on cross-site sub-resource requests.
        proxy_cookie_flags ~ secure samesite=none;
        proxy_hide_header X-Frame-Options;

        # WebSocket support (needed for gateway real-time comms)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Forward real client info
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # Timeouts (long for persistent gateway connections)
        proxy_read_timeout 86400;
        proxy_connect_timeout 300;
        proxy_send_timeout 86400;

        # Buffering off for real-time gateway
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX_OC_EOF

# NOTE: OpenClaw config uses SSL certs — don't enable until certbot has run (STEP 5)
log_info "OpenClaw Nginx config written (will be enabled after SSL cert is obtained)"

CONFIGURED_SERVER_NAME=$(grep -oP 'server_name\s+\K[^;]+' "$NGINX_CONF" | tr -d ' ')
if [ "$CONFIGURED_SERVER_NAME" != "$DOMAIN" ]; then
    log_error "Nginx server_name mismatch: got '$CONFIGURED_SERVER_NAME', expected '$DOMAIN'"
    log_error "This would break SSL certificate requests. Aborting."
    exit 1
fi
log_success "Nginx server_name verified: $CONFIGURED_SERVER_NAME"

if nginx -t 2>&1; then
    systemctl reload nginx
    log_success "Nginx configured: $DOMAIN -> http://127.0.0.1:${APP_PORT}"
    log_info "Nginx prepared (not yet enabled): https://$DOMAIN:$IDE_PORT -> http://127.0.0.1:${IDE_BACKEND_PORT}"
    log_info "Nginx prepared (not yet enabled): https://$DOMAIN:$OPENCLAW_PORT -> http://127.0.0.1:${OPENCLAW_BACKEND_PORT}"
else
    log_error "Nginx config test failed:"
    nginx -t
    exit 1
fi

# Pre-certbot connectivity check: verify domains are reachable from the internet via port 80
log_info "Verifying $DOMAIN is reachable on port 80 before requesting SSL..."
PRE_SSL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$DOMAIN/api/v2/health" 2>/dev/null || echo "000")
if [ "$PRE_SSL_CODE" = "000" ]; then
    log_error "Cannot reach http://$DOMAIN from this machine (HTTP $PRE_SSL_CODE)"
    log_error "Certbot WILL fail. Check: DNS A record, Security Group ports 80/443, nginx status"
    log_error "Skipping SSL setup — fix connectivity and re-run the script."
else
    log_success "http://$DOMAIN reachable (HTTP $PRE_SSL_CODE)"
fi

# =============================================================================
# STEP 5: SSL CERTIFICATE (Let's Encrypt via Certbot)
# =============================================================================
log_info "Installing Certbot..."
wait_for_apt
apt-get install -y certbot python3-certbot-nginx
log_success "Certbot installed"

if [ "$PRE_SSL_CODE" = "000" ]; then
    log_warn "Skipping SSL setup — domain not reachable on port 80 (see error above)"
else
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    NEED_NEW_CERT=true

    if [ -f "$CERT_PATH" ]; then
        CERT_EXPIRY_EPOCH=$(date -d "$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (CERT_EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        if [ "$DAYS_LEFT" -gt 10 ]; then
            log_success "SSL certificate valid (${DAYS_LEFT} days remaining)"
            NEED_NEW_CERT=false
        else
            log_warn "SSL certificate expires in ${DAYS_LEFT} days — renewing..."
            certbot renew --nginx --non-interactive
            log_success "SSL certificate renewed"
            NEED_NEW_CERT=false
        fi
    fi

    if [ "$NEED_NEW_CERT" = true ]; then
        log_info "Requesting new SSL certificate for $DOMAIN..."
        if certbot --nginx \
            --non-interactive \
            --agree-tos \
            --redirect \
            --expand \
            -m "$EMAIL" \
            -d "$DOMAIN"; then
            log_success "SSL certificate obtained and installed"
        else
            log_error "Certbot failed. Common causes:"
            log_error "  - DNS not pointing $DOMAIN to this VM ($VM_IP)"
            log_error "  - Port 80 blocked by firewall/security group"
            log_error "  - Rate limit hit (max 5 certs per domain per week)"
            log_error ""
            log_error "Fix the issue and re-run: sudo certbot --nginx -d $DOMAIN"
            log_error "The app is still running on HTTP — only SSL failed."
        fi
    fi
fi

if [ "$PRE_SSL_CODE" != "000" ]; then
    if ! grep -q "listen 443 ssl" /etc/nginx/sites-available/vxcloud-tenant 2>/dev/null; then
        log_info "SSL block missing from Nginx config — re-running certbot install..."
        certbot install --nginx --non-interactive --redirect -d "$DOMAIN" 2>/dev/null || \
        certbot --nginx --non-interactive --agree-tos --redirect --expand -m "$EMAIL" -d "$DOMAIN" || \
        log_warn "Could not inject SSL block — run manually: sudo certbot --nginx -d $DOMAIN"
    fi
fi

# ── Enable IDE + OpenClaw Nginx configs now that SSL cert exists ──
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    ln -sf "$NGINX_IDE_CONF" /etc/nginx/sites-enabled/
    log_success "IDE Nginx enabled: https://$DOMAIN:$IDE_PORT -> http://127.0.0.1:${IDE_BACKEND_PORT}"

    ln -sf "$NGINX_OPENCLAW_CONF" /etc/nginx/sites-enabled/
    log_success "OpenClaw Nginx enabled: https://$DOMAIN:$OPENCLAW_PORT -> http://127.0.0.1:${OPENCLAW_BACKEND_PORT}"
else
    log_warn "SSL cert not found — IDE and OpenClaw Nginx configs not enabled"
    log_warn "After obtaining cert, run:"
    log_warn "  sudo ln -sf $NGINX_IDE_CONF /etc/nginx/sites-enabled/"
    log_warn "  sudo ln -sf $NGINX_OPENCLAW_CONF /etc/nginx/sites-enabled/"
    log_warn "  sudo nginx -t && sudo systemctl reload nginx"
fi

systemctl reload nginx

# =============================================================================
# STEP 6: CERTBOT AUTO-RENEWAL
# =============================================================================
log_info "Setting up SSL auto-renewal..."

# Certbot installs a systemd timer or cron by default, but let's verify
if systemctl list-timers | grep -q certbot; then
    log_success "Certbot auto-renewal timer is active"
else
    # Fallback: add cron job
    CRON_CMD="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
    (crontab -l 2>/dev/null | grep -v certbot; echo "$CRON_CMD") | crontab -
    log_success "Certbot renewal cron job installed (daily at 3 AM)"
fi

# Test renewal (dry run)
certbot renew --dry-run 2>/dev/null && log_success "Renewal dry-run passed" || log_warn "Renewal dry-run failed (cert may not be installed yet)"

# =============================================================================
# STEP 7: FIREWALL (UFW)
# =============================================================================
if command -v ufw &> /dev/null; then
    log_info "Configuring UFW firewall..."
    ufw allow 22/tcp   > /dev/null 2>&1  # SSH
    ufw allow 80/tcp   > /dev/null 2>&1  # HTTP (for cert renewal)
    ufw allow 443/tcp  > /dev/null 2>&1  # HTTPS
    ufw allow ${IDE_PORT}/tcp > /dev/null 2>&1  # IDE (OpenVSCode Server HTTPS)
    ufw allow ${OPENCLAW_PORT}/tcp > /dev/null 2>&1  # OpenClaw Gateway HTTPS
    ufw --force enable  > /dev/null 2>&1 || true
    log_success "UFW: ports 22, 80, 443, ${IDE_PORT}, ${OPENCLAW_PORT} open"
else
    log_info "UFW not installed — ensure security group allows ports 80, 443, ${IDE_PORT}, and ${OPENCLAW_PORT}"
fi

# =============================================================================
# STEP 7b: FLEET SELF-UPDATE — host updater + systemd timer
# =============================================================================
# The vxnode container's in-binary listener watches a public channel JSON for a
# new image digest and writes a trigger file under /app/generated/. A process
# can't cleanly replace the container it runs in, so the actual pull+recreate
# happens on the HOST via the systemd unit installed here:
#
#   • /opt/vxcloud/update/vxnode-update.sh  — the worker (pull → up -d →
#     health-gate /api/v2/health → ROLLBACK on failure, single-flight via flock)
#   • vxnode-update.timer                    — fires 2 min after boot then every
#     5 min, matching the in-container poll cadence
#
# All embedded inline so tenant_setup.sh stays self-contained (no dependency on
# the distribution/ repo when it's curl|bash'd onto a fresh VM).
# =============================================================================
log_info "Installing host-side fleet updater (systemd timer)..."
UPDATE_DIR="$DEPLOY_DIR/update"
mkdir -p "$UPDATE_DIR"

cat > "$UPDATE_DIR/vxnode-update.sh" <<'UPDATER_EOF'
#!/usr/bin/env bash
# Host-side fleet updater — DO NOT EDIT (regenerated by tenant_setup.sh).
# Pulls the channel's desired digest, recreates the container via compose,
# health-gates /api/v2/health for 60s, rolls back on failure. Single-flight.
set -euo pipefail
DEPLOY_DIR="${DEPLOY_DIR:-/opt/vxcloud}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.yml}"
IMAGE="${IMAGE:-vxcloud/vxnode}"
TAG="${TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-vxcloud-vxnode}"
APP_PORT="${APP_PORT:-8744}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/api/v2/health"
CHANNEL_URL="${CHANNEL_URL:-https://vxcloud.io/download/vxnode/stable.json}"
TRIGGER="${TRIGGER:-$DEPLOY_DIR/generated/.vxnode-update}"
LOG="${LOG:-$DEPLOY_DIR/update/vxnode-update.log}"
LOCK="${LOCK:-/tmp/vxnode-update.lock}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
exec 9>"$LOCK"; flock -n 9 || { log "another update run holds the lock — exiting"; exit 0; }
desired=""
if manifest=$(curl -fsSL --max-time 15 "$CHANNEL_URL" 2>/dev/null); then
    desired=$(printf '%s' "$manifest" | jq -r '.digest // empty' 2>/dev/null || true)
fi
if [ -z "$desired" ] && [ -f "$TRIGGER" ]; then
    desired=$(head -n1 "$TRIGGER" 2>/dev/null || true)
fi
case "$desired" in sha256:*) : ;; *) log "no valid desired digest — nothing to do"; exit 0 ;; esac
running=""
if img_id=$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null); then
    running=$(docker inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$img_id" 2>/dev/null | sed 's/.*@//' || true)
fi
if [ "$desired" = "$running" ]; then log "up to date ($desired)"; rm -f "$TRIGGER" 2>/dev/null || true; exit 0; fi
log "update: running='${running:-none}' → desired='$desired'"
if ! docker pull "${IMAGE}@${desired}" >>"$LOG" 2>&1; then
    log "ERROR: pull ${IMAGE}@${desired} failed — keeping current image"; exit 1
fi
docker tag "${IMAGE}@${desired}" "${IMAGE}:${TAG}"
cd "$DEPLOY_DIR"
docker compose -f "$COMPOSE_FILE" up -d >>"$LOG" 2>&1
healthy=false
for _ in $(seq 1 30); do
    if curl -fsf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then healthy=true; break; fi
    sleep 2
done
if [ "$healthy" = true ]; then
    log "OK: now running $desired (healthy)"
    rm -f "$TRIGGER" 2>/dev/null || true
    docker image prune -f >>"$LOG" 2>&1 || true
    exit 0
fi
log "ERROR: new image unhealthy after 60s — rolling back"
if [ -n "$running" ]; then
    docker tag "${IMAGE}@${running}" "${IMAGE}:${TAG}" 2>>"$LOG" || true
    docker compose -f "$COMPOSE_FILE" up -d >>"$LOG" 2>&1 || true
    log "rolled back to $running"
else
    log "no previous digest recorded — cannot auto-roll-back; investigate on the node"
fi
exit 1
UPDATER_EOF
chmod 755 "$UPDATE_DIR/vxnode-update.sh"

cat > /etc/systemd/system/vxnode-update.service <<SERVICE_EOF
[Unit]
Description=vxnode self-update (pull + recreate when the channel digest changes)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$UPDATE_DIR/vxnode-update.sh
Environment=DEPLOY_DIR=$DEPLOY_DIR
Environment=CONTAINER_NAME=$CONTAINER_NAME
Environment=APP_PORT=$APP_PORT
Environment=CHANNEL_URL=${VXNODE_UPDATE_CHANNEL_URL:-https://vxcloud.io/download/vxnode/stable.json}
Nice=10
SERVICE_EOF

cat > /etc/systemd/system/vxnode-update.timer <<TIMER_EOF
[Unit]
Description=Run vxnode self-update every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

# Per-VM opt-out: if the operator set VXNODE_AUTO_UPDATE=false at script time,
# install the units but DO NOT enable the timer — so they can flip it on later
# without re-running this whole script.
systemctl daemon-reload
if [ "${VXNODE_AUTO_UPDATE:-true}" = "false" ]; then
    systemctl disable vxnode-update.timer 2>/dev/null || true
    log_warn "Fleet auto-update DISABLED on this VM (VXNODE_AUTO_UPDATE=false)."
    log_warn "To enable later: sudo systemctl enable --now vxnode-update.timer"
else
    systemctl enable --now vxnode-update.timer
    log_success "Fleet auto-update enabled (next run ~2 min, then every 5 min)"
    log_info "  logs:   tail -f $UPDATE_DIR/vxnode-update.log"
    log_info "  status: systemctl list-timers vxnode-update.timer"
    log_info "  manual: sudo systemctl start vxnode-update.service"
fi

# =============================================================================
# FINAL VERIFICATION
# =============================================================================
echo ""
log_info "============================================"
log_info "  FINAL VERIFICATION"
log_info "============================================"

# Container status
echo ""
log_info "Docker container:"
docker ps --filter "name=$CONTAINER_NAME" --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Nginx status
echo ""
log_info "Nginx status:"
systemctl is-active nginx > /dev/null 2>&1 && log_success "  Nginx is running" || log_error "  Nginx is NOT running"

# SSL cert info
echo ""
log_info "SSL certificate:"
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2)
    log_success "  Certificate found, expires: $CERT_EXPIRY"
else
    log_warn "  No certificate file found (certbot may have failed)"
fi

# HTTP -> HTTPS redirect test
echo ""
log_info "Endpoint tests (vxnode):"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$DOMAIN/api/v2/health" 2>/dev/null || echo "000")
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN/api/v2/health" 2>/dev/null || echo "000")
log_info "  http://$DOMAIN  -> HTTP $HTTP_CODE (expect 301 redirect)"
log_info "  https://$DOMAIN -> HTTP $HTTPS_CODE (expect 200)"

log_info "Endpoint tests (IDE):"
IDE_HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN:$IDE_PORT/" 2>/dev/null || echo "000")
log_info "  https://$DOMAIN:$IDE_PORT -> HTTP $IDE_HTTPS_CODE (expect 200 when IDE container is running)"

log_info "Endpoint tests (OpenClaw):"
OC_HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN:$OPENCLAW_PORT/" 2>/dev/null || echo "000")
log_info "  https://$DOMAIN:$OPENCLAW_PORT -> HTTP $OC_HTTPS_CODE (expect 200 when OpenClaw gateway is running)"

# =============================================================================
# STEP 8: INSTALL BASE PACKAGES & DEV TOOLS INSIDE CONTAINER
# =============================================================================
log_info "============================================"
log_info "  INSTALLING TOOLS INSIDE CONTAINER"
log_info "============================================"

# ── Base packages + networking inside container ──
log_info "Installing base packages inside container ${CONTAINER_NAME}..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq \
            ca-certificates curl wget gnupg unzip \
            software-properties-common apt-transport-https dnsutils \
            vim jq lsof git net-tools iputils-ping iproute2
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache \
            ca-certificates curl wget gnupg unzip \
            vim jq lsof git net-tools iputils-ping iproute2 bind-tools
    fi
' && log_success "Base packages installed in container" \
  || log_warn "Base packages install failed in container — image may use a different package manager"

# ── Terraform inside container ──
# IMPORTANT: pick the binary by container arch — uname -m inside the container,
# not the host. Releases publishes terraform_<v>_linux_{amd64,arm64}.zip; the URL
# previously hardcoded amd64, which "worked" on Graviton/Ampere arm64 tenants
# until the Go runtime tried to exec it and the provisioner returned 500 with
# "fork/exec /usr/local/bin/terraform: exec format error".
# Also verify the existing binary actually runs (`terraform version`) — a broken
# wrong-arch install from a previous run leaves `command -v terraform` truthy,
# so the old skip-if-present check would never self-heal.
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"
log_info "Installing Terraform ${TERRAFORM_VERSION} inside container..."
docker exec "$CONTAINER_NAME" sh -c "
    if terraform version >/dev/null 2>&1; then
        echo 'Terraform already installed and runnable'
    else
        ARCH=\$(uname -m)
        case \"\$ARCH\" in
            aarch64|arm64) TF_ARCH=arm64 ;;
            x86_64|amd64)  TF_ARCH=amd64 ;;
            *) echo \"Unsupported arch for terraform: \$ARCH\"; exit 1 ;;
        esac
        rm -f /usr/local/bin/terraform   # clear any broken wrong-arch leftover
        wget -q \"https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_\${TF_ARCH}.zip\" -O /tmp/terraform.zip && \
        unzip -o /tmp/terraform.zip -d /usr/local/bin/ && \
        chmod +x /usr/local/bin/terraform && \
        rm -f /tmp/terraform.zip && \
        echo \"Installed terraform_${TERRAFORM_VERSION}_linux_\${TF_ARCH}\"
    fi
" && log_success "Terraform installed in container: $(docker exec "$CONTAINER_NAME" terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo 'OK')" \
  || log_warn "Terraform install failed in container"

# ── Node.js inside container (needed for Codex, Gemini CLIs) ──
log_info "Installing Node.js inside container..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v node >/dev/null 2>&1; then
        echo "Node.js already installed: $(node --version)"
    else
        if command -v apt-get >/dev/null 2>&1; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
            apt-get install -y -qq nodejs
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache nodejs npm
        fi
    fi
' && log_success "Node.js installed in container: $(docker exec "$CONTAINER_NAME" node --version 2>/dev/null || echo 'OK')" \
  || log_warn "Node.js install failed in container"

# ── Claude Code inside container ──
log_info "Installing Claude Code CLI inside container..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v claude >/dev/null 2>&1; then
        echo "Claude Code already installed"
    else
        curl -fsSL https://claude.ai/install.sh | bash
        # Symlink into /usr/local/bin so claude is always in PATH (docker exec uses sh -c which skips profile files)
        for p in "$HOME/.local/bin/claude" /root/.local/bin/claude; do
            if [ -f "$p" ] || [ -L "$p" ]; then
                ln -sf "$p" /usr/local/bin/claude
                break
            fi
        done
    fi
' && log_success "Claude Code installed in container" \
  || log_warn "Claude Code install failed in container"

# ── OpenAI Codex CLI inside container ──
log_info "Installing OpenAI Codex CLI inside container..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v codex >/dev/null 2>&1; then
        echo "Codex already installed"
    else
        npm install -g @openai/codex 2>/dev/null
    fi
' && log_success "Codex installed in container" \
  || log_warn "Codex install failed in container"

# ── Google Gemini CLI inside container ──
log_info "Installing Gemini CLI inside container..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v gemini >/dev/null 2>&1; then
        echo "Gemini CLI already installed"
    else
        npm install -g @google/gemini-cli 2>/dev/null
    fi
' && log_success "Gemini CLI installed in container" \
  || log_warn "Gemini CLI install failed in container"

# ── vxcli (vxcloud CLI) inside container ──
# Installed from the public download channel as a prebuilt binary (amd64/arm64)
# — no Go toolchain, no build from source. The installer drops vxcli in
# ~/.local/bin (no sudo); we symlink it into /usr/local/bin so it's on PATH for
# `docker exec sh -c`, which skips login/profile files (same trick as claude).
log_info "Installing vxcli (vxcloud CLI) inside container..."
docker exec "$CONTAINER_NAME" sh -c '
    if command -v vxcli >/dev/null 2>&1; then
        echo "vxcli already installed"
    else
        curl -fsSL https://vxcloud.io/download/cli/install.sh | sh
        for p in "$HOME/.local/bin/vxcli" /root/.local/bin/vxcli; do
            if [ -f "$p" ] || [ -L "$p" ]; then
                ln -sf "$p" /usr/local/bin/vxcli
                break
            fi
        done
    fi
' && log_success "vxcli installed in container" \
  || log_warn "vxcli install failed in container"

# ── Verify vxcli (vxcli version) ──
log_info "Verifying vxcli inside container..."
if VXCLI_VER=$(docker exec "$CONTAINER_NAME" sh -c 'vxcli version' 2>/dev/null | head -1); then
    [ -n "$VXCLI_VER" ] && log_success "vxcli: $VXCLI_VER" \
                        || log_success "vxcli installed (version output empty)"
else
    log_warn "vxcli version check failed — re-run: docker exec $CONTAINER_NAME vxcli version"
fi

# ── Verify all tools inside container ──
log_info "Verifying tools inside container..."
for cmd in curl wget jq git vim terraform node npm; do
    if docker exec "$CONTAINER_NAME" sh -c "command -v $cmd" > /dev/null 2>&1; then
        log_success "  [container] $cmd"
    else
        log_warn "  [container] $cmd — not found"
    fi
done
for cmd in claude codex gemini vxcli; do
    if docker exec "$CONTAINER_NAME" sh -c "command -v $cmd" > /dev/null 2>&1; then
        log_success "  [container] $cmd"
    else
        log_warn "  [container] $cmd — not installed (optional)"
    fi
done

echo ""
log_info "============================================"
log_success "  SETUP COMPLETE"
log_info "============================================"
echo ""
log_info "Your app is live at:"
log_success "  https://$DOMAIN"
log_success "  https://$DOMAIN/api/v2/health"
log_success "  https://$DOMAIN:$IDE_PORT  (OpenVSCode Server IDE — run openvscode installer separately)"
log_success "  https://$DOMAIN:$OPENCLAW_PORT  (OpenClaw Gateway — run openclaw installer separately)"
echo ""
log_info "Useful commands:"
log_info "  docker compose -f $DEPLOY_DIR/docker-compose.yml logs -f    # App logs"
log_info "  docker compose -f $DEPLOY_DIR/docker-compose.yml restart    # Restart app"
log_info "  sudo certbot certificates                                    # View certs"
log_info "  sudo nginx -t && sudo systemctl reload nginx                 # Reload nginx"
echo ""

# =============================================================================
# INSTALLATION ORDER
# =============================================================================
# The order is:
#
# 1. tenant_setup.sh (this script) — ALWAYS RUN FIRST
#    - Deploys the vxnode container
#    - Installs Nginx
#    - Gets the SSL certificate (Let's Encrypt)
#    - Prepares all nginx proxy configs for IDE and OpenClaw
#      (but doesn't enable them until the cert exists)
#
# Then the other 2 in any order (they are independent of each other):
#
# 2. openvscode-server-one-time-installer.sh
#    - Deploys the IDE container on localhost:8089
#    - Nginx already proxies https://$DOMAIN:8443 -> localhost:8089
#
# 3. openclaw_vm_installer.sh
#    - Installs OpenClaw gateway on localhost:18790
#    - Nginx already proxies https://$DOMAIN:18789 -> localhost:18790
#
# Why tenant_setup first?
#   The other 2 scripts do NOT touch nginx at all — they rely on
#   tenant_setup.sh having already created the nginx configs and SSL cert.
#   If you ran them before tenant_setup, the services would still work on
#   localhost, but there would be no HTTPS proxy until you run tenant_setup.
# =============================================================================

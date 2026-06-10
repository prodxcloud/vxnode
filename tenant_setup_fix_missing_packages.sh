#!/bin/bash
# =============================================================================
#  setup_tenant_fix_missing.sh — Fix missing tools inside running container
#
#  Assumes: you are already SSH'd into the VM and the container is running.
#  Installs Claude Code + Codex inside the container via docker exec.
#
#  Usage:
#    chmod +x setup_tenant_fix_missing.sh
#    sudo ./setup_tenant_fix_missing.sh
#
#  Or with custom container name:
#    sudo CONTAINER_NAME="my-container" ./setup_tenant_fix_missing.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-valtunox-vxnode}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/valtunox}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Verify container is running ──
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_error "Container ${CONTAINER_NAME} is not running"
    docker ps -a --format '  {{.Names}}\t{{.Status}}' 2>/dev/null || true
    exit 1
fi
log_success "Container ${CONTAINER_NAME} is running"

# =============================================================================
# 0. FIX DOCKER SOCKET MOUNT (if missing)
# =============================================================================
log_info "── Checking Docker socket mount ──"

SOCKET_MOUNTED=false
if docker exec "$CONTAINER_NAME" sh -c "test -S /var/run/docker.sock" > /dev/null 2>&1; then
    SOCKET_MOUNTED=true
    log_success "Docker socket already mounted in container"
fi

if [ "$SOCKET_MOUNTED" = false ]; then
    log_warn "Docker socket not mounted — patching docker-compose.yml and recreating container..."

    COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Compose file not found at $COMPOSE_FILE"
        log_error "Set DEPLOY_DIR to the correct path"
        exit 1
    fi

    # Add volumes section with docker socket if not already present
    if grep -q "/var/run/docker.sock" "$COMPOSE_FILE" 2>/dev/null; then
        log_success "docker-compose.yml already has socket volume (container needs recreate)"
    else
        log_info "Patching $COMPOSE_FILE with Docker socket volume..."
        # Insert volumes block after cap_add section
        if grep -q "volumes:" "$COMPOSE_FILE" 2>/dev/null; then
            # volumes section exists — append socket line if missing
            sed -i '/volumes:/a\      - /var/run/docker.sock:/var/run/docker.sock' "$COMPOSE_FILE"
        elif grep -q "cap_add:" "$COMPOSE_FILE" 2>/dev/null; then
            # Insert after the cap_add block
            sed -i '/- NET_BIND_SERVICE/a\    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock' "$COMPOSE_FILE"
        else
            # Append before tmpfs or at end of service block
            sed -i '/tmpfs:/i\    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock' "$COMPOSE_FILE"
        fi
        log_success "docker-compose.yml patched"
    fi

    # Recreate container with new volume mount
    log_info "Recreating container to apply socket mount..."
    cd "$DEPLOY_DIR"
    docker compose up -d --force-recreate
    sleep 3

    # Verify container came back up
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container failed to restart after recreate"
        docker compose logs --tail 10 2>/dev/null || true
        exit 1
    fi

    # Confirm socket is now mounted
    if docker exec "$CONTAINER_NAME" sh -c "test -S /var/run/docker.sock" > /dev/null 2>&1; then
        log_success "Docker socket now mounted in container"
    else
        log_error "Docker socket still not available after recreate"
    fi
fi

# =============================================================================
# 1. CLAUDE CODE
# =============================================================================
log_info "── Installing Claude Code CLI ──"

if docker exec "$CONTAINER_NAME" sh -c "command -v claude" > /dev/null 2>&1; then
    log_success "Claude Code already installed: $(docker exec "$CONTAINER_NAME" claude --version 2>/dev/null || echo 'OK')"
else
    # Ensure curl exists inside container
    docker exec "$CONTAINER_NAME" sh -c '
        command -v curl >/dev/null 2>&1 && exit 0
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl
        elif command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq curl
        fi
    '

    log_info "Running Claude Code installer inside container..."
    docker exec "$CONTAINER_NAME" sh -c 'curl -fsSL https://claude.ai/install.sh | bash'

    # Symlink into /usr/local/bin so it is always in PATH for docker exec sessions
    docker exec "$CONTAINER_NAME" sh -c '
        for p in "$HOME/.local/bin/claude" /root/.local/bin/claude; do
            if [ -f "$p" ] || [ -L "$p" ]; then
                ln -sf "$p" /usr/local/bin/claude
                echo "Symlinked $p -> /usr/local/bin/claude"
                break
            fi
        done
    '

    if docker exec "$CONTAINER_NAME" sh -c "command -v claude" > /dev/null 2>&1; then
        log_success "Claude Code installed: $(docker exec "$CONTAINER_NAME" claude --version 2>/dev/null || echo 'OK')"
    else
        log_error "Claude Code install failed"
    fi
fi

# =============================================================================
# 2. OPENAI CODEX (commented out — uncomment when needed)
# =============================================================================
# log_info "── Installing OpenAI Codex CLI ──"
#
# if docker exec "$CONTAINER_NAME" sh -c "command -v codex" > /dev/null 2>&1; then
#     log_success "Codex already installed"
# else
#     # Ensure Node.js + npm exist inside container
#     if ! docker exec "$CONTAINER_NAME" sh -c "command -v node" > /dev/null 2>&1; then
#         log_info "Installing Node.js inside container..."
#         docker exec "$CONTAINER_NAME" sh -c '
#             if command -v apk >/dev/null 2>&1; then
#                 apk add --no-cache nodejs npm
#             elif command -v apt-get >/dev/null 2>&1; then
#                 export DEBIAN_FRONTEND=noninteractive
#                 curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
#                 apt-get install -y -qq nodejs
#             fi
#         '
#     fi
#
#     log_info "Running npm install @openai/codex..."
#     docker exec "$CONTAINER_NAME" sh -c 'npm install -g @openai/codex 2>/dev/null'
#
#     if docker exec "$CONTAINER_NAME" sh -c "command -v codex" > /dev/null 2>&1; then
#         log_success "Codex installed"
#     else
#         log_error "Codex install failed"
#     fi
# fi

# =============================================================================
# 3. DOCKER CLI (inside container)
# =============================================================================
log_info "── Installing Docker CLI ──"

if docker exec "$CONTAINER_NAME" sh -c "command -v docker" > /dev/null 2>&1; then
    log_success "Docker already installed: $(docker exec "$CONTAINER_NAME" docker --version 2>/dev/null || echo 'OK')"
else
    log_info "Installing Docker CLI inside container..."
    docker exec "$CONTAINER_NAME" sh -c '
        DOCKER_VERSION="${DOCKER_VERSION:-27.5.1}"
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache docker-cli
        elif command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            apt-get install -y -qq docker-ce-cli
        else
            # Fallback: download static binary
            curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" -o /tmp/docker.tgz
            tar xzf /tmp/docker.tgz -C /tmp
            mv /tmp/docker/docker /usr/local/bin/docker
            chmod +x /usr/local/bin/docker
            rm -rf /tmp/docker /tmp/docker.tgz
        fi
    '

    if docker exec "$CONTAINER_NAME" sh -c "command -v docker" > /dev/null 2>&1; then
        log_success "Docker CLI installed: $(docker exec "$CONTAINER_NAME" docker --version 2>/dev/null || echo 'OK')"
    else
        log_error "Docker CLI install failed"
    fi
fi

# Verify Docker daemon is reachable via socket
if docker exec "$CONTAINER_NAME" sh -c "docker info" > /dev/null 2>&1; then
    log_success "Docker daemon reachable from inside container"
else
    log_error "Docker CLI installed but cannot reach daemon — socket mount may have failed"
fi

# =============================================================================
# VERIFY
# =============================================================================
echo ""
log_info "── Verification ──"
for cmd in claude docker; do
    if docker exec "$CONTAINER_NAME" sh -c "command -v $cmd" > /dev/null 2>&1; then
        log_success "[container] $cmd"
    else
        log_error "[container] $cmd — NOT FOUND"
    fi
done
echo ""




# SSL quick fix

sudo sed -i 's|server_name https://tenantnode2.valtunox.space|server_name tenantnode1.valtunox.space|g' /etc/nginx/sites-available/valtunox-tenant
sudo nginx -t && sudo systemctl reload nginx
curl -s -o /dev/null -w "%{http_code}" http://tenantnode1.valtunox.space/api/v2/health
sudo certbot --nginx --non-interactive --agree-tos --redirect -m joelwembo.dev@gmail.com -d tenantnode1.valtunox.space

# or

# sudo sed -i 's|server_name https://tenantnode2.valtunox.space|server_name tenantnode2.valtunox.space|g' /etc/nginx/sites-available/valtunox-tenant
# sudo sed -i 's|server_name https://tenantnode1.valtunox.space|server_name tenantnode2.valtunox.space|g' /etc/nginx/sites-available/valtunox-tenant
# sudo nginx -t && sudo systemctl reload nginx
# curl -s -o /dev/null -w "%{http_code}" http://tenantnode2.valtunox.space/api/v2/health
# sudo certbot --nginx --non-interactive --agree-tos --redirect -m joelwembo.dev@gmail.com -d tenantnode2.valtunox.space

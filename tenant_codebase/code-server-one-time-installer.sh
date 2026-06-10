#!/bin/bash
set -euo pipefail

# =============================================================================
# Code-Server One-Time Installer (Single File — Zero External Dependencies)
# =============================================================================
# Everything is embedded: lib functions, config, devcontainer, connection check.
# No lib/, config/, devcontainer/, .env, or connection_checking.py needed.
#
# Usage:
#   ./code-server-one-time-installer.sh                # Full install
#   ./code-server-one-time-installer.sh post-deploy    # Post-deploy only
#   ./code-server-one-time-installer.sh check          # Connection check only
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (replaces .env)
# ---------------------------------------------------------------------------
CONTAINER_NAME="code-server"
IMAGE="codercom/code-server:latest"
# HOST_PORT=8089 matches tenant_setup.sh's IDE_BACKEND_PORT — nginx proxies
# https://$DOMAIN:8443 (public) -> 127.0.0.1:8089 (this container).
# Override with HOST_PORT=8080 to run standalone (no nginx).
HOST_PORT="${HOST_PORT:-8089}"
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
APP_NAME="code-server"
TZ="UTC"
# Auto-detect CPU limit — Docker rejects --cpus > host CPU count.
# Override via env (e.g. CPU_LIMIT=2.0) on bigger VMs.
_HOST_CPUS=$(nproc 2>/dev/null || echo 1)
if [ "${_HOST_CPUS}" -le 1 ]; then
    CPU_LIMIT="${CPU_LIMIT:-0.9}"
else
    CPU_LIMIT="${CPU_LIMIT:-2.0}"
fi
MEMORY_LIMIT="${MEMORY_LIMIT:-1g}"
PASSWORD="${PASSWORD:-adminpass1234}"
SUDO_PASSWORD="${SUDO_PASSWORD:-adminpass1234}"

DEPLOY_DIR="${DEPLOY_DIR:-/opt/valtunox}"
GENERATED_PATH="${GENERATED_PATH:-${DEPLOY_DIR}/generated}"

HOST_CONFIG_DIR="${HOME}/code-server/config"
HOST_PROJECTS_DIR="${HOME}/code-server/projects"
HOST_DATA_DIR="${HOME}/code-server/data"
SETTINGS_FILE="${HOST_DATA_DIR}/User/settings.json"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# =============================================================================
# Embedded: install-node-python-base.sh
# =============================================================================
valtunox_remote_script_base_apt() {
  cat <<'EOF'
apt-get update -qq && apt-get install -y -qq --no-install-recommends curl wget git unzip jq make gcc g++ python3 python3-pip python3-venv ca-certificates gnupg lsb-release openssh-client iputils-ping netcat-openbsd > /dev/null 2>&1
EOF
}

valtunox_remote_script_nodejs_20() {
  cat <<'EOF'
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1 && apt-get install -y -qq nodejs > /dev/null 2>&1
EOF
}

# =============================================================================
# Embedded: install-docker-cli-compose.sh
# =============================================================================
valtunox_remote_script_docker_cli_dood() {
  cat <<'EOF'
install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq docker-ce-cli docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
EOF
}

valtunox_remote_script_docker_standalone_compose() {
  cat <<'EOF'
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
EOF
}

valtunox_remote_script_docker_group_membership() {
  cat <<'EOF'
getent group docker >/dev/null 2>&1 || groupadd -f docker; usermod -aG docker coder 2>/dev/null || true
EOF
}

# =============================================================================
# Embedded: settings.json generator
# =============================================================================
generate_settings_json() {
  cat <<'EOF'
{
  "github.copilot.enable": false,
  "github.copilot.editor.enableAutoCompletions": false,
  "extensions.ignoreRecommendations": true,
  "workbench.startupEditor": "none",
  "telemetry.telemetryLevel": "off",
  "editor.fontSize": 14,
  "editor.tabSize": 2,
  "editor.minimap.enabled": false,
  "editor.wordWrap": "on",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 1000,
  "terminal.integrated.fontSize": 13,
  "workbench.colorTheme": "Default Dark Modern"
}
EOF
}

# =============================================================================
# Embedded: devcontainer.json generator
# =============================================================================
generate_devcontainer_json() {
  cat <<'EOF'
{
  "name": "Valtunox Full Stack (reference)",
  "image": "mcr.microsoft.com/devcontainers/python:3.12",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": true
    },
    "ghcr.io/devcontainers/features/node:1": {
      "version": "20"
    }
  },
  "forwardPorts": [
    3001, 3002, 3008, 3009,
    4200,
    5173,
    8000,
    8747, 8748, 8749,
    8888,
    9000,
    18786, 18788, 18789
  ],
  "customizations": {
    "vscode": {
      "extensions": [
        "ms-python.python",
        "redhat.vscode-yaml",
        "dbaeumer.vscode-eslint",
        "esbenp.prettier-vscode"
      ]
    }
  },
  "postCreateCommand": "python3 --version && node --version && (docker --version || true) && (docker compose version || true)"
}
EOF
}

# =============================================================================
# Embedded: connection checking (replaces connection_checking.py)
# =============================================================================
check_port() {
    local host="$1" port="$2" timeout="${3:-3}"
    if (echo >/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
        return 0
    fi
    return 1
}

check_http() {
    local url="$1" timeout="${2:-5}"
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "${timeout}" "${url}" 2>/dev/null || echo "000")
    if [ "${status_code}" -ge 200 ] 2>/dev/null && [ "${status_code}" -lt 500 ] 2>/dev/null; then
        echo "${status_code}"
        return 0
    fi
    echo "${status_code}"
    return 1
}

run_connection_check() {
    local all_ok=true

    echo "=================================================="
    echo "  Connectivity Test: ${APP_NAME^^}"
    echo "=================================================="

    # 1. Docker container check
    echo -e "\n── Docker Container"
    local container_status
    container_status=$(docker ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>/dev/null || true)
    if [ -n "${container_status}" ]; then
        local c_name c_status c_ports
        c_name=$(echo "${container_status}" | cut -d'|' -f1)
        c_status=$(echo "${container_status}" | cut -d'|' -f2)
        c_ports=$(echo "${container_status}" | cut -d'|' -f3)
        echo -e "  ${GREEN}[OK]${NC}   Container '${c_name}' is running"
        echo "         Status: ${c_status}"
        echo "         Ports:  ${c_ports}"
    else
        echo -e "  ${RED}[FAIL]${NC} Container '${CONTAINER_NAME}' is not running"
        all_ok=false
    fi

    # 2. App port TCP check
    if [ "${HOST_PORT}" -gt 0 ] 2>/dev/null; then
        echo -e "\n── App Port (${HOST_PORT}/tcp)"
        if check_port "localhost" "${HOST_PORT}"; then
            echo -e "  ${GREEN}[OK]${NC}   localhost:${HOST_PORT} is accepting connections"
        else
            echo -e "  ${RED}[FAIL]${NC} localhost:${HOST_PORT} is not reachable"
            all_ok=false
        fi
    fi

    # 3. HTTP health check
    if [ "${HOST_PORT}" -gt 0 ] 2>/dev/null; then
        echo -e "\n── HTTP Health Check (${HOST_PORT})"
        local http_code
        http_code=$(check_http "http://localhost:${HOST_PORT}/" 2>/dev/null) || true
        if [ "${http_code}" -ge 200 ] 2>/dev/null && [ "${http_code}" -lt 500 ] 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}   HTTP ${http_code} at http://localhost:${HOST_PORT}/"
        else
            echo -e "  ${YELLOW}[WARN]${NC} HTTP returned ${http_code} at http://localhost:${HOST_PORT}/"
        fi
    fi

    # Summary
    echo -e "\n=================================================="
    if [ "${all_ok}" = true ]; then
        echo -e "  Result: ${APP_NAME^^} — ${GREEN}ALL CHECKS PASSED${NC}"
    else
        echo -e "  Result: ${APP_NAME^^} — ${RED}SOME CHECKS FAILED${NC}"
    fi
    echo "=================================================="

    if [ "${all_ok}" = true ]; then return 0; else return 1; fi
}

# =============================================================================
# Shared helpers
# =============================================================================
install_extension() {
    local ext_id="$1"
    local ext_name="${2:-$ext_id}"
    echo -n "  Installing ${ext_name}... "
    if docker exec "${CONTAINER_NAME}" code-server --install-extension "${ext_id}" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}SKIPPED (may not be on Open VSX)${NC}"
    fi
}

install_tool_root() {
    local tool_name="$1"
    shift
    echo -n "  Installing ${tool_name}... "
    if docker exec -u root "${CONTAINER_NAME}" bash -c "$*" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}SKIPPED (install failed, check manually)${NC}"
    fi
}

wait_for_container() {
    local retries=0 max_retries=15
    while [ $retries -lt $max_retries ]; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            return 0
        fi
        retries=$((retries + 1))
        sleep 2
    done
    return 1
}

fix_container_permissions() {
    docker exec -u root "${CONTAINER_NAME}" bash -c "
        chown -R coder:coder /home/coder/.local 2>/dev/null || true
        mkdir -p /home/coder/.local/state /home/coder/.local/bin /home/coder/.local/share/code-server/User
        chown -R coder:coder /home/coder/.local
        chown -R coder:coder /home/coder/.config 2>/dev/null || true
        chown -R coder:coder /home/coder/projects 2>/dev/null || true
    " 2>/dev/null
}

install_system_deps() {
    log_info "Updating apt and installing base packages..."
    install_tool_root "Base APT packages" "$(valtunox_remote_script_base_apt)"

    log_info "Installing Node.js 20 LTS..."
    install_tool_root "Node.js 20" "$(valtunox_remote_script_nodejs_20)"
    log_info "Node.js: $(docker exec ${CONTAINER_NAME} node --version 2>/dev/null || echo 'check manually')"
    log_info "npm:     $(docker exec ${CONTAINER_NAME} npm --version 2>/dev/null || echo 'check manually')"

    log_info "Installing Docker CLI + Buildx + Compose v2 (DooD)..."
    install_tool_root "Docker CLI + plugins" "$(valtunox_remote_script_docker_cli_dood)"
    install_tool_root "Docker Compose (standalone binary)" "$(valtunox_remote_script_docker_standalone_compose)"
    install_tool_root "Docker group (coder user)" "$(valtunox_remote_script_docker_group_membership)"
}

install_extensions() {
    log_info "AI Coding Assistants:"
    install_extension "codeium.codeium"           "Codeium (AI Autocomplete)"
    install_extension "Continue.continue"         "Continue.dev (Multi-LLM AI)"
    install_extension "TabbyML.vscode-tabby"      "Tabby (Self-hosted AI)"

    log_info "Languages & Infrastructure:"
    install_extension "ms-vscode-remote.remote-containers" "Dev Containers"
    install_extension "hashicorp.terraform"       "Terraform"
    install_extension "redhat.vscode-yaml"        "YAML"
    install_extension "esbenp.prettier-vscode"    "Prettier"
    install_extension "dbaeumer.vscode-eslint"    "ESLint"
    install_extension "bradlc.vscode-tailwindcss" "Tailwind CSS IntelliSense"
    install_extension "ms-python.python"          "Python"
    install_extension "golang.go"                 "Go"

    log_info "Productivity & Git:"
    install_extension "eamodio.gitlens"            "GitLens"
    install_extension "mhutchie.git-graph"         "Git Graph"
}

install_ai_tools() {
    # Claude Code — native installer + symlink
    echo -n "  Installing Claude Code... "
    if docker exec -u root "${CONTAINER_NAME}" bash -c '
        if command -v claude >/dev/null 2>&1; then exit 0; fi
        curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null
        for p in "$HOME/.local/bin/claude" /root/.local/bin/claude; do
            if [ -f "$p" ] || [ -L "$p" ]; then
                ln -sf "$p" /usr/local/bin/claude
                break
            fi
        done
        command -v claude >/dev/null 2>&1
    ' > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}SKIPPED (install failed — run manually inside container)${NC}"
    fi

    install_tool_root "Gemini CLI"   "npm install -g --prefix /usr/local @google/gemini-cli 2>/dev/null"
    install_tool_root "OpenAI Codex" "npm install -g --prefix /usr/local @openai/codex 2>/dev/null"
}

install_devops_tools() {
    install_tool_root "GitHub CLI" \
        'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq gh > /dev/null 2>&1'

    install_tool_root "Terraform" \
        'wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list > /dev/null && apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq terraform > /dev/null 2>&1'

    # kubectl / Helm / Minikube / AWS CLI / Azure CLI / gcloud CLI removed —
    # users install these on demand from the IDE terminal if they need them.
}

verify_installations() {
    echo ""
    log_info "Tool verification:"
    echo -n "  Node.js:    "; docker exec "${CONTAINER_NAME}" node --version 2>/dev/null || echo "not found"
    echo -n "  npm:        "; docker exec "${CONTAINER_NAME}" npm --version 2>/dev/null || echo "not found"
    echo -n "  Claude:     "; docker exec "${CONTAINER_NAME}" claude --version 2>/dev/null || echo "not found (auth required)"
    echo -n "  Gemini:     "; docker exec "${CONTAINER_NAME}" gemini --version 2>/dev/null || echo "not found"
    echo -n "  Codex:      "; docker exec "${CONTAINER_NAME}" codex --version 2>/dev/null || echo "not found"
    echo -n "  gh:         "; docker exec "${CONTAINER_NAME}" gh --version 2>/dev/null | head -1 || echo "not found"
    echo -n "  Terraform:  "; docker exec "${CONTAINER_NAME}" terraform --version 2>/dev/null | head -1 || echo "not found"
    echo -n "  Python:     "; docker exec "${CONTAINER_NAME}" python3 --version 2>/dev/null || echo "not found"
    echo -n "  Git:        "; docker exec "${CONTAINER_NAME}" git --version 2>/dev/null || echo "not found"
    echo -n "  Docker:     "; docker exec "${CONTAINER_NAME}" docker version --format '{{.Client.Version}}' 2>/dev/null || echo "not found (check socket + DOCKER_GID)"
    echo -n "  Compose v2: "; docker exec "${CONTAINER_NAME}" docker compose version 2>/dev/null | head -1 || echo "not found"
    echo -n "  compose v1: "; docker exec "${CONTAINER_NAME}" docker-compose version 2>/dev/null | head -1 || echo "not found"

    echo ""
    log_info "Installed extensions:"
    docker exec "${CONTAINER_NAME}" code-server --list-extensions 2>/dev/null | while read -r ext; do
        echo "  - ${ext}"
    done
}

seed_devcontainer() {
    local dest_dir="/home/coder/projects/.devcontainer"
    local tmp_file="/tmp/_valtunox_devcontainer.json"

    log_info "Generating devcontainer template..."
    generate_devcontainer_json > "${tmp_file}"
    docker exec -u root "${CONTAINER_NAME}" mkdir -p "${dest_dir}" 2>/dev/null || true
    docker cp "${tmp_file}" "${CONTAINER_NAME}:${dest_dir}/devcontainer.json" 2>/dev/null && \
        log_info "Template copied to ${dest_dir}/devcontainer.json" || \
        log_warn "Could not copy devcontainer template (non-fatal)"
    docker exec -u root "${CONTAINER_NAME}" \
        chown -R coder:coder "${dest_dir}" 2>/dev/null || true
    rm -f "${tmp_file}"
    log_info "Devcontainer template ready — Ctrl+Shift+P → Dev Containers: Reopen in Container"
}

print_banner() {
    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║         ${GREEN}Valtunox IDE${BLUE}  is ready!              ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "IDE:       http://localhost:${HOST_PORT}"
    log_info "Dashboard: http://localhost:3000/dashboard?tab=icodebase"
    log_info "Password:  ${PASSWORD}"
    echo ""
    log_info "AI CLI tools — authenticate from the integrated terminal:"
    echo "  claude  — Run 'claude' or set ANTHROPIC_API_KEY"
    echo "  gemini  — Run 'gemini' (free tier: 1000 req/day)"
    echo "  codex   — Run 'codex' or set OPENAI_API_KEY"
    echo "  gh      — Run 'gh auth login'"
    echo ""
    log_info "Dev ports available on host:"
    echo "  React/Vite:  http://localhost:5173"
    echo "  Node/CRA:    http://localhost:3000"
    echo "  General:     http://localhost:8000"
    echo "  Valtunox:    http://localhost:8741 - 8749"
    echo ""
    log_info "Devcontainer (inner environment):"
    echo "  1. Open a project folder in the IDE"
    echo "  2. Ctrl+Shift+P → Dev Containers: Reopen in Container"
    echo "  3. Template at: /home/coder/projects/.devcontainer/devcontainer.json"
    echo ""
}

# #############################################################################
#                         POST-DEPLOY MODE
# #############################################################################
run_post_deploy() {
    log_section "Post-Deploy: Waiting for container"

    if ! wait_for_container; then
        log_warn "Container '${CONTAINER_NAME}' not found. Skipping post-deploy."
        exit 0
    fi
    log_info "Container is running"
    sleep 5

    log_section "Post-Deploy: Fix permissions"
    fix_container_permissions
    log_info "Permissions fixed"

    log_section "Post-Deploy: System dependencies"
    install_system_deps

    log_section "Post-Deploy: VS Code extensions"
    install_extensions

    log_section "Post-Deploy: AI CLI tools"
    install_ai_tools

    log_section "Post-Deploy: DevOps tools"
    install_devops_tools

    log_section "Post-Deploy: Finalize"
    docker exec -u root "${CONTAINER_NAME}" bash -c "
        chown -R coder:coder /home/coder/.local 2>/dev/null || true
        chown -R coder:coder /home/coder/.config 2>/dev/null || true
        chown -R coder:coder /home/coder/.npm 2>/dev/null || true
    " 2>/dev/null

    docker restart "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    sleep 5

    log_section "Post-Deploy: Connection Check"
    run_connection_check || true

    log_info "Post-deploy complete for ${CONTAINER_NAME}"
}

# #############################################################################
#                         FULL INSTALL MODE
# #############################################################################
run_full_install() {

    # PHASE 1: Preflight
    log_section "Phase 1: Preflight Checks"

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH. Install Docker first."
        exit 1
    fi
    log_info "Docker found: $(docker --version)"

    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running. Start Docker first."
        exit 1
    fi
    log_info "Docker daemon is running"
    log_info "DEPLOY_DIR:     ${DEPLOY_DIR}"
    log_info "GENERATED_PATH: ${GENERATED_PATH}"

    # PHASE 2: Clean Up
    log_section "Phase 2: Clean Up Existing Container"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Container '${CONTAINER_NAME}' already exists. Stopping and removing..."
        docker stop "${CONTAINER_NAME}" > /dev/null 2>&1 || true
        docker rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
        sleep 2
        log_info "Old container removed"
    else
        log_info "No existing container to clean up"
    fi

    # Kill any non-docker process still holding the port
    if command -v lsof &> /dev/null; then
        PIDS=$(lsof -ti :"${HOST_PORT}" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            for PID in $PIDS; do
                PNAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
                if echo "$PNAME" | grep -qE "^(systemd|sshd|init)$"; then
                    log_warn "Skipping critical process $PNAME (PID $PID) on port ${HOST_PORT}"
                else
                    log_warn "Killing $PNAME (PID $PID) on port ${HOST_PORT}"
                    kill -9 "$PID" 2>/dev/null || true
                fi
            done
            sleep 2
        fi
    fi

    log_info "Cleaning stale volume data..."
    rm -rf "${HOST_CONFIG_DIR}" "${HOST_PROJECTS_DIR}" "${HOST_DATA_DIR}" 2>/dev/null || true
    log_info "Old volume data cleared"

    # PHASE 3: Host Directories
    log_section "Phase 3: Create Host Directories"

    mkdir -p "${HOST_CONFIG_DIR}" "${HOST_PROJECTS_DIR}" "${HOST_DATA_DIR}"
    log_info "Created: ${HOST_CONFIG_DIR}"
    log_info "Created: ${HOST_PROJECTS_DIR}"
    log_info "Created: ${HOST_DATA_DIR}"

    if [ -d "${GENERATED_PATH}" ]; then
        log_info "Generated path found: ${GENERATED_PATH}"
    else
        mkdir -p "${GENERATED_PATH}"
        log_warn "Created generated path: ${GENERATED_PATH}"
    fi

    if command -v chown &> /dev/null && [ "$(id -u)" = "0" ]; then
        chown -R 1000:1000 "${HOST_CONFIG_DIR}" "${HOST_PROJECTS_DIR}" "${HOST_DATA_DIR}"
        log_info "Fixed host directory permissions (UID 1000)"
    else
        log_warn "Run 'sudo chown -R 1000:1000 ~/code-server/{config,projects,data}' if you get permission errors"
    fi

    # PHASE 4: Generate Settings
    log_section "Phase 4: Generate Settings File"

    mkdir -p "$(dirname "${SETTINGS_FILE}")"
    if [ ! -f "${SETTINGS_FILE}" ]; then
        generate_settings_json > "${SETTINGS_FILE}"
        log_info "Generated settings.json at ${SETTINGS_FILE}"
    else
        log_info "settings.json already exists, keeping it"
    fi

    # PHASE 5: Start Container
    log_section "Phase 5: Start Code-Server Container"

    log_info "Pulling latest image..."
    docker pull "${IMAGE}"

    DOCKER_RUN_EXTRA=()
    if [ -S /var/run/docker.sock ]; then
        DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)
        DOCKER_RUN_EXTRA+=( -v /var/run/docker.sock:/var/run/docker.sock )
        if [ -n "${DOCKER_SOCK_GID}" ]; then
            DOCKER_RUN_EXTRA+=( --group-add "${DOCKER_SOCK_GID}" )
        fi
        log_info "Docker-outside-of-Docker: mounting host socket (group ${DOCKER_SOCK_GID:-unknown})"
    else
        log_warn "No /var/run/docker.sock — Docker CLI inside IDE won't reach a daemon"
    fi

    log_info "Starting container..."
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
        -p "127.0.0.1:3001:3001" \
        -p "127.0.0.1:3002:3002" \
        -p "127.0.0.1:3008:3008" \
        -p "127.0.0.1:3009:3009" \
        -p "127.0.0.1:4200:4200" \
        -p "127.0.0.1:5173:5173" \
        -p "127.0.0.1:8747:8747" \
        -p "127.0.0.1:8749:8749" \
        -p "127.0.0.1:8888:8888" \
        -p "127.0.0.1:18786:18786" \
        -p "127.0.0.1:18788:18788" \
        -e "PASSWORD=${PASSWORD}" \
        -e "SUDO_PASSWORD=${SUDO_PASSWORD}" \
        -e PROXY_DOMAIN=code-server.local \
        -e TZ="${TZ}" \
        -v "${HOST_CONFIG_DIR}:/home/coder/.config" \
        -v "${HOST_PROJECTS_DIR}:/home/coder/projects" \
        -v "${GENERATED_PATH}:/home/coder/projects/generated" \
        -v "${HOST_DATA_DIR}:/home/coder/.local/share/code-server" \
        -v "${SETTINGS_FILE}:/home/coder/.local/share/code-server/User/settings.json" \
        "${DOCKER_RUN_EXTRA[@]}" \
        --cpus="${CPU_LIMIT}" \
        --memory="${MEMORY_LIMIT}" \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        "${IMAGE}" > /dev/null

    log_info "Container started"

    log_info "Waiting for code-server to initialize..."
    sleep 5

    RETRIES=0
    MAX_RETRIES=12
    while [ $RETRIES -lt $MAX_RETRIES ]; do
        if docker exec "${CONTAINER_NAME}" pgrep -f "code-server" > /dev/null 2>&1; then
            log_info "Code-server process is running"
            break
        fi
        RETRIES=$((RETRIES + 1))
        sleep 5
    done

    if [ $RETRIES -eq $MAX_RETRIES ]; then
        log_error "Code-server failed to start. Check: docker logs ${CONTAINER_NAME}"
        exit 1
    fi

    # PHASE 6: Fix Permissions
    log_section "Phase 6: Fix Permissions Inside Container"
    fix_container_permissions
    log_info "Permissions fixed"

    # PHASE 7: System Dependencies
    log_section "Phase 7: Install System Dependencies"
    install_system_deps

    # PHASE 8: Extensions
    log_section "Phase 8: Install VS Code Extensions"
    install_extensions

    # PHASE 9: AI CLI Tools
    log_section "Phase 9: Install AI CLI Tools"
    install_ai_tools

    # PHASE 10: DevOps Tools
    log_section "Phase 10: Install DevOps Tools"
    install_devops_tools

    # PHASE 11: Final Permissions
    log_section "Phase 11: Final Permission Fix"
    docker exec -u root "${CONTAINER_NAME}" bash -c "
        chown -R coder:coder /home/coder/.local 2>/dev/null || true
        chown -R coder:coder /home/coder/.config 2>/dev/null || true
        chown -R coder:coder /home/coder/.npm 2>/dev/null || true
    " 2>/dev/null
    log_info "All permissions fixed"

    # PHASE 12: Restart & Verify
    log_section "Phase 12: Restart & Verify"
    log_info "Restarting container..."
    docker restart "${CONTAINER_NAME}" > /dev/null 2>&1
    sleep 8
    verify_installations

    # PHASE 13: Seed Devcontainer
    log_section "Phase 13: Seed Devcontainer Template"
    seed_devcontainer

    # PHASE 14: Connection Check
    log_section "Phase 14: Connection Check"
    run_connection_check || true

    # Done
    log_section "Valtunox IDE (Code-Server) — Setup Complete"
    print_banner
}

# #############################################################################
#                              MAIN
# #############################################################################
case "${1:-}" in
    post-deploy|--post-deploy)
        run_post_deploy
        ;;
    check|--check)
        run_connection_check
        ;;
    *)
        run_full_install
        ;;
esac

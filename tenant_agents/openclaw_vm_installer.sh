#!/bin/bash

# ==============================================================================
# OPENCLAW VM INSTALLER — ALL-IN-ONE SCRIPT (openclaw_vm_installer.sh)
# ==============================================================================
# One script. Four modes. Pick with a flag (default = install).
#
#   (default)     Install OpenClaw on a remote VM via SSH
#   --preflight   Pre-flight VM readiness checks only (no install)
#   --update      Update / backup / restore / rotate / reset / uninstall / etc.
#   --configure   Configure OpenClaw (telegram token, API keys, channels)
#   --help        Show help for any mode (or all modes)
#
# Works two ways:
#   1. Invoked by the Go provisioner (services/openclaw/openclaw.go)
#      — passes flags programmatically: --hostname, --username, --private-key, ...
#   2. Copy-pasted to a terminal by a human operator
#      — edit the DEFAULTS block below, or pass flags on the CLI
#
# Usage:
#   # --- LOCAL install (copy-paste on the target VM, no args needed) ---
#   curl -fsSL https://.../openclaw_vm_installer.sh | bash
#   ./openclaw_vm_installer.sh                                   # install locally
#
#   # --- REMOTE install (run from your laptop, SSH into a VM) ---
#   ./openclaw_vm_installer.sh --hostname 1.2.3.4 --username ubuntu --private-key ~/.ssh/k.pem
#
#   # --- Other modes ---
#   ./openclaw_vm_installer.sh --preflight                       # readiness check
#   ./openclaw_vm_installer.sh --update --action backup          # maintenance
#   ./openclaw_vm_installer.sh --configure --telegram-token ...  # configure bot
#   ./openclaw_vm_installer.sh --health --action status          # health / control
#   ./openclaw_vm_installer.sh --help                            # all modes
#
# When --hostname is omitted (or is localhost / 127.0.0.1), the script runs
# every command on THIS machine with no SSH — true copy-paste-and-run.
# ==============================================================================

set -uo pipefail
# NOTE: `set -e` is intentionally omitted at the top level. Individual commands
# that must succeed use explicit error checks (|| exit 1). This prevents
# false-positive failures from SSH probes, grep -q in pipes, and other
# commands whose non-zero exit is normal control flow — not an error.

# ==============================================================================
# DEFAULTS — EDIT THESE FOR COPY-PASTE USE, OR OVERRIDE VIA CLI
# ==============================================================================
DEFAULT_HOSTNAME=""          # empty = install LOCALLY on this machine (no SSH)
DEFAULT_USERNAME=""          # e.g., ubuntu, ec2-user, root (unused in local mode)
DEFAULT_PRIVATE_KEY=""       # e.g., ~/.ssh/mykey.pem (unused in local mode)

# Install mode
DEFAULT_INSTALL_METHOD="npm"                 # npm | oneliner | source
DEFAULT_NODE_VERSION="24"                    # Node.js major (>= 22 required)
SKIP_CLEANUP=false
SKIP_DOCKER=false
DRY_RUN=false

# Preflight mode
MIN_DISK_GB=5
MIN_RAM_MB=1024
REQUIRED_PORTS=(18789)
SSH_TIMEOUT=15

# Update mode
DEFAULT_UPDATE_CHANNEL="stable"              # stable | beta | dev
DEFAULT_BACKUP_DIR="./backups"

# Update + health share --action; default is picked per-mode after parsing:
#   update  → "update"  (update|backup|restore|rotate|reset|uninstall|node|security)
#   health  → "status"  (status|start|stop|restart|logs|doctor|pairings|resources|processes|config)
ACTION=""
LOG_LINES=50                                  # --lines N (health logs)

# Configure mode
DEFAULT_MODEL="anthropic/claude-opus-4-6"
DEFAULT_DM_POLICY="pairing"                  # pairing | allowlist | open
DEFAULT_GATEWAY_PORT=18789
TELEGRAM_BOT_TOKEN=""
ANTHROPIC_API_KEY=""
OPENAI_API_KEY=""
DISCORD_BOT_TOKEN=""
SLACK_BOT_TOKEN=""
SLACK_APP_TOKEN=""
START_GATEWAY=false
# ==============================================================================


# ==============================================================================
# RUNTIME STATE
# ==============================================================================
MODE="install"

VM_HOSTNAME="${DEFAULT_HOSTNAME}"
VM_USERNAME="${DEFAULT_USERNAME}"
VM_PRIVATE_KEY="${DEFAULT_PRIVATE_KEY}"

# LOCAL_MODE=true → no SSH, run all commands on THIS machine.
# Auto-enabled when --hostname is empty OR is localhost/127.0.0.1.
LOCAL_MODE=false

INSTALL_METHOD="${DEFAULT_INSTALL_METHOD}"
NODE_VERSION="${DEFAULT_NODE_VERSION}"

UPDATE_CHANNEL="${DEFAULT_UPDATE_CHANNEL}"
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"

MODEL="${DEFAULT_MODEL}"
DM_POLICY="${DEFAULT_DM_POLICY}"
GATEWAY_PORT="${DEFAULT_GATEWAY_PORT}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# Progress / counters
CURRENT_STEP=0
TOTAL_STEPS=0
START_TIME=$(date +%s)
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; TOTAL_CHECKS=0

# Log file — name depends on mode (set after parsing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=""


# ==============================================================================
# LOGGING HELPERS
# ==============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    [ -n "$LOG_FILE" ] && echo "$msg" >> "$LOG_FILE"
    echo -e "$1"
}
log_info()    { log "${BLUE}  [INFO]${NC} $1"; }
log_success() { log "${GREEN}  [OK]${NC} $1"; }
log_warn()    { log "${YELLOW}  [WARN]${NC} $1"; }
log_error()   { log "${RED}  [ERROR]${NC} $1"; }
log_header()  { log ""; log "${BOLD}${CYAN}--- $1 ---${NC}"; }

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local pct=0
    [ "$TOTAL_STEPS" -gt 0 ] && pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    log ""
    log "${BOLD}${MAGENTA}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] (${pct}%) $1${NC}"
    log "${MAGENTA}────────────────────────────────────────────────────────────${NC}"
}

log_check() { TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); log "${BLUE}[CHECK ${TOTAL_CHECKS}]${NC} $1"; }
log_pass()  { PASS_COUNT=$((PASS_COUNT + 1)); log "${GREEN}  [PASS]${NC} $1"; }
log_fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); log "${RED}  [FAIL]${NC} $1"; }

elapsed_time() {
    local now=$(date +%s); local e=$((now - START_TIME))
    echo "$((e / 60))m $((e % 60))s"
}


# ==============================================================================
# SSH HELPERS
# ==============================================================================
ssh_cmd() {
    if [ "$LOCAL_MODE" = true ]; then
        # Local execution — `eval` handles both `ssh_cmd "shell string"` and
        # `ssh_cmd /bin/bash <<EOF ... EOF` (heredoc on stdin) call patterns.
        eval "$@"
        return $?
    fi
    ssh -i "$VM_PRIVATE_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="${SSH_TIMEOUT}" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=5 \
        "$VM_USERNAME@$VM_HOSTNAME" \
        "$@"
}

ssh_cmd_quiet() {
    if [ "$LOCAL_MODE" = true ]; then
        eval "$@" 2>/dev/null
        return $?
    fi
    ssh -q -i "$VM_PRIVATE_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="${SSH_TIMEOUT}" \
        -o BatchMode=yes \
        "$VM_USERNAME@$VM_HOSTNAME" \
        "$@"
}

# copy_up <local_src> <remote_dest_path>    — upload (scp) or local cp
# copy_down <remote_src_path> <local_dest>  — download (scp) or local cp
# Remote paths use ~ which expands on the remote shell; locally we expand to $HOME.
copy_up() {
    local src="$1" dst="$2"
    if [ "$LOCAL_MODE" = true ]; then
        local expanded="${dst/#\~/$HOME}"
        mkdir -p "$(dirname "$expanded")"
        cp "$src" "$expanded"
    else
        scp -i "$VM_PRIVATE_KEY" -o StrictHostKeyChecking=no "$src" "$VM_USERNAME@$VM_HOSTNAME:$dst"
    fi
}
copy_down() {
    local src="$1" dst="$2"
    if [ "$LOCAL_MODE" = true ]; then
        local expanded="${src/#\~/$HOME}"
        cp "$expanded" "$dst"
    else
        scp -i "$VM_PRIVATE_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$VM_HOSTNAME:$src" "$dst"
    fi
}

confirm_dangerous() {
    local action="$1"
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will ${action} on ${VM_USERNAME}@${VM_HOSTNAME}${NC}"
    echo -e "${RED}This action cannot be easily undone.${NC}"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
}

validate_common_inputs() {
    # Auto-detect LOCAL MODE: empty hostname, or hostname is the loopback / this host.
    if [ -z "$VM_HOSTNAME" ] || [ "$VM_HOSTNAME" = "localhost" ] || [ "$VM_HOSTNAME" = "127.0.0.1" ] || [ "$VM_HOSTNAME" = "YOUR_VM_IP_HERE" ]; then
        LOCAL_MODE=true
        VM_HOSTNAME="localhost"
        [ -z "$VM_USERNAME" ] && VM_USERNAME="$(whoami)"
        log_info "No --hostname given — running in LOCAL MODE (installing on this machine: $(hostname))"
        return 0
    fi

    # Remote (SSH) mode — key is mandatory.
    if [ -z "$VM_PRIVATE_KEY" ] || [ ! -f "$VM_PRIVATE_KEY" ]; then
        log_error "Remote mode requires --private-key to an existing file (got: '${VM_PRIVATE_KEY}')"
        log_info  "Omit --hostname to install on THIS machine instead (no SSH)."
        exit 1
    fi
    [ -z "$VM_USERNAME" ] && VM_USERNAME="ubuntu"
}


# ==============================================================================
# HELP
# ==============================================================================
print_help() {
    cat << 'HELPEOF'
OpenClaw VM Installer — All-in-One Script

USAGE:
    # Local install (zero args — runs on THIS machine, no SSH)
    ./openclaw_vm_installer.sh

    # Remote install (SSH into another VM)
    ./openclaw_vm_installer.sh --hostname HOST --username USER --private-key KEY

    ./openclaw_vm_installer.sh [MODE] [OPTIONS]

Omitting --hostname (or passing localhost / 127.0.0.1) enables LOCAL MODE:
every step runs on THIS machine via a plain shell — no SSH, no key required.
Useful for copy-paste onto a fresh VM via curl | bash.

MODES (default: install):
    (no flag)      Install OpenClaw on the remote VM
    --preflight    Only run VM readiness checks (no changes)
    --update       Run maintenance actions (update/backup/etc.)
    --configure    Configure OpenClaw (tokens, API keys, channels)
    --health       Monitor / control the running gateway
    --help         Show this help

COMMON OPTIONS (all modes):
    --hostname HOST          Target hostname/IP
    --username USER          SSH username
    --private-key KEY        Path to SSH private key (.pem)

INSTALL MODE OPTIONS:
    --install-method METHOD  npm (default), oneliner, source
    --node-version VER       Node.js major (default: 24, min: 22)
    --skip-cleanup           Don't remove previous Node/OpenClaw installs
    --skip-docker            Skip Docker install (no sandboxing)
    --dry-run                Preview commands without executing

UPDATE MODE OPTIONS:
    --action ACTION          update (default) | backup | restore | rotate |
                             reset | uninstall | node | security
    --channel CHANNEL        stable (default) | beta | dev
    --backup-dir DIR         Local backup directory (default: ./backups)

HEALTH MODE OPTIONS:
    --action ACTION          status (default) | start | stop | restart |
                             logs | doctor | pairings | resources |
                             processes | config
    --lines N                Log lines to show for --action logs (default: 50)

CONFIGURE MODE OPTIONS:
    --telegram-token TOKEN   Telegram bot token (from @BotFather)
    --anthropic-key KEY      Anthropic API key (sk-ant-...)
    --openai-key KEY         OpenAI API key (sk-...)
    --model MODEL            AI model (default: anthropic/claude-opus-4-6)
    --dm-policy POLICY       pairing | allowlist | open
    --gateway-port PORT      Gateway port (default: 18789)
    --discord-token TOKEN    Discord bot token
    --slack-bot-token TOKEN  Slack bot token (xoxb-...)
    --slack-app-token TOKEN  Slack app token (xapp-...)
    --start-gateway          Start the gateway after configuration

EXAMPLES:
    # Fresh install (install is default)
    ./openclaw_vm_installer.sh --hostname 34.56.78.90 --username ubuntu \
        --private-key ~/.ssh/key.pem

    # Check VM readiness before installing
    ./openclaw_vm_installer.sh --preflight --hostname 34.56.78.90 \
        --username ubuntu --private-key ~/.ssh/key.pem

    # Update OpenClaw to latest stable
    ./openclaw_vm_installer.sh --update --action update \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem

    # Backup workspace
    ./openclaw_vm_installer.sh --update --action backup \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem

    # Configure Telegram + Anthropic and start gateway
    ./openclaw_vm_installer.sh --configure \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem \
        --telegram-token "123456789:ABC..." \
        --anthropic-key "sk-ant-..." \
        --start-gateway

    # Full health report (default --action status)
    ./openclaw_vm_installer.sh --health \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem

    # Tail recent gateway logs
    ./openclaw_vm_installer.sh --health --action logs --lines 100 \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem

    # Restart the gateway
    ./openclaw_vm_installer.sh --health --action restart \
        --hostname 34.56.78.90 --username ubuntu --private-key ~/.ssh/key.pem
HELPEOF
}


# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        # --- mode flags ---
        --preflight)       MODE="preflight"; shift ;;
        --update)          MODE="update"; shift ;;
        --configure)       MODE="configure"; shift ;;
        --health)          MODE="health"; shift ;;
        --help|-h)         print_help; exit 0 ;;

        # --- common ---
        --hostname)        VM_HOSTNAME="$2"; shift 2 ;;
        --username)        VM_USERNAME="$2"; shift 2 ;;
        --private-key)     VM_PRIVATE_KEY="$2"; shift 2 ;;

        # --- install ---
        --install-method)  INSTALL_METHOD="$2"; shift 2 ;;
        --node-version)    NODE_VERSION="$2"; shift 2 ;;
        --skip-cleanup)    SKIP_CLEANUP=true; shift ;;
        --skip-docker)     SKIP_DOCKER=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;

        # --- update + health (shared --action) ---
        --action)          ACTION="$2"; shift 2 ;;
        --channel)         UPDATE_CHANNEL="$2"; shift 2 ;;
        --backup-dir)      BACKUP_DIR="$2"; shift 2 ;;
        --lines)           LOG_LINES="$2"; shift 2 ;;

        # --- configure ---
        --telegram-token)  TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
        --anthropic-key)   ANTHROPIC_API_KEY="$2"; shift 2 ;;
        --openai-key)      OPENAI_API_KEY="$2"; shift 2 ;;
        --model)           MODEL="$2"; shift 2 ;;
        --dm-policy)       DM_POLICY="$2"; shift 2 ;;
        --gateway-port)    GATEWAY_PORT="$2"; shift 2 ;;
        --discord-token)   DISCORD_BOT_TOKEN="$2"; shift 2 ;;
        --slack-bot-token) SLACK_BOT_TOKEN="$2"; shift 2 ;;
        --slack-app-token) SLACK_APP_TOKEN="$2"; shift 2 ;;
        --start-gateway)   START_GATEWAY=true; shift ;;

        *)
            log_error "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# Set log filename now that MODE is known
LOG_FILE="${SCRIPT_DIR}/${MODE}_$(date +%Y%m%d_%H%M%S).log"


# ==============================================================================
# MODE: PREFLIGHT
# ==============================================================================
run_preflight() {
    log ""
    log "${BOLD}${CYAN}========================================${NC}"
    log "${BOLD}${CYAN}  OpenClaw VM Pre-Flight Check${NC}"
    log "${BOLD}${CYAN}========================================${NC}"
    log ""
    log "  Target:      ${BOLD}${VM_USERNAME}@${VM_HOSTNAME}${NC}"
    log "  Private Key:  ${VM_PRIVATE_KEY}"
    log "  Log File:     ${LOG_FILE}"
    log ""

    validate_common_inputs

    # 1. Connectivity
    if [ "$LOCAL_MODE" = true ]; then
        log_check "Local-mode readiness (no SSH)"
        log_pass "Running on $(hostname) as $(whoami)"
    else
        log_check "SSH connectivity to ${VM_USERNAME}@${VM_HOSTNAME}"
        local PF_SSH_OK=""
        PF_SSH_OK=$(ssh_cmd_quiet "echo OK" 2>&1) || true
        if echo "$PF_SSH_OK" | grep -q "OK"; then
            log_pass "SSH connection successful"
        else
            log_fail "SSH connection failed. Check hostname, username, key, firewall."
            log_fail "Output: ${PF_SSH_OK}"
            exit 1
        fi
    fi

    # 2. OS
    log_check "Operating system compatibility"
    local OS_ID OS_VERSION
    OS_ID=$(ssh_cmd_quiet "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")
    OS_VERSION=$(ssh_cmd_quiet "grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "0")
    log_info "Detected: ${OS_ID} ${OS_VERSION}"
    case "$OS_ID" in
        ubuntu|debian) log_pass "${OS_ID} ${OS_VERSION} is supported" ;;
        centos|rhel|rocky|alma) log_warn "${OS_ID} ${OS_VERSION} — optimized for Ubuntu/Debian, may work" ;;
        *) log_warn "Unrecognized OS: ${OS_ID}" ;;
    esac

    # 3. Arch
    log_check "CPU architecture"
    local ARCH; ARCH=$(ssh_cmd_quiet "uname -m" 2>/dev/null || echo "unknown")
    case "$ARCH" in
        x86_64|amd64|aarch64|arm64) log_pass "Architecture: ${ARCH}" ;;
        *) log_warn "Architecture: ${ARCH} — may have compatibility issues" ;;
    esac

    # 4. Disk
    log_check "Available disk space (need >= ${MIN_DISK_GB} GB free)"
    local DISK_FREE_KB DISK_FREE_GB
    DISK_FREE_KB=$(ssh_cmd_quiet "df / --output=avail | tail -1 | tr -d ' '" 2>/dev/null || echo "0")
    DISK_FREE_GB=$((DISK_FREE_KB / 1024 / 1024))
    if [ "$DISK_FREE_GB" -ge "$MIN_DISK_GB" ]; then
        log_pass "Free disk space: ${DISK_FREE_GB} GB"
    else
        log_fail "Only ${DISK_FREE_GB} GB free (need ${MIN_DISK_GB} GB)"
    fi

    # 5. RAM
    log_check "Total RAM (need >= ${MIN_RAM_MB} MB)"
    local TOTAL_RAM_KB TOTAL_RAM_MB
    TOTAL_RAM_KB=$(ssh_cmd_quiet "grep MemTotal /proc/meminfo | awk '{print \$2}'" 2>/dev/null || echo "0")
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
    if [ "$TOTAL_RAM_MB" -ge "$MIN_RAM_MB" ]; then
        log_pass "Total RAM: ${TOTAL_RAM_MB} MB"
    else
        log_fail "Total RAM: ${TOTAL_RAM_MB} MB (need ${MIN_RAM_MB} MB)"
    fi

    # 6. Internet
    log_check "Internet connectivity"
    local INET_OK; INET_OK=$(ssh_cmd_quiet "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://github.com 2>/dev/null" || echo "000")
    if [[ "$INET_OK" =~ ^(200|301|302)$ ]]; then
        log_pass "Internet access OK (github.com: HTTP ${INET_OK})"
    else
        log_fail "Cannot reach github.com (HTTP ${INET_OK})"
    fi

    # 7. DNS
    log_check "DNS resolution (registry.npmjs.org)"
    local DNS_OK; DNS_OK=$(ssh_cmd_quiet "getent hosts registry.npmjs.org >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "no")
    [ "$DNS_OK" = "yes" ] && log_pass "DNS resolution working" || log_warn "DNS may have issues"

    # 8. Ports
    for PORT in "${REQUIRED_PORTS[@]}"; do
        log_check "Port ${PORT} availability (OpenClaw gateway)"
        local PORT_USED; PORT_USED=$(ssh_cmd_quiet "sudo ss -tlnp | grep ':${PORT} ' | head -1" 2>/dev/null || echo "")
        [ -z "$PORT_USED" ] && log_pass "Port ${PORT} is free" || log_warn "Port ${PORT} in use: ${PORT_USED}"
    done

    # 9. Existing installs
    log_check "Existing Node.js / NVM / OpenClaw / Docker"
    local NODE_VER OC_EXISTS DOCKER_EXISTS
    NODE_VER=$(ssh_cmd_quiet "node --version 2>/dev/null" || echo "not installed")
    OC_EXISTS=$(ssh_cmd_quiet "command -v openclaw 2>/dev/null" || echo "")
    DOCKER_EXISTS=$(ssh_cmd_quiet "command -v docker 2>/dev/null" || echo "")
    log_info "Node.js: ${NODE_VER}"
    [ -n "$OC_EXISTS" ] && log_warn "OpenClaw already installed at ${OC_EXISTS}" || log_info "OpenClaw: not installed (clean)"
    [ -n "$DOCKER_EXISTS" ] && log_info "Docker: present" || log_info "Docker: not installed (optional)"
    log_pass "Inventory complete"

    # 10. sudo
    log_check "Sudo access for ${VM_USERNAME}"
    local SUDO_OK; SUDO_OK=$(ssh_cmd_quiet "sudo -n true 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
    [ "$SUDO_OK" = "yes" ] && log_pass "Passwordless sudo" || log_warn "Sudo may require a password"

    # Summary
    log ""
    log_header "Pre-Flight Summary"
    log "  ${GREEN}PASSED:${NC}  ${PASS_COUNT}"
    log "  ${YELLOW}WARNINGS:${NC} ${WARN_COUNT}"
    log "  ${RED}FAILED:${NC}  ${FAIL_COUNT}"
    log "  ${BLUE}TOTAL:${NC}   ${TOTAL_CHECKS} checks"
    log ""
    if [ "$FAIL_COUNT" -eq 0 ]; then
        log "${GREEN}${BOLD}VM is ready for OpenClaw installation.${NC}"
        log "  Next: ./openclaw_vm_installer.sh --hostname ${VM_HOSTNAME} --username ${VM_USERNAME} --private-key ${VM_PRIVATE_KEY}"
    else
        log "${RED}${BOLD}${FAIL_COUNT} critical issue(s). Fix before installing.${NC}"
        exit 1
    fi
}


# ==============================================================================
# MODE: INSTALL
# ==============================================================================
run_install() {
    TOTAL_STEPS=9
    [ "$SKIP_CLEANUP" = false ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [ "$SKIP_DOCKER" = false ]  && TOTAL_STEPS=$((TOTAL_STEPS + 1))

    log ""
    log "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${BOLD}${CYAN}║           OpenClaw VM Installer                             ║${NC}"
    log "${BOLD}${CYAN}║           ClawdBot Remote Installation Script               ║${NC}"
    log "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "  Target:         ${BOLD}${VM_USERNAME}@${VM_HOSTNAME}${NC}"
    log "  Private Key:     ${VM_PRIVATE_KEY}"
    log "  Install Method:  ${INSTALL_METHOD}"
    log "  Node Version:    ${NODE_VERSION}"
    log "  Skip Cleanup:    ${SKIP_CLEANUP}"
    log "  Skip Docker:     ${SKIP_DOCKER}"
    log "  Dry Run:         ${DRY_RUN}"
    log "  Log File:        ${LOG_FILE}"
    log ""

    validate_common_inputs
    case "$INSTALL_METHOD" in
        npm|oneliner|source) ;;
        *) log_error "Invalid --install-method: $INSTALL_METHOD (use: npm, oneliner, source)"; exit 1 ;;
    esac
    [ "$DRY_RUN" = true ] && log_warn "DRY RUN MODE — nothing will be executed on the remote VM"

    # ---- Step 1: Connectivity ----
    if [ "$LOCAL_MODE" = true ]; then
        log_step "Verifying local environment"
        log_success "Running on $(hostname) as $(whoami)"
        log_info "OS:   $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2 || echo Unknown)"
        log_info "Arch: $(uname -m)"
    else
        log_step "Testing SSH connection"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY] ssh $VM_USERNAME@$VM_HOSTNAME exit"
            log_success "Would test SSH connection"
        else
            local SSH_TEST_OUT=""
            SSH_TEST_OUT=$(ssh_cmd "echo SSH_OK" 2>&1) || true
            if echo "$SSH_TEST_OUT" | grep -q "SSH_OK"; then
                log_success "SSH connection established"
                local REMOTE_OS REMOTE_ARCH
                REMOTE_OS=$(ssh_cmd "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2" 2>/dev/null || echo "Unknown")
                REMOTE_ARCH=$(ssh_cmd "uname -m" 2>/dev/null || echo "unknown")
                log_info "Remote OS: ${REMOTE_OS}"
                log_info "Remote Arch: ${REMOTE_ARCH}"
            else
                log_error "SSH connection failed"
                log_error "SSH output: ${SSH_TEST_OUT}"
                log_info "Check: private key permissions (chmod 600), hostname, username, security group/firewall"
                log_info "Run: $0 --preflight for detailed diagnostics"
                exit 1
            fi
        fi
    fi

    # ---- Step 2: Cleanup ----
    if [ "$SKIP_CLEANUP" = false ]; then
        log_step "Cleaning previous Node.js / OpenClaw installs"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY] Would remove: nodejs, npm, ~/.npm, ~/.node, ~/.openclaw"
        else
            ssh_cmd /bin/bash << 'CLEANUP_EOF'
                if command -v openclaw >/dev/null 2>&1; then openclaw gateway stop 2>/dev/null || true; fi
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl --user stop openclaw 2>/dev/null || true
                    systemctl --user disable openclaw 2>/dev/null || true
                fi
                pkill -f "openclaw" 2>/dev/null || true
                sudo apt-get remove -y nodejs npm 2>/dev/null || true
                sudo rm -rf /usr/lib/node_modules 2>/dev/null || true
                rm -rf ~/.npm ~/.node ~/.openclaw 2>/dev/null || true
                hash -r 2>/dev/null || true
                echo "[SUCCESS] Cleanup complete"
CLEANUP_EOF
            log_success "Previous installs cleaned"
        fi
    fi

    # ---- Step 3: System packages ----
    log_step "Updating system packages"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] apt-get install build-essential python3 make g++ git ffmpeg sqlite3 curl wget"
    else
        ssh_cmd /bin/bash << 'SYSPKG_EOF'
            sudo apt-get update -y 2>&1 | tail -3
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                build-essential python3 make g++ git ffmpeg sqlite3 curl wget \
                ca-certificates gnupg lsb-release unzip psmisc dos2unix \
                2>&1 | tail -5
            echo "[SUCCESS] System packages installed"
SYSPKG_EOF
        log_success "System packages updated"
    fi

    # ---- Step 4: NVM ----
    log_step "Installing NVM"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] curl nvm-sh/nvm/v0.39.7/install.sh | bash"
    else
        ssh_cmd /bin/bash << 'NVM_EOF'
            export NVM_DIR="$HOME/.nvm"
            if [ -s "$NVM_DIR/nvm.sh" ]; then
                source "$NVM_DIR/nvm.sh"
                if command -v nvm >/dev/null 2>&1; then
                    echo "[INFO] NVM already installed: $(nvm --version)"
                    exit 0
                fi
            fi
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            command -v nvm >/dev/null 2>&1 || { echo "[ERROR] NVM install failed"; exit 1; }
            echo "[SUCCESS] NVM installed: $(nvm --version)"
NVM_EOF
        log_success "NVM installed"
    fi

    # ---- Step 5: Node.js ----
    log_step "Installing Node.js v${NODE_VERSION}"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] nvm install ${NODE_VERSION} && nvm alias default ${NODE_VERSION}"
    else
        ssh_cmd /bin/bash << NODEJS_EOF
            export NVM_DIR="\$HOME/.nvm"
            [ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
            nvm install ${NODE_VERSION} 2>&1 | tail -5
            nvm use ${NODE_VERSION}
            nvm alias default ${NODE_VERSION}
            echo "[INFO] Node.js: \$(node -v)  npm: \$(npm -v)"
            MAJOR=\$(node -v | sed 's/v//' | cut -d. -f1)
            [ "\$MAJOR" -ge 22 ] || { echo "[ERROR] Need Node >= 22"; exit 1; }
            echo "[SUCCESS] Node.js \$(node -v) meets requirement"
NODEJS_EOF
        log_success "Node.js v${NODE_VERSION} installed"
    fi

    # ---- Step 6: OpenClaw ----
    log_step "Installing OpenClaw (method: ${INSTALL_METHOD})"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] Install OpenClaw via ${INSTALL_METHOD}"
    else
        case "$INSTALL_METHOD" in
            npm)
                ssh_cmd /bin/bash << 'NPM_EOF'
                    export NVM_DIR="$HOME/.nvm"
                    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
                    export NODE_OPTIONS="--max-old-space-size=4096"
                    SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install -g openclaw@latest 2>&1 | tail -20
                    if ! command -v openclaw >/dev/null 2>&1; then
                        NPM_BIN="$(npm prefix -g)/bin"
                        export PATH="$NPM_BIN:$PATH"
                        if command -v openclaw >/dev/null 2>&1; then
                            echo "export PATH=\"$NPM_BIN:\$PATH\"" >> ~/.bashrc
                        else
                            echo "[ERROR] openclaw not found"; exit 1
                        fi
                    fi
                    echo "[SUCCESS] OpenClaw: $(openclaw --version 2>/dev/null || echo ok)"
NPM_EOF
                ;;
            oneliner)
                ssh_cmd /bin/bash << 'ONELINER_EOF'
                    export NVM_DIR="$HOME/.nvm"
                    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
                    curl -fsSL https://openclaw.ai/install.sh | bash 2>&1
                    source ~/.bashrc 2>/dev/null || true
                    echo "[SUCCESS] Installed via one-liner"
ONELINER_EOF
                ;;
            source)
                ssh_cmd /bin/bash << 'SOURCE_EOF'
                    export NVM_DIR="$HOME/.nvm"
                    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
                    command -v pnpm >/dev/null 2>&1 || npm install -g pnpm 2>&1 | tail -3
                    if [ -d "$HOME/openclaw" ]; then
                        cd "$HOME/openclaw" && git pull 2>&1 | tail -3
                    else
                        git clone https://github.com/openclaw/openclaw.git "$HOME/openclaw" 2>&1 | tail -5
                        cd "$HOME/openclaw"
                    fi
                    pnpm install 2>&1 | tail -5
                    pnpm ui:build 2>&1 | tail -5
                    pnpm build 2>&1 | tail -5
                    pnpm link --global 2>&1
                    command -v openclaw >/dev/null 2>&1 || { echo "[ERROR] source build failed"; exit 1; }
                    echo "[SUCCESS] Installed from source"
SOURCE_EOF
                ;;
        esac
        log_success "OpenClaw installed (method: ${INSTALL_METHOD})"
    fi

    # ---- Step 7: Docker ----
    if [ "$SKIP_DOCKER" = false ]; then
        log_step "Installing Docker (for sandboxing)"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY] Install Docker CE"
        else
            ssh_cmd /bin/bash << DOCKER_EOF
                if command -v docker >/dev/null 2>&1; then
                    echo "[INFO] Docker already installed: \$(docker --version)"
                    exit 0
                fi
                sudo install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>&1
                echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update -y 2>&1 | tail -3
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | tail -5
                sudo systemctl start docker 2>/dev/null || true
                sudo systemctl enable docker 2>/dev/null || true
                sudo usermod -aG docker ${VM_USERNAME} 2>/dev/null || true
                echo "[SUCCESS] Docker: \$(docker --version)"
DOCKER_EOF
            log_success "Docker installed"
        fi
    fi

    # ---- Step 8: systemd ----
    log_step "Setting up OpenClaw systemd service"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] Create ~/.config/systemd/user/openclaw.service"
    else
        ssh_cmd /bin/bash << 'SYSTEMD_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            OC_BIN=$(command -v openclaw 2>/dev/null || echo "")
            if [ -z "$OC_BIN" ]; then
                NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
                export PATH="$NPM_BIN:$PATH"
                OC_BIN=$(command -v openclaw 2>/dev/null || echo "")
            fi
            [ -z "$OC_BIN" ] && { echo "[WARN] openclaw binary not found — skipping systemd"; exit 0; }
            NODE_BIN=$(which node); NVM_BIN_DIR=$(dirname "$NODE_BIN")
            mkdir -p ~/.config/systemd/user
            cat > ~/.config/systemd/user/openclaw.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (ClawdBot)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="PATH=${NVM_BIN_DIR}:/usr/local/bin:/usr/bin:/bin"
Environment="NVM_DIR=%h/.nvm"
Environment="NODE_OPTIONS=--max-old-space-size=4096"
ExecStart=${OC_BIN} gateway --port 18789
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

[Install]
WantedBy=default.target
SVCEOF
            systemctl --user daemon-reload
            systemctl --user enable openclaw 2>&1 || true
            command -v loginctl >/dev/null 2>&1 && sudo loginctl enable-linger $(whoami) 2>/dev/null || true
            echo "[SUCCESS] Systemd service configured"
SYSTEMD_EOF
        log_success "Systemd service configured"
    fi

    # ---- Step 9: workspace ----
    log_step "Creating initial OpenClaw workspace"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] mkdir ~/.openclaw/workspace + skeleton openclaw.json"
    else
        ssh_cmd /bin/bash << 'WORKSPACE_EOF'
            mkdir -p ~/.openclaw/workspace/skills ~/.openclaw/credentials ~/.openclaw/agents ~/.openclaw/logs
            if [ ! -f ~/.openclaw/openclaw.json ]; then
                cat > ~/.openclaw/openclaw.json << 'CONFIGEOF'
{
  "agent": { "model": "anthropic/claude-opus-4-6" },
  "channels": {
    "telegram": {
      "enabled": false,
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "dmPolicy": "pairing",
      "groups": { "*": { "requireMention": true } }
    }
  },
  "gateway": { "port": 18789 }
}
CONFIGEOF
                chmod 600 ~/.openclaw/openclaw.json
            fi
            [ -f ~/.openclaw/workspace/AGENTS.md ] || echo -e "# Agent Instructions\n\nYou are a helpful AI assistant." > ~/.openclaw/workspace/AGENTS.md
            echo "[SUCCESS] Workspace ready at ~/.openclaw/"
WORKSPACE_EOF
        log_success "Workspace created"
    fi

    # ---- Step 10: verify ----
    log_step "Verifying installation"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] openclaw --version && openclaw doctor"
    else
        ssh_cmd /bin/bash << 'VERIFY_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
            export PATH="$NPM_BIN:$PATH"
            echo "============================================"
            echo "  INSTALLATION VERIFICATION"
            echo "============================================"
            command -v node     >/dev/null 2>&1 && echo "Node.js:  $(node -v)"      || echo "[FAIL] Node.js missing"
            command -v openclaw >/dev/null 2>&1 && echo "OpenClaw: $(openclaw --version 2>/dev/null)" || echo "[FAIL] openclaw missing"
            command -v docker   >/dev/null 2>&1 && echo "Docker:   $(docker --version)" || echo "Docker:   not installed"
            [ -f ~/.config/systemd/user/openclaw.service ] && echo "Service:  present" || echo "Service:  missing"
            [ -f ~/.openclaw/openclaw.json ] && echo "Config:   present ($(stat -c %a ~/.openclaw/openclaw.json))" || echo "Config:   missing"
            command -v openclaw >/dev/null 2>&1 && openclaw doctor 2>&1 | head -30 || true
VERIFY_EOF
        log_success "Installation verified"
    fi

    # ---- Step 11: Ensure Nginx Proxy Is Enabled ----
    log_step "Enabling Nginx reverse proxy for OpenClaw (if available)"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY] Would enable valtunox-openclaw nginx config"
    else
        ssh_cmd /bin/bash << 'NGINX_EOF'
            NGINX_OC_CONF="/etc/nginx/sites-available/valtunox-openclaw"
            if [ -f "$NGINX_OC_CONF" ] && command -v nginx >/dev/null 2>&1; then
                sudo ln -sf "$NGINX_OC_CONF" /etc/nginx/sites-enabled/ 2>/dev/null || true
                # Also enable IDE if config exists
                if [ -f "/etc/nginx/sites-available/valtunox-ide" ]; then
                    sudo ln -sf /etc/nginx/sites-available/valtunox-ide /etc/nginx/sites-enabled/ 2>/dev/null || true
                fi
                if sudo nginx -t 2>/dev/null; then
                    sudo systemctl reload nginx 2>/dev/null || true
                    echo "[SUCCESS] Nginx reloaded — OpenClaw proxy enabled on port 18790"
                else
                    echo "[WARN] Nginx config test failed — OpenClaw proxy not enabled (check SSL cert)"
                fi
            else
                echo "[INFO] No Nginx OpenClaw config found — skipping (run tenant_setup.sh first for HTTPS)"
            fi
NGINX_EOF
        log_success "Nginx proxy check complete"
    fi

    # Summary
    local ELAPSED; ELAPSED=$(elapsed_time)
    log ""
    log "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${BOLD}${CYAN}║           Installation Complete                             ║${NC}"
    log "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "  Target:    ${VM_USERNAME}@${VM_HOSTNAME}"
    log "  Method:    ${INSTALL_METHOD}"
    log "  Duration:  ${ELAPSED}"
    log "  Log:       ${LOG_FILE}"
    log ""
    log "${BOLD}NEXT STEPS:${NC}"
    log "  1. Configure tokens:"
    log "     $0 --configure --hostname ${VM_HOSTNAME} --username ${VM_USERNAME} --private-key ${VM_PRIVATE_KEY} \\"
    log "        --telegram-token ... --anthropic-key ... --start-gateway"
    log "  2. Check health:"
    log "     ./openclaw_vm_health.sh --hostname ${VM_HOSTNAME} --username ${VM_USERNAME} --private-key ${VM_PRIVATE_KEY}"
    log ""
}


# ==============================================================================
# MODE: UPDATE
# ==============================================================================
run_update() {
    local UPDATE_ACTION="${ACTION:-update}"
    log ""
    log "${BOLD}${CYAN}--- OpenClaw Update / Maintenance ---${NC}"
    log "  Target:  ${VM_USERNAME}@${VM_HOSTNAME}"
    log "  Action:  ${UPDATE_ACTION}"
    log "  Channel: ${UPDATE_CHANNEL}"
    log ""

    validate_common_inputs

    if [ "$LOCAL_MODE" = false ]; then
        local UPD_SSH_TEST=""
        UPD_SSH_TEST=$(ssh_cmd "echo OK" 2>&1) || true
        if ! echo "$UPD_SSH_TEST" | grep -q "OK"; then
            log_error "SSH connection failed to ${VM_USERNAME}@${VM_HOSTNAME}"
            log_error "Output: ${UPD_SSH_TEST}"
            exit 1
        fi
    fi

    case "$UPDATE_ACTION" in

    update)
        log_header "Updating OpenClaw (channel: ${UPDATE_CHANNEL})"
        ssh_cmd /bin/bash << UPDATE_EOF
            export NVM_DIR="\$HOME/.nvm"
            [ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
            NPM_BIN="\$(npm prefix -g 2>/dev/null)/bin" 2>/dev/null
            export PATH="\$NPM_BIN:\$PATH" 2>/dev/null
            OLD_VER=\$(openclaw --version 2>/dev/null || echo unknown)
            systemctl --user stop openclaw 2>/dev/null || true
            sleep 2
            if [ "${UPDATE_CHANNEL}" = "stable" ]; then
                npm update -g openclaw 2>&1 | tail -10
            else
                if command -v openclaw >/dev/null 2>&1; then
                    openclaw update --channel ${UPDATE_CHANNEL} 2>&1 | tail -10
                else
                    npm install -g openclaw@${UPDATE_CHANNEL} 2>&1 | tail -10
                fi
            fi
            NEW_VER=\$(openclaw --version 2>/dev/null || echo unknown)
            echo "[INFO] \$OLD_VER -> \$NEW_VER"
            openclaw doctor 2>&1 | head -20 || true
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user start openclaw 2>/dev/null || true
            sleep 3
            STATUS=\$(systemctl --user is-active openclaw 2>/dev/null || echo unknown)
            echo "[INFO] Service status: \$STATUS"
UPDATE_EOF
        log_success "Update complete"
        ;;

    backup)
        log_header "Backing Up OpenClaw Data"
        local TS REMOTE LOCAL
        TS=$(date +%Y%m%d_%H%M%S)
        REMOTE="/tmp/openclaw_backup_${TS}.tar.gz"
        LOCAL="${BACKUP_DIR}/openclaw_backup_${VM_HOSTNAME}_${TS}.tar.gz"
        mkdir -p "$BACKUP_DIR"
        ssh_cmd /bin/bash << BACKUP_EOF
            tar czf ${REMOTE} \
                --exclude='*.sqlite' --exclude='*/node_modules/*' --exclude='*/sandbox-images/*' \
                -C \$HOME .openclaw/openclaw.json .openclaw/workspace/ .openclaw/credentials/ \
                .config/systemd/user/openclaw.service 2>/dev/null || true
            echo "[INFO] Backup size: \$(stat -c %s ${REMOTE} 2>/dev/null) bytes"
BACKUP_EOF
        copy_down "${REMOTE}" "$LOCAL"
        ssh_cmd "rm -f ${REMOTE}"
        log_success "Backup saved: ${LOCAL}"
        ;;

    restore)
        log_header "Restoring OpenClaw Data"
        [ -d "$BACKUP_DIR" ] || { log_error "Backup dir not found: $BACKUP_DIR"; exit 1; }
        local LATEST; LATEST=$(ls -t "$BACKUP_DIR"/openclaw_backup_*.tar.gz 2>/dev/null | head -1)
        [ -z "$LATEST" ] && { log_error "No backup files in $BACKUP_DIR"; exit 1; }
        log_info "Restoring from: $LATEST"
        confirm_dangerous "restore OpenClaw data (overwrite current config & workspace)"
        local REMOTE_RESTORE="/tmp/openclaw_restore_$$.tar.gz"
        copy_up "$LATEST" "${REMOTE_RESTORE}"
        ssh_cmd /bin/bash << RESTORE_EOF
            systemctl --user stop openclaw 2>/dev/null || true
            sleep 2
            cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.pre-restore.\$(date +%s) 2>/dev/null || true
            cd \$HOME && tar xzf ${REMOTE_RESTORE} 2>&1
            chmod 600 ~/.openclaw/openclaw.json 2>/dev/null || true
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user start openclaw 2>/dev/null || true
            rm -f ${REMOTE_RESTORE}
            echo "[SUCCESS] Restore complete"
RESTORE_EOF
        log_success "Restore complete"
        ;;

    rotate)
        log_header "Rotating Log Files"
        ssh_cmd /bin/bash << 'ROTATE_EOF'
            find /tmp/openclaw/ -name "openclaw-*.log" -mtime +7 -delete 2>/dev/null || true
            if command -v journalctl >/dev/null 2>&1; then
                journalctl --user --vacuum-time=7d 2>/dev/null || true
            fi
            df -h / | tail -1
            echo "[SUCCESS] Rotation complete"
ROTATE_EOF
        log_success "Log rotation complete"
        ;;

    reset)
        log_header "Factory Reset OpenClaw"
        confirm_dangerous "FACTORY RESET OpenClaw (delete all config, sessions, workspace)"
        ssh_cmd /bin/bash << 'RESET_EOF'
            systemctl --user stop openclaw 2>/dev/null || true
            systemctl --user disable openclaw 2>/dev/null || true
            rm -rf ~/.openclaw
            rm -f ~/.config/systemd/user/openclaw.service
            systemctl --user daemon-reload 2>/dev/null || true
            echo "[SUCCESS] Factory reset complete"
RESET_EOF
        log_success "Factory reset complete"
        ;;

    uninstall)
        log_header "Uninstalling OpenClaw"
        confirm_dangerous "COMPLETELY REMOVE OpenClaw (binary, data, service, NVM, Node)"
        ssh_cmd /bin/bash << 'UNINSTALL_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            systemctl --user stop openclaw 2>/dev/null || true
            systemctl --user disable openclaw 2>/dev/null || true
            pkill -f openclaw 2>/dev/null || true
            npm uninstall -g openclaw 2>/dev/null || true
            rm -rf ~/.openclaw ~/.nvm ~/.npm ~/.node
            rm -f ~/.config/systemd/user/openclaw.service
            systemctl --user daemon-reload 2>/dev/null || true
            sed -i '/NVM_DIR/d; /nvm.sh/d; /OPENCLAW/d; /ANTHROPIC_API_KEY/d; /OPENAI_API_KEY/d; /TELEGRAM_BOT_TOKEN/d' ~/.bashrc 2>/dev/null || true
            echo "[SUCCESS] OpenClaw uninstalled"
UNINSTALL_EOF
        log_success "OpenClaw uninstalled"
        ;;

    node)
        log_header "Updating Node.js"
        ssh_cmd /bin/bash << 'NODE_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            OLD=$(node -v 2>/dev/null || echo none)
            nvm install 24 2>&1 | tail -5
            nvm alias default 24
            nvm use 24
            nvm reinstall-packages "$OLD" 2>&1 | tail -5 || true
            echo "[SUCCESS] Node.js: $OLD -> $(node -v)"
NODE_EOF
        log_success "Node.js updated"
        ;;

    security)
        log_header "Security Audit"
        ssh_cmd /bin/bash << 'SEC_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin" 2>/dev/null
            export PATH="$NPM_BIN:$PATH" 2>/dev/null
            echo "=== Config permissions ==="
            if [ -f ~/.openclaw/openclaw.json ]; then
                P=$(stat -c %a ~/.openclaw/openclaw.json)
                [ "$P" = "600" ] && echo "  [PASS] $P" || echo "  [WARN] $P (should be 600)"
                grep -q '"open"' ~/.openclaw/openclaw.json 2>/dev/null && echo "  [WARN] DM policy = 'open'" || echo "  [PASS] DM policy secure"
            fi
            echo "=== Credential files ==="
            find ~/.openclaw/ -name "*.json" -o -name "*.key" -o -name "*.pem" 2>/dev/null | while read f; do
                P=$(stat -c %a "$f" 2>/dev/null || echo ?)
                [[ "$P" =~ ^(600|400)$ ]] && echo "  [PASS] $f ($P)" || echo "  [WARN] $f ($P)"
            done
            echo "=== Bash history ==="
            if [ -f ~/.bash_history ]; then
                L=$(grep -cE "(sk-ant-|sk-|xoxb-|xapp-)" ~/.bash_history 2>/dev/null || echo 0)
                [ "$L" -gt 0 ] && echo "  [WARN] $L potential API keys in history" || echo "  [PASS] No API keys in history"
            fi
            command -v openclaw >/dev/null 2>&1 && openclaw security audit 2>&1 || true
            command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null || echo "  [INFO] UFW not installed"
SEC_EOF
        log_success "Security audit complete"
        ;;

    *)
        log_error "Unknown --action: $UPDATE_ACTION"
        log_info "Valid: update, backup, restore, rotate, reset, uninstall, node, security"
        exit 1
        ;;
    esac
}


# ==============================================================================
# MODE: HEALTH
# ==============================================================================
run_health() {
    local HEALTH_ACTION="${ACTION:-status}"
    log ""
    log "${BOLD}${CYAN}--- OpenClaw Health / Control ---${NC}"
    log "  Target:  ${VM_USERNAME}@${VM_HOSTNAME}"
    log "  Action:  ${HEALTH_ACTION}"
    log ""

    validate_common_inputs

    if [ "$LOCAL_MODE" = false ]; then
        local HLT_SSH_TEST=""
        HLT_SSH_TEST=$(ssh_cmd "echo OK" 2>&1) || true
        if ! echo "$HLT_SSH_TEST" | grep -q "OK"; then
            log_error "SSH connection failed to ${VM_USERNAME}@${VM_HOSTNAME}"
            log_error "Output: ${HLT_SSH_TEST}"
            exit 1
        fi
    fi

    case "$HEALTH_ACTION" in

    status)
        log ""
        log "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        log "${BOLD}${CYAN}║           OpenClaw Health Report                            ║${NC}"
        log "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        log ""
        log "  Host: ${BOLD}${VM_USERNAME}@${VM_HOSTNAME}${NC}"
        log "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
        ssh_cmd /bin/bash << 'STATUS_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin" 2>/dev/null
            export PATH="$NPM_BIN:$PATH" 2>/dev/null

            echo ""; echo "--- Service Status ---"
            if command -v systemctl >/dev/null 2>&1; then
                SVC_ACTIVE=$(systemctl --user is-active openclaw 2>/dev/null || echo inactive)
                SVC_ENABLED=$(systemctl --user is-enabled openclaw 2>/dev/null || echo disabled)
                echo "  Systemd:    active=$SVC_ACTIVE, enabled=$SVC_ENABLED"
                if [ "$SVC_ACTIVE" = "active" ]; then
                    echo "  Started:    $(systemctl --user show openclaw --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)"
                    echo "  PID:        $(systemctl --user show openclaw --property=MainPID 2>/dev/null | cut -d= -f2)"
                fi
            else
                echo "  Systemd:    not available"
            fi
            echo "  Processes:  $(pgrep -f openclaw 2>/dev/null | wc -l) openclaw process(es) running"

            echo ""; echo "--- OpenClaw Version ---"
            if command -v openclaw >/dev/null 2>&1; then
                echo "  Version:    $(openclaw --version 2>/dev/null || echo unknown)"
                echo "  Path:       $(which openclaw)"
            else
                echo "  [NOT FOUND] openclaw command not in PATH"
            fi

            echo ""; echo "--- Node.js ---"
            if command -v node >/dev/null 2>&1; then
                echo "  Node:       $(node -v)"
                echo "  npm:        $(npm -v 2>/dev/null || echo unknown)"
            else
                echo "  [NOT FOUND] Node.js not in PATH"
            fi

            echo ""; echo "--- Configuration ---"
            if [ -f ~/.openclaw/openclaw.json ]; then
                echo "  Config:     ~/.openclaw/openclaw.json ($(stat -c %s ~/.openclaw/openclaw.json) bytes, perms: $(stat -c %a ~/.openclaw/openclaw.json))"
                echo "  Channels:"
                grep -o '"[a-z]*".*"enabled".*true' ~/.openclaw/openclaw.json 2>/dev/null | head -5 | while read line; do
                    echo "    - $line"
                done || echo "    (unable to parse)"
            else
                echo "  [MISSING] ~/.openclaw/openclaw.json not found"
            fi

            echo ""; echo "--- Workspace ---"
            if [ -d ~/.openclaw/workspace ]; then
                SKILL_COUNT=$(find ~/.openclaw/workspace/skills -name "SKILL.md" 2>/dev/null | wc -l)
                echo "  Workspace:  ~/.openclaw/workspace/ (exists)"
                echo "  Skills:     $SKILL_COUNT installed"
            else
                echo "  [MISSING] ~/.openclaw/workspace/ not found"
            fi

            echo ""; echo "--- Docker ---"
            if command -v docker >/dev/null 2>&1; then
                echo "  Docker:     $(docker --version 2>/dev/null || echo unknown)"
                CONTAINERS=$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -c openclaw || echo 0)
                echo "  Containers: $CONTAINERS openclaw container(s)"
            else
                echo "  Docker:     not installed"
            fi

            echo ""; echo "--- Resources ---"
            echo "  CPU:        $(nproc) cores, load: $(cat /proc/loadavg | cut -d' ' -f1-3)"
            TOTAL_RAM=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
            AVAIL_RAM=$(($(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024))
            echo "  RAM:        ${AVAIL_RAM}/${TOTAL_RAM} MB available"
            echo "  Disk:       $(df -h / --output=avail | tail -1 | tr -d ' ')/$(df -h / --output=size | tail -1 | tr -d ' ') available"
            echo "  Uptime:     $(uptime -p 2>/dev/null || uptime)"

            echo ""; echo "--- Port Check (18789) ---"
            if ss -tlnp 2>/dev/null | grep -q ':18789 '; then
                echo "  Port 18789: LISTENING"
                ss -tlnp 2>/dev/null | grep ':18789 ' | head -1
            else
                echo "  Port 18789: not listening"
            fi

            echo ""; echo "--- Recent Errors (last 10 from journal) ---"
            journalctl --user -u openclaw --no-pager -p err -n 10 2>/dev/null || echo "  No error logs found"
STATUS_EOF
        ;;

    start)
        log_header "Starting OpenClaw Gateway"
        ssh_cmd /bin/bash << 'START_EOF'
            systemctl --user start openclaw 2>&1
            sleep 3
            STATUS=$(systemctl --user is-active openclaw 2>/dev/null || echo unknown)
            [ "$STATUS" = "active" ] && echo "[SUCCESS] OpenClaw gateway started" || {
                echo "[WARN] Service status: $STATUS"
                echo "[INFO] Check logs: journalctl --user -u openclaw -n 20"
            }
START_EOF
        ;;

    stop)
        log_header "Stopping OpenClaw Gateway"
        ssh_cmd /bin/bash << 'STOP_EOF'
            systemctl --user stop openclaw 2>&1
            sleep 2
            echo "[INFO] Service status: $(systemctl --user is-active openclaw 2>/dev/null || echo unknown)"
            pkill -f "openclaw gateway" 2>/dev/null || true
            echo "[SUCCESS] OpenClaw gateway stopped"
STOP_EOF
        ;;

    restart)
        log_header "Restarting OpenClaw Gateway"
        ssh_cmd /bin/bash << 'RESTART_EOF'
            systemctl --user restart openclaw 2>&1
            sleep 5
            STATUS=$(systemctl --user is-active openclaw 2>/dev/null || echo unknown)
            if [ "$STATUS" = "active" ]; then
                echo "[SUCCESS] OpenClaw gateway restarted"
            else
                echo "[WARN] Service status: $STATUS"
                journalctl --user -u openclaw --no-pager -n 10 2>/dev/null
            fi
RESTART_EOF
        ;;

    logs)
        log_header "OpenClaw Gateway Logs (last ${LOG_LINES} lines)"
        ssh_cmd /bin/bash << LOGS_EOF
            echo "=== systemd journal ==="
            journalctl --user -u openclaw --no-pager -n ${LOG_LINES} 2>/dev/null || echo "(no journal entries)"
            echo ""
            echo "=== openclaw log files ==="
            LOGFILE=\$(ls -t /tmp/openclaw/openclaw-*.log 2>/dev/null | head -1)
            if [ -n "\$LOGFILE" ]; then
                echo "File: \$LOGFILE"
                tail -${LOG_LINES} "\$LOGFILE"
            else
                echo "(no log files in /tmp/openclaw/)"
            fi
LOGS_EOF
        ;;

    doctor)
        log_header "Running OpenClaw Doctor"
        ssh_cmd /bin/bash << 'DOCTOR_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin" 2>/dev/null
            export PATH="$NPM_BIN:$PATH" 2>/dev/null
            if command -v openclaw >/dev/null 2>&1; then
                openclaw doctor 2>&1
            else
                echo "[ERROR] openclaw command not found"
                echo "[INFO] Is OpenClaw installed? Run: ./openclaw_vm_installer.sh"
            fi
DOCTOR_EOF
        ;;

    pairings)
        log_header "Pending Channel Pairings"
        ssh_cmd /bin/bash << 'PAIR_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin" 2>/dev/null
            export PATH="$NPM_BIN:$PATH" 2>/dev/null
            if command -v openclaw >/dev/null 2>&1; then
                for CH in telegram discord slack whatsapp; do
                    echo "--- $CH ---"
                    openclaw pairing list "$CH" 2>&1 || echo "(none or error)"
                    echo ""
                done
            else
                echo "[ERROR] openclaw command not found"
            fi
PAIR_EOF
        ;;

    resources)
        log_header "VM Resource Usage"
        ssh_cmd /bin/bash << 'RES_EOF'
            echo "=== CPU ==="
            echo "  Cores:     $(nproc)"
            echo "  Load:      $(cat /proc/loadavg)"
            echo ""
            echo "=== Memory ==="
            free -h
            echo ""
            echo "=== Disk ==="
            df -h / /tmp /home 2>/dev/null
            echo ""
            echo "=== Top Processes (by memory) ==="
            ps aux --sort=-%mem | head -10
RES_EOF
        ;;

    processes)
        log_header "OpenClaw Processes"
        ssh_cmd /bin/bash << 'PROC_EOF'
            echo "=== OpenClaw processes ==="
            ps aux | grep -E "(openclaw|node.*openclaw)" | grep -v grep || echo "(none running)"
            echo ""
            echo "=== Listening on port 18789 ==="
            ss -tlnp | grep ':18789 ' || echo "(port 18789 not listening)"
            echo ""
            echo "=== Systemd service ==="
            systemctl --user status openclaw 2>&1 || echo "(service not found)"
PROC_EOF
        ;;

    config)
        log_header "OpenClaw Configuration (secrets masked)"
        ssh_cmd /bin/bash << 'CFG_EOF'
            if [ -f ~/.openclaw/openclaw.json ]; then
                echo "File: ~/.openclaw/openclaw.json"
                echo "Permissions: $(stat -c '%a' ~/.openclaw/openclaw.json)"
                echo "Size: $(stat -c '%s' ~/.openclaw/openclaw.json) bytes"
                echo ""
                sed -E 's/("(botToken|token|apiKey|appToken|api_key)"\s*:\s*)"[^"]+"/\1"***MASKED***"/g' \
                    ~/.openclaw/openclaw.json
            else
                echo "[ERROR] ~/.openclaw/openclaw.json not found"
            fi
CFG_EOF
        ;;

    *)
        log_error "Unknown --action: $HEALTH_ACTION"
        log_info "Valid: status, start, stop, restart, logs, doctor, pairings, resources, processes, config"
        exit 1
        ;;
    esac
}


# ==============================================================================
# MODE: CONFIGURE
# ==============================================================================
run_configure() {
    log ""
    log "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${BOLD}${CYAN}║           OpenClaw VM Configuration                         ║${NC}"
    log "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "  Target:         ${BOLD}${VM_USERNAME}@${VM_HOSTNAME}${NC}"
    log "  Model:          ${MODEL}"
    log "  DM Policy:      ${DM_POLICY}"
    log "  Gateway Port:   ${GATEWAY_PORT}"
    log "  Telegram:       $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo provided || echo 'not set')"
    log "  Anthropic Key:  $([ -n "$ANTHROPIC_API_KEY" ] && echo provided || echo 'not set')"
    log "  OpenAI Key:     $([ -n "$OPENAI_API_KEY" ] && echo provided || echo 'not set')"
    log "  Discord:        $([ -n "$DISCORD_BOT_TOKEN" ] && echo provided || echo 'not set')"
    log "  Slack:          $([ -n "$SLACK_BOT_TOKEN" ] && echo provided || echo 'not set')"
    log "  Start Gateway:  ${START_GATEWAY}"
    log ""

    validate_common_inputs

    if [ "$LOCAL_MODE" = true ]; then
        log_success "Local mode — no SSH needed"
    else
        log_info "Testing SSH connection..."
        local CFG_SSH_TEST=""
        CFG_SSH_TEST=$(ssh_cmd "echo OK" 2>&1) || true
        if echo "$CFG_SSH_TEST" | grep -q "OK"; then
            log_success "SSH connection OK"
        else
            log_error "SSH connection failed"
            log_error "Output: ${CFG_SSH_TEST}"
            exit 1
        fi
    fi

    # Build openclaw.json dynamically
    log_info "Building OpenClaw configuration..."
    local CONFIG_JSON='{'
    CONFIG_JSON+="
  \"agent\": { \"model\": \"${MODEL}\" },"
    CONFIG_JSON+='
  "channels": {'
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        CONFIG_JSON+="
    \"telegram\": {
      \"enabled\": true,
      \"botToken\": \"${TELEGRAM_BOT_TOKEN}\",
      \"dmPolicy\": \"${DM_POLICY}\",
      \"groups\": { \"*\": { \"requireMention\": true } }
    }"
    else
        CONFIG_JSON+='
    "telegram": {
      "enabled": false,
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "dmPolicy": "pairing"
    }'
    fi
    if [ -n "$DISCORD_BOT_TOKEN" ]; then
        CONFIG_JSON+=",
    \"discord\": { \"enabled\": true, \"token\": \"${DISCORD_BOT_TOKEN}\" }"
    fi
    if [ -n "$SLACK_BOT_TOKEN" ]; then
        CONFIG_JSON+=",
    \"slack\": { \"enabled\": true, \"botToken\": \"${SLACK_BOT_TOKEN}\", \"appToken\": \"${SLACK_APP_TOKEN}\" }"
    fi
    CONFIG_JSON+='
  },'
    CONFIG_JSON+="
  \"gateway\": { \"port\": ${GATEWAY_PORT} }
}"

    local TEMP_CONFIG="/tmp/openclaw_config_$$.json"
    echo "$CONFIG_JSON" > "$TEMP_CONFIG"

    ssh_cmd /bin/bash << 'BACKUP_EOF'
        if [ -f ~/.openclaw/openclaw.json ]; then
            cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.backup.$(date +%Y%m%d_%H%M%S)
        fi
        mkdir -p ~/.openclaw
BACKUP_EOF

    copy_up "$TEMP_CONFIG" "~/.openclaw/openclaw.json"
    rm -f "$TEMP_CONFIG"

    ssh_cmd /bin/bash << ENVEOF
        chmod 600 ~/.openclaw/openclaw.json
        echo "[SUCCESS] Configuration uploaded (chmod 600)"

        if [ -n "${ANTHROPIC_API_KEY}" ]; then
            sed -i '/^export ANTHROPIC_API_KEY=/d' ~/.bashrc 2>/dev/null || true
            echo 'export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"' >> ~/.bashrc
        fi
        if [ -n "${OPENAI_API_KEY}" ]; then
            sed -i '/^export OPENAI_API_KEY=/d' ~/.bashrc 2>/dev/null || true
            echo 'export OPENAI_API_KEY="${OPENAI_API_KEY}"' >> ~/.bashrc
        fi
        if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
            sed -i '/^export TELEGRAM_BOT_TOKEN=/d' ~/.bashrc 2>/dev/null || true
            echo 'export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"' >> ~/.bashrc
        fi

        if [ -f ~/.config/systemd/user/openclaw.service ]; then
            ENVLINE=""
            [ -n "${ANTHROPIC_API_KEY}"  ] && ENVLINE+="Environment=\"ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}\"\n"
            [ -n "${OPENAI_API_KEY}"     ] && ENVLINE+="Environment=\"OPENAI_API_KEY=${OPENAI_API_KEY}\"\n"
            [ -n "${TELEGRAM_BOT_TOKEN}" ] && ENVLINE+="Environment=\"TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}\"\n"
            if [ -n "\$ENVLINE" ]; then
                sed -i "/^\[Service\]/a \$(echo -e "\$ENVLINE")" ~/.config/systemd/user/openclaw.service 2>/dev/null || true
                systemctl --user daemon-reload 2>/dev/null || true
            fi
        fi
        echo "[SUCCESS] Configuration complete"
ENVEOF

    log_success "Configuration uploaded and applied"

    if [ "$START_GATEWAY" = true ]; then
        log_info "Starting OpenClaw gateway..."
        ssh_cmd /bin/bash << 'START_EOF'
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
            NPM_BIN="$(npm prefix -g 2>/dev/null)/bin"
            export PATH="$NPM_BIN:$PATH"
            systemctl --user stop openclaw 2>/dev/null || true
            sleep 2
            systemctl --user start openclaw 2>/dev/null
            sleep 5
            STATUS=$(systemctl --user is-active openclaw 2>/dev/null || echo unknown)
            echo "[INFO] Gateway status: $STATUS"
            command -v openclaw >/dev/null 2>&1 && openclaw status 2>/dev/null || true
START_EOF
        log_success "Gateway started"
    fi

    log ""
    log "${BOLD}${CYAN}--- Configuration Complete ---${NC}"
    log "  Config:        ~/.openclaw/openclaw.json"
    log "  Model:         ${MODEL}"
    log "  DM Policy:     ${DM_POLICY}"
    log "  Gateway Port:  ${GATEWAY_PORT}"
    log ""
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        log "${BOLD}TELEGRAM PAIRING:${NC}"
        log "  1. Send a message to your bot on Telegram"
        log "  2. The bot replies with a pairing code"
        log "  3. Approve: ssh -i ${VM_PRIVATE_KEY} ${VM_USERNAME}@${VM_HOSTNAME} \\"
        log "              openclaw pairing approve telegram <CODE>"
    fi
}


# ==============================================================================
# DISPATCH
# ==============================================================================
case "$MODE" in
    install)   run_install   ;;
    preflight) run_preflight ;;
    update)    run_update    ;;
    configure) run_configure ;;
    health)    run_health    ;;
    *)         log_error "Unknown mode: $MODE"; print_help; exit 1 ;;
esac

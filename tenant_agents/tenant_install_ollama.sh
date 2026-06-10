#!/bin/bash
set -euo pipefail

# =============================================================================
# Valtunox Ollama Installer — Standalone (SSL + Nginx + Firewall)
# =============================================================================
# What it does:
#   1. Installs Ollama and pulls lightweight models (llama3.2 + gemma4:e4b)
#   2. Installs Nginx (if missing)
#   3. Writes an Nginx reverse proxy: https://$DOMAIN:$OLLAMA_PORT -> 127.0.0.1:11434
#   4. Obtains / reuses Let's Encrypt SSL certificate for $DOMAIN
#   5. Opens UFW port $OLLAMA_PORT
#   6. Verifies the HTTPS endpoint
#
# Prerequisites:
#   - Ubuntu 20.04 / 22.04 / 24.04 (root / sudo)
#   - DNS A record for $DOMAIN pointing to this VM's IP BEFORE running
#   - Ports 80, 443, and $OLLAMA_PORT (default 11435) open in security group
#
# Usage (copy-paste on the target VM):
#   sudo ./tenant_install_ollama.sh                      # Full install
#   sudo ./tenant_install_ollama.sh --test               # Skip install, chat test
#   sudo ./tenant_install_ollama.sh --test --model llama3.2
#
# Optional overrides:
#   sudo DOMAIN="t.example.com" \
#        EMAIL="admin@example.com" \
#        IP="1.2.3.4" \
#        OLLAMA_PORT="11435" \
#        ./tenant_install_ollama.sh
#
# CLI flags:
#   --domain <host>       Domain name (default: ollama.valtunox.cloud)
#   --email <addr>        Let's Encrypt account email
#   --ip <addr>            VM public IP (optional — auto-detected if omitted)
#   --port <n>             Public HTTPS port (default: 11435)
#   --backend-port <n>     Ollama API port (default: 11434)
#   --test  / --chat       Skip install; smoke-test + interactive chat
#   --model <name>         Model for --test (default: llama3.3)
#
# Behaviour:
#   - If an SSL cert for $DOMAIN already exists (e.g. tenant_setup.sh has run),
#     it's reused — no new certbot run.
#   - If no cert exists, certbot is installed and requests one via HTTP-01 on
#     port 80. This requires port 80 open + DNS pointing here.
#   - IP is optional. If provided it's only used for the DNS-mismatch warning.
#   - --test requires Ollama to already be installed and running locally.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION (env vars override CLI flags below)
# ---------------------------------------------------------------------------
DOMAIN="${DOMAIN:-ollama.valtunox.cloud}"
EMAIL="${EMAIL:-joelwembo.dev@gmail.com}"
IP="${IP:-}"
OLLAMA_PORT="${OLLAMA_PORT:-11435}"
OLLAMA_BACKEND_PORT="${OLLAMA_BACKEND_PORT:-11434}"
TEST_ONLY=false
TEST_MODEL="${TEST_MODEL:-llama3.3}"

# ---------------------------------------------------------------------------
# CLI flag parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)       DOMAIN="$2";              shift 2 ;;
        --email)        EMAIL="$2";               shift 2 ;;
        --ip)           IP="$2";                  shift 2 ;;
        --port)         OLLAMA_PORT="$2";         shift 2 ;;
        --backend-port) OLLAMA_BACKEND_PORT="$2"; shift 2 ;;
        --test|--chat)  TEST_ONLY=true;           shift   ;;
        --model)        TEST_MODEL="$2";          shift 2 ;;
        -h|--help)
            sed -n '3,38p' "$0"
            exit 0
            ;;
        *) echo "[ERROR] Unknown flag: $1"; exit 1 ;;
    esac
done

# Normalize + validate domain
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"
if [ -z "$DOMAIN" ]; then
    echo "[ERROR] DOMAIN is required. Pass --domain or set DOMAIN=..."
    exit 1
fi
if [[ "$DOMAIN" =~ [:/] ]] || [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "[ERROR] Invalid domain: '$DOMAIN' — must be a bare hostname"
    exit 1
fi

# Port validation
for p in "$OLLAMA_PORT" "$OLLAMA_BACKEND_PORT"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        echo "[ERROR] Invalid port: $p"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Colours & logging
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_apt() {
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log_info "Waiting for dpkg lock (unattended-upgrades)..."
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Chat / smoke test (--test / --chat)
# ---------------------------------------------------------------------------
run_chat_test() {
    local model="$1"

    log_info "============================================"
    log_info "  Ollama Chat Test — model: $model"
    log_info "============================================"

    if ! command -v ollama &> /dev/null; then
        log_error "Ollama is not installed. Run this script without --test first."
        exit 1
    fi

    # 1. Local API reachability
    log_info "Checking local API (http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/tags)..."
    if ! curl -sf --max-time 3 "http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/tags" > /dev/null 2>&1; then
        log_error "Ollama is not responding on 127.0.0.1:${OLLAMA_BACKEND_PORT}"
        log_error "Check: sudo systemctl status ollama"
        exit 1
    fi
    log_success "Local API OK"

    # 2. Public HTTPS reachability (best-effort)
    local cert_path="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    if [ -f "$cert_path" ]; then
        local https_code
        https_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN:$OLLAMA_PORT/api/tags" 2>/dev/null || echo "000")
        if [ "$https_code" = "200" ]; then
            log_success "Public HTTPS OK  (https://$DOMAIN:$OLLAMA_PORT -> HTTP $https_code)"
        else
            log_warn "Public HTTPS not reachable (HTTP $https_code) — local test will continue"
        fi
    else
        log_warn "No SSL cert for $DOMAIN — skipping HTTPS check"
    fi

    # 3. Ensure the test model is present
    if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$model"; then
        log_success "Model '$model' is already installed"
    else
        log_info "Model '$model' not found — pulling it now (this can take a while)..."
        if ! ollama pull "$model"; then
            log_error "Failed to pull '$model'. Try: ollama pull $model"
            exit 1
        fi
        log_success "Model '$model' pulled"
    fi

    # 4. One-shot smoke prompt (non-interactive)
    echo ""
    log_info "Smoke test — asking '$model' a quick question..."
    echo "----------------------------------------------------"
    local smoke_response
    smoke_response=$(curl -sf --max-time 120 \
        "http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/generate" \
        -d "{\"model\":\"$model\",\"prompt\":\"Reply with exactly: pong\",\"stream\":false}" \
        2>/dev/null | sed -n 's/.*"response":"\([^"]*\)".*/\1/p' | head -c 200)
    if [ -n "$smoke_response" ]; then
        echo "$smoke_response"
        echo "----------------------------------------------------"
        log_success "Smoke test OK"
    else
        echo "(no response parsed)"
        echo "----------------------------------------------------"
        log_warn "Smoke test returned no parsable response (model may still work interactively)"
    fi

    # 5. Interactive chat — drop the user into `ollama run`
    echo ""
    log_info "============================================"
    log_info "  Entering interactive chat with '$model'"
    log_info "  Type your message and press Enter."
    log_info "  Commands: /bye (exit), /?  (help), Ctrl+D to quit"
    log_info "============================================"
    echo ""
    exec ollama run "$model"
}

# If --test / --chat was passed, run the chat test and exit (don't install anything).
if [ "$TEST_ONLY" = true ]; then
    run_chat_test "$TEST_MODEL"
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_error "Must be run as root (use sudo)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log_info "============================================"
log_info "  Valtunox Ollama Installer"
log_info "  Domain        : $DOMAIN"
log_info "  Email         : $EMAIL"
log_info "  Public port   : $OLLAMA_PORT (HTTPS)"
log_info "  Backend port  : $OLLAMA_BACKEND_PORT (Ollama API)"
log_info "============================================"

# Detect VM public IP (fallback if user didn't pass --ip)
if [ -z "$IP" ]; then
    IP=$(curl -s --max-time 5 http://checkip.amazonaws.com || curl -s --max-time 5 http://ifconfig.me || echo "")
fi
if [ -n "$IP" ]; then
    log_info "This VM's public IP: $IP"
else
    log_warn "Could not determine VM's public IP (skipping DNS-vs-IP check)"
fi

# Install dig if needed for DNS check
if ! command -v dig &> /dev/null; then
    wait_for_apt
    apt-get update -qq
    apt-get install -y -qq dnsutils > /dev/null
fi

DNS_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || echo "")
if [ -n "$IP" ] && [ "$DNS_IP" = "$IP" ]; then
    log_success "DNS $DOMAIN -> $DNS_IP (matches this VM)"
elif [ -z "$DNS_IP" ]; then
    log_warn "Cannot resolve $DOMAIN yet. DNS may still be propagating."
    log_warn "Certbot will fail if DNS is not pointing here. Proceeding anyway..."
elif [ -n "$IP" ]; then
    log_warn "DNS $DOMAIN -> $DNS_IP but this VM is $IP"
    log_warn "SSL certificate request may fail. Proceeding anyway..."
else
    log_info "DNS $DOMAIN -> $DNS_IP (VM IP unknown — cannot cross-check)"
fi

# =============================================================================
# STEP 1: Install Ollama (official installer — supports all Linux distros)
# =============================================================================
log_info "Installing Ollama..."

if command -v ollama &> /dev/null; then
    log_success "Ollama already installed: $(ollama --version 2>/dev/null || echo 'present')"
else
    curl -fsSL https://ollama.com/install.sh | sh
    log_success "Ollama installed"
fi

# =============================================================================
# STEP 2: Start Ollama service
# =============================================================================
log_info "Starting Ollama service..."

if command -v systemctl &> /dev/null; then
    systemctl enable ollama 2>/dev/null || true
    systemctl start ollama 2>/dev/null || true
    sleep 3
    log_success "Ollama service started (systemd)"
else
    # Non-systemd fallback (Alpine, older distros, containers)
    if ! pgrep -f "ollama serve" &> /dev/null; then
        nohup ollama serve > /tmp/ollama.log 2>&1 &
        sleep 3
        log_success "Ollama started in background (non-systemd)"
    else
        log_success "Ollama already running"
    fi
fi

# Wait for Ollama API to respond
RETRIES=0
MAX_RETRIES=15
while [ $RETRIES -lt $MAX_RETRIES ]; do
    if curl -sf --max-time 2 "http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/tags" > /dev/null 2>&1; then
        log_success "Ollama API ready on port ${OLLAMA_BACKEND_PORT}"
        break
    fi
    RETRIES=$((RETRIES + 1))
    sleep 2
done

if [ $RETRIES -eq $MAX_RETRIES ]; then
    log_error "Ollama not responding on port ${OLLAMA_BACKEND_PORT} after 30s"
    log_error "Check: systemctl status ollama  or  ollama serve"
    exit 1
fi

# =============================================================================
# STEP 3: Pull models (small + fast only)
# =============================================================================
log_info "Pulling llama3.2 (small, fast)..."
ollama pull llama3.2 && log_success "llama3.2 pulled" || log_warn "llama3.2 pull failed (continuing)"

log_info "Pulling llama3.3 (for --test chat)..."
ollama pull llama3.3 && log_success "llama3.3 pulled" || log_warn "llama3.3 pull failed (continuing — it is large; can pull later with 'ollama pull llama3.3')"

log_info "Pulling gemma4:e4b (small, fast)..."
ollama pull gemma4:e4b && log_success "gemma4:e4b pulled" || log_warn "gemma4:e4b pull failed (continuing)"

# =============================================================================
# STEP 4: Install Nginx (if missing)
# =============================================================================
if ! command -v nginx &> /dev/null; then
    log_info "Installing Nginx..."
    wait_for_apt
    apt-get update -qq
    apt-get install -y -qq nginx > /dev/null
    systemctl enable nginx
    systemctl start nginx
    log_success "Nginx installed"
else
    log_success "Nginx already installed: $(nginx -v 2>&1 | awk '{print $3}')"
    systemctl is-active nginx >/dev/null 2>&1 || systemctl start nginx
fi

# =============================================================================
# STEP 5: Obtain / reuse SSL certificate
# =============================================================================
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

if [ -f "$CERT_PATH" ]; then
    log_success "SSL certificate already exists for $DOMAIN — reusing it"
else
    log_info "No SSL cert found for $DOMAIN — requesting a new one"

    # Ensure certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Installing Certbot..."
        wait_for_apt
        apt-get install -y -qq certbot python3-certbot-nginx > /dev/null
        log_success "Certbot installed"
    fi

    # Certbot needs an HTTP vhost on port 80 for $DOMAIN to serve the ACME
    # challenge. Write a minimal placeholder (it returns 404 for everything
    # except /.well-known/, which is fine for cert validation).
    ACME_CONF="/etc/nginx/sites-available/valtunox-ollama-acme"
    log_info "Writing temporary ACME challenge vhost for $DOMAIN..."
    cat > "$ACME_CONF" << ACME_EOF
# Temporary vhost for Let's Encrypt HTTP-01 challenge.
# Can be left in place — certbot reuses it for auto-renewal.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 404;
    }
}
ACME_EOF

    mkdir -p /var/www/html
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$ACME_CONF" /etc/nginx/sites-enabled/

    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        log_error "Nginx config test failed — cannot proceed with certbot"
        nginx -t
        exit 1
    fi

    # Pre-check: is port 80 actually reachable from the internet?
    PRE_SSL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$DOMAIN/" 2>/dev/null || echo "000")
    if [ "$PRE_SSL_CODE" = "000" ]; then
        log_error "Cannot reach http://$DOMAIN — certbot WILL fail"
        log_error "Fix: DNS A record, Security Group port 80, nginx running"
        log_error "Skipping SSL setup. Re-run after fixing connectivity."
    else
        log_success "http://$DOMAIN reachable (HTTP $PRE_SSL_CODE)"

        log_info "Requesting SSL certificate for $DOMAIN..."
        if certbot --nginx \
            --non-interactive \
            --agree-tos \
            --expand \
            -m "$EMAIL" \
            -d "$DOMAIN"; then
            log_success "SSL certificate obtained and installed"
        else
            log_error "Certbot failed. Common causes:"
            log_error "  - DNS not pointing $DOMAIN to this VM"
            log_error "  - Port 80 blocked by firewall / security group"
            log_error "  - Rate limit hit (5 certs per domain per week)"
            log_error "Fix and re-run: sudo certbot --nginx -d $DOMAIN"
        fi
    fi
fi

# =============================================================================
# STEP 6: Nginx reverse proxy — HTTPS on $OLLAMA_PORT -> 127.0.0.1:$OLLAMA_BACKEND_PORT
# =============================================================================
NGINX_OLLAMA_CONF="/etc/nginx/sites-available/valtunox-ollama"
log_info "Writing Nginx reverse proxy config for Ollama on port $OLLAMA_PORT..."

cat > "$NGINX_OLLAMA_CONF" << NGINX_OLLAMA_EOF
# Managed by tenant_install_ollama.sh — Ollama API
# Same domain, dedicated HTTPS port ($OLLAMA_PORT) -> 127.0.0.1:$OLLAMA_BACKEND_PORT

server {
    listen ${OLLAMA_PORT} ssl;
    listen [::]:${OLLAMA_PORT} ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:${OLLAMA_BACKEND_PORT};
        proxy_http_version 1.1;

        # Ollama rejects requests whose Host header != localhost/127.0.0.1
        # with HTTP 403. Rewrite so it always sees a trusted origin.
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Long timeouts for model inference
        proxy_read_timeout 600;
        proxy_connect_timeout 300;
        proxy_send_timeout 600;

        # Streaming responses — no buffering
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX_OLLAMA_EOF

if [ -f "$CERT_PATH" ]; then
    ln -sf "$NGINX_OLLAMA_CONF" /etc/nginx/sites-enabled/
    if nginx -t 2>&1; then
        systemctl reload nginx
        log_success "Nginx enabled: https://$DOMAIN:$OLLAMA_PORT -> http://127.0.0.1:${OLLAMA_BACKEND_PORT}"
    else
        log_error "Nginx config test failed after writing Ollama vhost"
        nginx -t
        rm -f /etc/nginx/sites-enabled/valtunox-ollama
        systemctl reload nginx
        exit 1
    fi
else
    log_warn "SSL cert not found — Ollama HTTPS vhost written but not enabled"
    log_warn "After obtaining cert, run:"
    log_warn "  sudo ln -sf $NGINX_OLLAMA_CONF /etc/nginx/sites-enabled/"
    log_warn "  sudo nginx -t && sudo systemctl reload nginx"
fi

# =============================================================================
# STEP 7: Firewall (UFW)
# =============================================================================
if command -v ufw &> /dev/null; then
    log_info "Configuring UFW..."
    ufw allow 22/tcp                   > /dev/null 2>&1
    ufw allow 80/tcp                   > /dev/null 2>&1
    ufw allow 443/tcp                  > /dev/null 2>&1
    ufw allow "${OLLAMA_PORT}/tcp"     > /dev/null 2>&1
    ufw --force enable                 > /dev/null 2>&1 || true
    log_success "UFW: ports 22, 80, 443, ${OLLAMA_PORT} open"
else
    log_info "UFW not installed — ensure your cloud security group allows"
    log_info "  TCP 80 (cert renewal), 443, and ${OLLAMA_PORT} (Ollama API)"
fi

# =============================================================================
# STEP 8: Certbot auto-renewal
# =============================================================================
if [ -f "$CERT_PATH" ]; then
    if systemctl list-timers 2>/dev/null | grep -q certbot; then
        log_success "Certbot auto-renewal timer is active"
    else
        CRON_CMD="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
        (crontab -l 2>/dev/null | grep -v certbot; echo "$CRON_CMD") | crontab -
        log_success "Certbot renewal cron installed (daily 03:00)"
    fi
fi

# =============================================================================
# STEP 9: Verify
# =============================================================================
log_info "Installed models:"
ollama list || true

echo ""
log_info "Endpoint tests:"
LOCAL_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/tags" 2>/dev/null || echo "000")
log_info "  http://127.0.0.1:${OLLAMA_BACKEND_PORT}/api/tags -> HTTP $LOCAL_CODE (expect 200)"

if [ -f "$CERT_PATH" ]; then
    HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN:$OLLAMA_PORT/api/tags" 2>/dev/null || echo "000")
    log_info "  https://$DOMAIN:$OLLAMA_PORT/api/tags -> HTTP $HTTPS_CODE (expect 200)"
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
log_success "=========================================="
log_success "  Ollama installation complete"
log_success "=========================================="
log_info "  Local API : http://127.0.0.1:${OLLAMA_BACKEND_PORT}"
if [ -f "$CERT_PATH" ]; then
    log_success "  Public URL: https://$DOMAIN:$OLLAMA_PORT"
else
    log_warn "  Public URL: pending SSL cert — run sudo certbot --nginx -d $DOMAIN"
fi
log_info "  Models    : llama3.2, llama3.3, gemma4:e4b"
echo ""
log_info "Chat test (interactive):"
log_info "  sudo ./tenant_install_ollama.sh --test                      # chat with llama3.3"
log_info "  sudo ./tenant_install_ollama.sh --test --model llama3.2     # chat with llama3.2"
echo ""
log_info "Useful commands:"
log_info "  sudo systemctl status ollama                 # Ollama service status"
log_info "  sudo journalctl -u ollama -f                 # Ollama logs"
log_info "  sudo nginx -t && sudo systemctl reload nginx # Reload nginx"
log_info "  sudo certbot certificates                    # View SSL certs"
log_info "  ollama list                                  # List models"
log_info "  ollama pull <model>                          # Pull new model"
log_info "  ollama run llama3.3                          # Chat directly"
echo ""

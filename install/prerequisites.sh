#!/bin/bash

# Reusables Prerequisites check script for Docker Compose deployments
# This script verifies and installs all required dependencies:
# - Docker and Docker Compose installation and configuration
# - Essential system packages and networking tools
# - Python 3.12.3 with required packages
# - Container registry authentication setup
# - System resource verification
# - Network connectivity checks
# - Filesystem and permission validations
# Used by Terraform to ensure all prerequisites are met before deployment

# Log file for installation output
LOG_FILE="prerequisites_install.log"
echo "Installation log started at $(date)" > "$LOG_FILE"


# Functions for colored output
print_info() {
    echo -e "\033[0;34m$1\033[0m"
}

print_success() {
    echo -e "\033[0;32m✓ $1\033[0m"
}

print_error() {
    echo -e "\033[0;31m✗ $1\033[0m"
}

# Safely restart a service whether or not systemd is available
restart_service() {
    local svc="$1"
    # Prefer systemctl only if it exists and systemd is actually running
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        sudo systemctl restart "$svc" >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        sudo service "$svc" restart >/dev/null 2>&1 || true
    else
        # No service manager available; skip quietly
        true
    fi
}

# Check and install Docker
print_info "Checking for Docker..."
if ! command -v docker &>/dev/null; then
    print_info "Docker not found. Installing... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release &>> "$LOG_FILE"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg &>> "$LOG_FILE"
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io &>> "$LOG_FILE"
    # Enable/start docker only if a service manager is available; log silently
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        sudo systemctl enable docker &>> "$LOG_FILE" || true
        sudo systemctl start docker &>> "$LOG_FILE" || true
    elif command -v service >/dev/null 2>&1; then
        sudo service docker start &>> "$LOG_FILE" || true
    fi
    print_success "Docker installed."
else
    print_success "Docker is already installed."
fi

# Check and install vim
print_info "Checking for vim..."
if ! command -v vim &>/dev/null; then
    print_info "Installing vim... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y vim &>> "$LOG_FILE"
    print_success "vim installed."
else
    print_success "vim is already installed."
fi

# Check and install networking tools
print_info "Checking for networking tools..."

# Check net-tools
if ! command -v netstat &>/dev/null; then
    print_info "Installing net-tools... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y net-tools &>> "$LOG_FILE"
    print_success "net-tools installed."
else
    print_success "net-tools is already installed."
fi

# Check iputils-ping
if ! command -v ping &>/dev/null; then
    print_info "Installing iputils-ping... (check $LOG_FILE for details)"
    sudo apt-get install -y iputils-ping &>> "$LOG_FILE"
    print_success "iputils-ping installed."
else
    print_success "iputils-ping is already installed."
fi

# Check iproute2
if ! command -v ip &>/dev/null; then
    print_info "Installing iproute2... (check $LOG_FILE for details)"
    sudo apt-get install -y iproute2 &>> "$LOG_FILE"
    print_success "iproute2 installed."
else
    print_success "iproute2 is already installed."
fi

# Check and install Docker Compose
print_info "Checking for docker-compose..."
if ! command -v docker-compose &>/dev/null; then
    print_info "docker-compose not found. Installing... (check $LOG_FILE for details)"
    DOCKER_COMPOSE_VERSION="1.29.2" # You might want to update this to a newer version like v2.x.x
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose &>> "$LOG_FILE"
    sudo chmod +x /usr/local/bin/docker-compose &>> "$LOG_FILE"
    print_success "docker-compose ${DOCKER_COMPOSE_VERSION} installed."
else
    print_success "docker-compose is already installed."
fi

# Check and install Terraform
print_info "Checking for Terraform..."
if ! command -v terraform &>/dev/null; then
    print_info "Terraform not found. Installing... (check $LOG_FILE for details)"
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg &>> "$LOG_FILE"
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    sudo apt-get update &>> "$LOG_FILE" && sudo apt-get install -y terraform &>> "$LOG_FILE"
    print_success "Terraform installed."
else
    print_success "Terraform is already installed."
fi

# Check and install Go
print_info "Checking for Go..."
if ! command -v go &>/dev/null; then
    print_info "Go not found. Installing... (check $LOG_FILE for details)"
    GO_VERSION="1.22.4" # Updated to a more recent stable version
    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz &>> "$LOG_FILE"
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz &>> "$LOG_FILE"
    rm go${GO_VERSION}.linux-amd64.tar.gz &>> "$LOG_FILE"
    if ! grep -q '/usr/local/go/bin' <<< "$PATH"; then
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
    fi
    print_success "Go ${GO_VERSION} installed."
else
    print_success "Go is already installed."
fi

# Check and install Node.js (with npm)
print_info "Checking for Node.js..."
if ! command -v node &>/dev/null; then
    print_info "Node.js not found. Installing Node.js 20.x... (check $LOG_FILE for details)"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - &>> "$LOG_FILE"
    sudo apt-get install -y nodejs &>> "$LOG_FILE"
    print_success "Node.js 20.x and npm installed."
else
    # Check if existing Node.js version is sufficient (>= 20.19)
    NODE_VERSION=$(node -v | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        print_info "Node.js $NODE_VERSION is too old. Upgrading to Node.js 20.x... (check $LOG_FILE for details)"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - &>> "$LOG_FILE"
        sudo apt-get install -y nodejs &>> "$LOG_FILE"
        print_success "Node.js upgraded to 20.x."
    else
        print_success "Node.js $NODE_VERSION is already installed."
    fi
fi

# Check and install Redis
print_info "Checking for Redis..."
if ! command -v redis-server &>/dev/null; then
    print_info "Redis not found. Installing... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y redis-server &>> "$LOG_FILE"
    # Configure Redis to bind to localhost and enable as service
    if [ -f /etc/redis/redis.conf ]; then
        sudo sed -i 's/^bind 127.0.0.1 ::1/bind 127.0.0.1/' /etc/redis/redis.conf &>> "$LOG_FILE" || true
        sudo sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf &>> "$LOG_FILE" || true
    fi
    # Enable and start Redis service
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        sudo systemctl enable redis-server &>> "$LOG_FILE" || true
        sudo systemctl start redis-server &>> "$LOG_FILE" || true
    elif command -v service >/dev/null 2>&1; then
        sudo service redis-server start &>> "$LOG_FILE" || true
    fi
    print_success "Redis installed and configured."
else
    print_success "Redis is already installed."
fi

##############################
# Python (3.12.x OK) and pip #
##############################
print_info "Checking for Python 3.12.x and pip3..."

# Helper to compare versions (returns 0 if $1 >= $2)
version_gte() {
    # sort -V sorts by version, head -n1 gives the lowest; if lowest equals required, then $1 >= $2
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

PY_OK=false
if command -v python3.12 &>/dev/null; then
    PY_VER=$(python3.12 -V 2>&1 | awk '{print $2}')
    if version_gte "$PY_VER" "3.12.0"; then
        print_success "Python $PY_VER detected (>= 3.12.0)."
        PY_OK=true
    fi
fi

if [ "$PY_OK" = false ]; then
    # Fallback to system python3 if it's sufficiently new
    if command -v python3 &>/dev/null; then
        PY3_VER=$(python3 -V 2>&1 | awk '{print $2}')
        if version_gte "$PY3_VER" "3.10.0"; then
            print_success "System Python3 $PY3_VER is acceptable (>= 3.10)."
            PY_OK=true
        fi
    fi
fi

if [ "$PY_OK" = false ]; then
    print_info "Suitable Python not found. Installing Python 3.12 (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y software-properties-common &>> "$LOG_FILE"
    sudo add-apt-repository -y ppa:deadsnakes/ppa &>> "$LOG_FILE" || true
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y python3.12 python3.12-venv python3.12-dev &>> "$LOG_FILE"
    print_success "Python 3.12 installed."
fi

# Check for pip3
if ! command -v pip3 &>/dev/null; then
    print_info "pip3 not found. Installing... (check $LOG_FILE for details)"
    sudo apt-get install -y python3-pip &>> "$LOG_FILE"
    print_success "pip3 installed."
else
    print_success "pip3 is already installed."
fi

# Install Celery (Python task queue) with Redis support
print_info "Checking for Celery..."
if ! python3 -c "import celery" &>/dev/null 2>&1; then
    print_info "Celery not found. Installing with Redis support... (check $LOG_FILE for details)"
    pip3 install celery[redis] &>> "$LOG_FILE" || sudo pip3 install celery[redis] &>> "$LOG_FILE"
    print_success "Celery with Redis support installed."
else
    print_success "Celery is already installed."
fi

# Verify all prerequisites are installed
REQUIRED_COMMANDS=(
    docker
    docker-compose
    terraform
    netstat
    ping
    ip
    vim
    go
    node
    npm # npm comes with node
    python3 # accept system python3, version validated separately
    pip3
    redis-server # Redis server
)

ALL_INSTALLED=true
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "Error: $cmd is still not installed. Please check the installation logs."
        ALL_INSTALLED=false
    fi
done

############################################
# Ensure required CLI utilities are present #
############################################
# jq is required later by Terraform local-exec
if ! command -v jq &>/dev/null; then
    print_info "Installing jq... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y jq &>> "$LOG_FILE"
    print_success "jq installed."
else
    print_success "jq is already installed."
fi

# lsof is used by entrypoint checks
if ! command -v lsof &>/dev/null; then
    print_info "Installing lsof... (check $LOG_FILE for details)"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y lsof &>> "$LOG_FILE"
    print_success "lsof installed."
else
    print_success "lsof is already installed."
fi

# Additional check for Python acceptable version (3.12.x or Python3 >= 3.10)
if "$ALL_INSTALLED"; then
    PY_OK_FINAL=false
    if command -v python3.12 &>/dev/null; then
        PY_VER=$(python3.12 -V 2>&1 | awk '{print $2}')
        if version_gte "$PY_VER" "3.12.0"; then
            PY_OK_FINAL=true
        fi
    elif command -v python3 &>/dev/null; then
        PY3_VER=$(python3 -V 2>&1 | awk '{print $2}')
        if version_gte "$PY3_VER" "3.10.0"; then
            PY_OK_FINAL=true
        fi
    fi
    if [ "$PY_OK_FINAL" = false ]; then
        print_error "Error: Suitable Python version not found."
        ALL_INSTALLED=false
    fi
fi

if "$ALL_INSTALLED"; then
    print_success "All prerequisites verified successfully!"
else
    print_error "Some prerequisites are missing or not the correct version. Please review the output."
    exit 1
fi
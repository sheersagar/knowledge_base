#!/bin/bash
# ==============================================================================
# ERPNext v16 Automated Installation Script
# Supports: Local (All-in-one) and Managed (Remote DB/Redis) Deployments
# ==============================================================================

set -e

# Disable interactive prompts during apt install (fixes the "pink screen" issue)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ==============================================================================
# 1. Interactive Prompts
# ==============================================================================
clear
echo "================================================================="
echo "          ERPNext v16 Automated Setup Script"
echo "================================================================="
echo ""
echo "Select Architecture Type:"
echo "  1) Local   (MariaDB and Redis installed on this VM)"
echo "  2) Managed (MariaDB and Redis are hosted remotely/managed)"
echo ""
read -p "Enter choice [1 or 2]: " ARCH_CHOICE

if [[ "$ARCH_CHOICE" != "1" && "$ARCH_CHOICE" != "2" ]]; then
    err "Invalid choice. Exiting."
fi

read -p "Client Application / Site Name (e.g., company_name): " SITE_NAME
read -p "Database Root Password: " DB_ROOT_PASS
read -p "ERPNext Admin Password: " ADMIN_PASS
read -p "Domain Name for ERP (e.g., erp.domain.com) [Optional, press Enter to skip]: " DOMAIN_NAME
if [ -n "$DOMAIN_NAME" ]; then
    read -p "Enable Let's Encrypt SSL on this server? (Type 'n' if using AWS ALB/Cloudflare) [y/N]: " ENABLE_SSL
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        read -p "Email for Let's Encrypt SSL (e.g., admin@domain.com): " SSL_EMAIL
    fi
fi
read -p "Install extra apps (HRMS, Insights, India Compliance)? [y/N]: " INSTALL_EXTRA_APPS

if [ "$ARCH_CHOICE" == "2" ]; then
    SETUP_TYPE="managed"
    read -p "Remote MariaDB Private IP: " MARIADB_IP
    read -p "Managed Redis IP: " REDIS_IP
    
    if [[ -z "$MARIADB_IP" || -z "$REDIS_IP" ]]; then
        err "Remote IPs cannot be empty for Managed setup."
    fi
else
    SETUP_TYPE="local"
    MARIADB_IP="127.0.0.1"
fi

echo ""
echo "================================================================="
echo "Review Configuration:"
echo "Architecture:   $SETUP_TYPE"
echo "Site Name:      $SITE_NAME"
if [ "$SETUP_TYPE" == "managed" ]; then
    echo "MariaDB IP:     $MARIADB_IP"
    echo "Redis IP:       $REDIS_IP"
fi
echo "Domain:         ${DOMAIN_NAME:-None}"
echo "================================================================="
read -p "Press Enter to start installation or Ctrl+C to cancel..."

# ==============================================================================
# 2. System Packages
# ==============================================================================
log "Updating system and installing base packages..."
sudo apt update && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt upgrade -y

log "Checking memory and creating Swap file if needed (prevents Exit Code 137 during build)..."
if [ $(free -m | awk '/^Swap:/ {print $2}') -lt 2000 ]; then
    sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile || true
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    log "2GB Swap file created and enabled."
else
    log "Sufficient Swap memory already exists."
fi

echo '* libraries/restart-without-asking boolean true' | sudo debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y \
  git curl wget jq \
  python3 python3-dev python3-pip python3-venv \
  build-essential \
  libffi-dev libssl-dev \
  software-properties-common \
  xvfb libfontconfig \
  cron \
  nginx \
  supervisor \
  pkg-config \
  libmariadb-dev \
  libmariadb-dev-compat \
  mysql-client \
  redis-tools

# ==============================================================================
# 3. Python 3.14
# ==============================================================================
log "Installing Python 3.14 (Required for v16)..."
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y python3.14 python3.14-dev python3.14-venv

# ==============================================================================
# 4. MariaDB & Redis (Architecture Dependent)
# ==============================================================================
if [ "$SETUP_TYPE" == "local" ]; then
    log "Installing local MariaDB and Redis..."
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y mariadb-server mariadb-client redis-server
    sudo systemctl start mariadb redis-server
    sudo systemctl enable mariadb redis-server

    log "Configuring MariaDB..."
    cat <<EOF | sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf
[server]

[mysql]
default-character-set = utf8mb4

[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
    sudo systemctl restart mariadb

    log "Setting MariaDB root password..."
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASS}'); FLUSH PRIVILEGES;"
    
else
    log "Configuring for Managed Setup (Skipping local MariaDB install)..."
    log "Installing redis-server binary ONLY for bench init..."
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y redis-server
    sudo systemctl stop redis-server
    sudo systemctl disable redis-server
    
    # Pre-flight Check for Managed Services
    log "Running connection checks to managed services..."
    mysql -h "$MARIADB_IP" -u root -p"$DB_ROOT_PASS" -e "SELECT 1;" >/dev/null 2>&1 || err "Cannot connect to remote MariaDB at $MARIADB_IP"
    redis-cli -h "$REDIS_IP" -p 6379 ping | grep -q PONG || err "Cannot connect to managed Redis at $REDIS_IP"
fi

# ==============================================================================
# 5. Node.js 24 & wkhtmltopdf
# ==============================================================================
log "Installing Node.js 24 and yarn..."
sudo apt remove -y nodejs 2>/dev/null || true
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y nodejs
sudo npm install -g yarn

log "Installing wkhtmltopdf..."
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb -O /tmp/wkhtmltox.deb
sudo dpkg -i /tmp/wkhtmltox.deb || sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -f -y
rm /tmp/wkhtmltox.deb

# ==============================================================================
# 6. Frappe User Creation
# ==============================================================================
if ! id -u frappe > /dev/null 2>&1; then
    log "Creating frappe user..."
    sudo adduser --disabled-password --gecos "" frappe
    sudo usermod -aG sudo frappe
    echo "frappe ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/frappe
    sudo chmod 0440 /etc/sudoers.d/frappe
else
    log "Frappe user already exists."
fi

# ==============================================================================
# 7. Bench CLI Install
# ==============================================================================
log "Installing bench CLI and Ansible..."
PIP_CMD="sudo pip3"
# Check if python 3.12+ (requires --break-system-packages)
if pip3 --version | grep -qE "python 3\.1[2-9]"; then
    PIP_CMD="sudo pip3 --break-system-packages"
fi

$PIP_CMD install frappe-bench ansible

# ==============================================================================
# 8. Setup Bench & ERPNext (Running as Frappe)
# ==============================================================================
log "Initializing bench and installing ERPNext..."

sudo su - frappe <<EOF
set -e

# Init Bench
if [ ! -d '/home/frappe/frappe-bench' ]; then
    echo '[+] Running bench init...'
    bench init --frappe-branch version-16 /home/frappe/frappe-bench --python python3.14
fi
cd /home/frappe/frappe-bench

# Get ERPNext
if [ ! -d 'apps/erpnext' ]; then
    echo '[+] Downloading ERPNext v16...'
    bench get-app --branch version-16 erpnext
fi

# Managed Redis Configuration
if [ "$SETUP_TYPE" = "managed" ]; then
    echo '[+] Configuring common_site_config.json for Managed Redis...'
    jq '.redis_cache = "redis://'$REDIS_IP':6379" | .redis_queue = "redis://'$REDIS_IP':6379" | .redis_socketio = "redis://'$REDIS_IP':6379"' sites/common_site_config.json > sites/tmp.json && mv sites/tmp.json sites/common_site_config.json
fi

# Create Site
if [ ! -d "sites/$SITE_NAME" ]; then
    echo "[+] Creating site $SITE_NAME..."
    bench new-site "$SITE_NAME" \
        --db-host "$MARIADB_IP" \
        --db-port 3306 \
        --db-root-username root \
        --db-root-password "$DB_ROOT_PASS" \
        --admin-password "$ADMIN_PASS" \
        --mariadb-user-host-login-scope='%'

    echo '[+] Setting default site...'
    bench use "$SITE_NAME"

    echo '[+] Starting bench workers temporarily for installation phase...'
    bench start > /dev/null 2>&1 &
    BENCH_PID=\$!
    sleep 5

    echo '[+] Installing ERPNext on site...'
    bench --site "$SITE_NAME" install-app erpnext

    if [ "$INSTALL_EXTRA_APPS" = "y" ] || [ "$INSTALL_EXTRA_APPS" = "Y" ]; then
        echo '[+] Downloading extra apps...'
        bench get-app --branch version-16 https://github.com/frappe/hrms.git || true
        bench get-app --branch develop https://github.com/frappe/insights.git || true
        bench get-app --branch version-16 https://github.com/resilient-tech/india-compliance.git || true

        echo '[+] Installing extra apps on site...'
        bench --site "$SITE_NAME" install-app hrms || true
        bench --site "$SITE_NAME" install-app insights || true
        bench --site "$SITE_NAME" install-app india_compliance || true
    fi

    echo '[+] Running post-installation migrations...'
    bench --site "$SITE_NAME" migrate
    bench --site "$SITE_NAME" clear-cache

    echo '[+] Stopping temporary bench workers...'
    kill \$BENCH_PID || true
    wait \$BENCH_PID 2>/dev/null || true

    if [ -n "$DOMAIN_NAME" ]; then
        echo "[+] Setting up domain $DOMAIN_NAME for site..."
        bench setup add-domain "$DOMAIN_NAME" --site "$SITE_NAME"
    fi
else
    echo "[!] Site $SITE_NAME already exists."
fi
EOF

# ==============================================================================
# 9. Production Setup
# ==============================================================================
log "Cleaning up old Nginx configurations..."
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-enabled/frappe-bench || true
sudo rm -f /etc/nginx/conf.d/frappe-bench.conf || true

log "Setting up production (Nginx & Supervisor)..."
sudo su - frappe <<EOF
set -e
cd /home/frappe/frappe-bench

# Build assets (CRITICAL for v16)
echo '[+] Building assets...'
bench build

echo '[+] Setting up bench production...'
sudo env PATH=\$PATH:/home/frappe/.local/bin bench setup production frappe --yes
EOF

# Fix Supervisor Symlink
sudo ln -sf /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
sudo systemctl restart supervisor || true
sleep 3
sudo supervisorctl reread && sudo supervisorctl update

# Fix Static Asset Permissions
log "Fixing Nginx permissions..."
sudo chmod o+x /home/frappe
sudo chmod o+x /home/frappe/frappe-bench
sudo chmod -R o+r /home/frappe/frappe-bench/sites/assets

# Modify Supervisor to remove local Redis if Managed
if [ "$SETUP_TYPE" == "managed" ]; then
    log "Removing local Redis from Supervisor..."
    sudo sed -i '/^\[group:frappe-bench-redis\]/,/^$/s/^/# /' /home/frappe/frappe-bench/config/supervisor.conf
    sudo sed -i '/^\[program:frappe-bench-redis-cache\]/,/^$/s/^/# /' /home/frappe/frappe-bench/config/supervisor.conf
    sudo sed -i '/^\[program:frappe-bench-redis-queue\]/,/^$/s/^/# /' /home/frappe/frappe-bench/config/supervisor.conf
    
    sudo supervisorctl reread
    sudo supervisorctl update
fi

if [ -n "$DOMAIN_NAME" ]; then
    log "Enforcing Domain Name in Nginx configuration..."
    sudo sed -i "s/server_name[[:space:]]\+$SITE_NAME/server_name $DOMAIN_NAME/g" /etc/nginx/conf.d/frappe-bench.conf
fi

sudo nginx -t && sudo systemctl restart nginx || true

# ==============================================================================
# 10. SSL Setup
# ==============================================================================
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    log "Setting up SSL for $DOMAIN_NAME..."
    sudo snap install --classic certbot || sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt install -y certbot python3-certbot-nginx
    
    echo "Wait for DNS to propagate. Attempting SSL..."
    sudo certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "$SSL_EMAIL" || warn "SSL Setup failed. You may need to run certbot manually once DNS propagates."
fi

log "================================================================="
log "          ERPNext v16 Installation Complete!"
log "================================================================="
log "Site Name: $SITE_NAME"
log "Admin URL: http://${DOMAIN_NAME:-$SITE_NAME}"
log "Admin Username: Administrator"
log "Admin Password: $ADMIN_PASS"
echo "================================================================="

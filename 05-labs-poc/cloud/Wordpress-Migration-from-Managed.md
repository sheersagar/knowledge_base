# WordPress Migration Documentation
## Migrating Managed WordPress to Self-Hosted EC2 with Nginx


**Target URL:** `https://preprod.example-domain.<company.com>/blog`

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Phase 1 — EC2 Instance Setup](#phase-1--ec2-instance-setup)
3. [Phase 2 — System & Software Installation](#phase-2--system--software-installation)
4. [Phase 3 — Dedicated WordPress User](#phase-3--dedicated-wordpress-user)
5. [Phase 4 — MySQL Database Setup](#phase-4--mysql-database-setup)
6. [Phase 5 — WordPress Installation](#phase-5--wordpress-installation)
7. [Phase 6 — wp-config.php Configuration](#phase-6--wp-configphp-configuration)
8. [Phase 7 — PHP-FPM Pool Configuration](#phase-7--php-fpm-pool-configuration)
9. [Phase 8 — Nginx Configuration](#phase-8--nginx-configuration)
10. [Phase 9 — WP-CLI Installation](#phase-9--wp-cli-installation)
11. [Phase 10 — WordPress Core Install](#phase-10--wordpress-core-install)
12. [Phase 11 — Import .wpress Backup](#phase-11--import-wpress-backup)
13. [Phase 12 — File Permissions](#phase-12--file-permissions)
14. [Phase 13 — ALB Configuration](#phase-13--alb-configuration)
15. [Troubleshooting Log](#troubleshooting-log)
16. [Final Verification](#final-verification)
17. [Replication Guide for example-domain.com/blog](#replication-guide-for-example-domaincomblog)
18. [Quick Reference](#quick-reference)

---

## Architecture Overview

```
User
 │
 ▼
AWS ALB (STAGING-example-domain)
 │  HTTPS:443 listener
 │  ├── /aboutus  → nginx-proxy target group → aboutus.example-domain.com (static)
 │  ├── /blog     → test-wp target group     → WordPress EC2 (this setup)
 │  └── default   → frontend target group    → Next.js app
 │
 ▼
WordPress EC2 Server (Ubuntu 22.04)
 ├── Nginx (reverse proxy + static files)
 ├── PHP-FPM 8.3 (WordPress pool)
 ├── MySQL (wordpress_db)
 └── /var/www/wordpress (WordPress files)
```

**Key Design Decisions:**
- ALB terminates SSL — EC2 only needs to listen on port 80
- WordPress installed at `/var/www/wordpress` (root), not in a `/blog` subfolder
- Nginx strips `/blog` prefix before passing to WordPress
- Dedicated `wpuser` system account owns WordPress files for security isolation
- Separate PHP-FPM pool (`wordpress`) isolated from other PHP sites

---

## Phase 1 — EC2 Instance Setup

### Launch Instance
1. AWS Console → EC2 → **Launch Instance**
2. AMI: **Ubuntu 22.04 LTS**
3. Instance type: `t2.small` or higher
4. Key pair: create or select existing `.pem` key — **save it securely**
5. Security Group inbound rules:

| Type | Port | Source |
|---|---|---|
| SSH | 22 | Your IP only |
| HTTP | 80 | 0.0.0.0/0 |

> **Note:** HTTPS (443) is handled at the ALB level. EC2 does not need port 443 open since ALB terminates SSL and forwards HTTP to EC2.

6. Allocate and associate an **Elastic IP** to keep a static IP

### SSH Into Instance
```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

### If Key is Lost — Recovery Steps
1. Go to **EC2 → Select Instance → Connect → EC2 Instance Connect** (browser terminal, no key needed)
2. On local machine, generate new key:
```bash
ssh-keygen -t rsa -b 4096 -f ~/new-key
cat ~/new-key.pub
```
3. In EC2 Instance Connect browser terminal:
```bash
echo "paste-your-public-key-here" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```
4. SSH normally with new key:
```bash
chmod 400 ~/new-key
ssh -i ~/new-key ubuntu@<EC2-PUBLIC-IP>
```

---

## Phase 2 — System & Software Installation

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Nginx
sudo apt install nginx -y
sudo systemctl enable nginx
sudo systemctl start nginx

# Install MySQL
sudo apt install mysql-server -y
sudo systemctl enable mysql
sudo systemctl start mysql

# Secure MySQL installation
sudo mysql_secure_installation
# Answer:
# Validate password plugin → N
# Remove anonymous users → Y
# Disallow root login remotely → Y
# Remove test database → Y
# Reload privilege tables → Y

# Install PHP 8.3 FPM and all WordPress required extensions
sudo apt install php-fpm php-mysql php-curl php-gd php-mbstring \
  php-xml php-xmlrpc php-soap php-intl php-zip php-imagick unzip -y
```

> **Important:** Check your PHP version — it determines socket paths used later:
```bash
php -v
# This server had: PHP 8.3.x
```

---

## Phase 3 — Dedicated WordPress User

Instead of running WordPress as `www-data` or `ubuntu`, a dedicated system user is created for security isolation.

```bash
sudo adduser --system --no-create-home --group wpuser
```

**Why this matters:**
- If WordPress is compromised, attacker is limited to `wpuser` permissions
- PHP-FPM processes for WordPress are isolated from other sites
- File ownership is clearly separated

---

## Phase 4 — MySQL Database Setup

```bash
# Login without password on fresh Ubuntu (uses auth_socket)
sudo mysql
```

```sql
CREATE DATABASE wordpress_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wp_user'@'localhost' IDENTIFIED BY 'StrongPassword123!';
GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wp_user'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> **Troubleshooting:** If `sudo mysql -u root -p` asks for password on a fresh install, just press **Enter** (no password set yet). If that fails, use `sudo mysql` instead — Ubuntu uses `auth_socket` authentication by default.

---

## Phase 5 — WordPress Installation

```bash
# Create directory
sudo mkdir -p /var/www/wordpress
cd /var/www/wordpress

# Download and extract WordPress
sudo wget https://wordpress.org/latest.zip
sudo apt install unzip -y   # install unzip if not present
sudo unzip latest.zip
sudo mv wordpress/* .
sudo rm -rf wordpress latest.zip

# Create config from sample
sudo cp wp-config-sample.php wp-config.php

# Verify files
ls /var/www/wordpress
# Expected: wp-admin  wp-content  wp-includes  wp-config.php  index.php  ...
```

---

## Phase 6 — wp-config.php Configuration

```bash
sudo vi /var/www/wordpress/wp-config.php
```

### Database Settings
Update these values in the file: Make sure that these values will be same as you set them in Phase 4
```php
define( 'DB_NAME', 'wordpress_db' );
define( 'DB_USER', 'wp_user' );
define( 'DB_PASSWORD', 'StrongPassword123!' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
```

### Add Custom Config Block
Add these lines **after `DB_COLLATE` and before the Authentication keys section**:

```php
/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', '' );

// ← ADD BELOW HERE

// Detect HTTPS from ALB (ALB terminates SSL and forwards HTTP to EC2)
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
define('WP_HOME', 'https://preprod.example-domain.infinitelocus.com/blog');
define('WP_SITEURL', 'https://preprod.example-domain.infinitelocus.com/blog');
define('WP_MEMORY_LIMIT', '256M');

/**#@+
 * Authentication unique keys and salts.
```

> **Why `HTTP_X_FORWARDED_PROTO`?**  
> ALB terminates SSL and forwards plain HTTP to EC2. WordPress needs to know the original request was HTTPS. The ALB adds `X-Forwarded-Proto: https` header which this code detects.

> **Do NOT use `$_SERVER['HTTPS'] = 'on'` directly** — this causes infinite redirect loops when the site is accessed via HTTP (e.g., health checks).

### Generate Secret Keys
Replace the placeholder keys by visiting:
```
https://api.wordpress.org/secret-key/1.1/salt/
```
Copy the output and replace the `put your unique phrase here` block in wp-config.php.

---

## Phase 7 — PHP-FPM Pool Configuration

A dedicated PHP-FPM pool isolates WordPress PHP processes.

```bash
# Check PHP version
php -v  # PHP 8.3.x on this server

# Copy default pool as base
sudo cp /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/wordpress.conf
sudo vi /etc/php/8.3/fpm/pool.d/wordpress.conf
```

### Changes to Make (use esc/ to search and enter)

| Find | Replace With |
|---|---|
| `[www]` | `[wordpress]` |
| `user = www-data` | `user = wpuser` |
| `listen = /run/php/php8.3-fpm.sock` | `listen = /run/php/php8.3-wordpress.sock` |

Keep `group`, `listen.owner`, `listen.group` as `www-data`.

### Add Upload Limits at Bottom of File if present
```ini
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
```

```bash
# Restart PHP-FPM
sudo systemctl restart php8.3-fpm

# Verify new socket exists
ls /run/php/
# Must see: php8.3-wordpress.sock
```

### Verify Pool Config is Correct
```bash
grep -E "^\[|^user|^listen" /etc/php/8.3/fpm/pool.d/wordpress.conf
```

Expected output:
```
[wordpress]
user = wpuser
group = www-data
listen = /run/php/php8.3-wordpress.sock
listen.owner = www-data
listen.group = www-data
```

---

## Phase 8 — Nginx Configuration

### Key Design: /blog Prefix Stripping
WordPress is installed at `/var/www/wordpress` (root) but accessed via `/blog` URL path. Nginx strips the `/blog` prefix before passing requests to WordPress.

**Why `^~` prefix on `/blog/` location?**  
Without `^~`, Nginx's regex location blocks (like `~* \.(js|css...)`) would intercept static file requests like `/blog/wp-includes/js/file.js` before the `/blog/` rewrite could strip the prefix, causing 404s.

```bash
sudo vi /etc/nginx/sites-available/wordpress
```

```nginx
server {
    listen 80;
    server_name <EC2-PUBLIC-IP> preprod.example-domain.<company>.com;

    root /var/www/wordpress;
    index index.php index.html;

    client_max_body_size 512M;

    # Handle exact /blog (no trailing slash)
    location = /blog {
        rewrite ^ /index.php last;
    }

    # Handle /blog/* - strip prefix and restart location matching
    # ^~ gives this block priority over regex blocks (js/css/etc)
    location ^~ /blog/ {
        rewrite ^/blog/(.*)$ /$1 last;
    }

    # WordPress permalinks
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # PHP-FPM handler
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-wordpress.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    # Deny .htaccess (not used in Nginx)
    location ~ /\.ht {
        deny all;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|svg|mp4)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # Block xmlrpc.php
    location = /xmlrpc.php {
        deny all;
    }

    error_log /var/log/nginx/wordpress_error.log;
    access_log /var/log/nginx/wordpress_access.log;
}
```

```bash
# Enable site
sudo ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default

# Test and reload
sudo nginx -t   # Must return: syntax is ok
sudo systemctl restart nginx
```

---

## Phase 9 — WP-CLI Installation

WP-CLI allows managing WordPress from the command line.

```bash
# Must be run from home directory — not /var/www (permission denied)
cd ~

curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# Verify
wp --info
```

---

## Phase 10 — WordPress Core Install

This creates all database tables. Required before importing content.

```bash
sudo -u wpuser wp core install \
  --url="https://preprod.example-domain.<company>.com/blog" \
  --title="My WordPress Site" \
  --admin_user="admin" \
  --admin_password="AdminPassword123!" \
  --admin_email="your@email.com" \
  --path=/var/www/wordpress
```

> **Note:** The `sh: 1: /usr/sbin/sendmail: not found` warning is harmless — WordPress tried to send a confirmation email but sendmail isn't installed. Installation still succeeds.

> **Note:** These credentials are temporary — they will be overwritten when you import the `.wpress` backup.

---

## Phase 11 — Import .wpress Backup

### Export from Managed WordPress
1. Log into managed WordPress admin
2. Go to **Plugins → Add New → Search "All-in-One WP Migration"**
3. Install and Activate
4. Go to **All-in-One WP Migration → Export → Export To → File**
5. Download the `.wpress` file (in this case: `blog-example-domain-com-20260221-154430-ybf0s4y9r186.wpress`, 400MB)

### Transfer to EC2
```bash
# From local machine
scp -i ~/.ssh/your-key.pem ~/Downloads/blog-example-domain-com-20260221-154430-ybf0s4y9r186.wpress ubuntu@<EC2-PUBLIC-IP>:~/
```

### Set Up Import Directory
```bash
sudo mkdir -p /var/www/wordpress/wp-content/ai1wm-backups
sudo mv ~/blog-example-domain-com-20260221-154430-ybf0s4y9r186.wpress /var/www/wordpress/wp-content/ai1wm-backups/
sudo chown wpuser:www-data /var/www/wordpress/wp-content/ai1wm-backups/*.wpress
sudo chmod 664 /var/www/wordpress/wp-content/ai1wm-backups/*.wpress
```

### Install Plugin via WP-CLI
```bash
cd /var/www/wordpress
sudo -u wpuser wp plugin install all-in-one-wp-migration --activate --path=/var/www/wordpress
```

### Import via Browser
The free version of All-in-One WP Migration CLI restore requires a paid extension. Use the browser instead:

1. Open: `http://<EC2-PUBLIC-IP>/wp-admin`
2. Go to **All-in-One WP Migration → Import**
3. Click **Import From → File**
4. Upload your `.wpress` file

**If upload size limit is too small (shows 2MB limit):**
```bash
grep -r "MAX_FILE_SIZE" /var/www/wordpress/wp-content/plugins/all-in-one-wp-migration/
# Find the file containing MAX_FILE_SIZE, then edit it:
sudo vi <that-file>
# Change: define( 'AI1WM_MAX_FILE_SIZE', 2 << 28 );
# To:     define( 'AI1WM_MAX_FILE_SIZE', 2 << 30 );
```

### Fix URLs After Import
After import, the database will have the old managed host URLs. Replace them:

```bash
# Replace old domain with new domain
sudo -u wpuser wp search-replace 'https://old-managed-host.com' 'https://preprod.example-domain.<company>.com' \
  --all-tables --path=/var/www/wordpress

# Explicitly update siteurl and home
sudo -u wpuser wp option update siteurl 'https://preprod.example-domain.<company>.com/blog' \
  --path=/var/www/wordpress
sudo -u wpuser wp option update home 'https://preprod.example-domain.<company>.com/blog' \
  --path=/var/www/wordpress

# Flush rewrite rules
sudo -u wpuser wp rewrite flush --path=/var/www/wordpress
```

---

## Phase 12 — File Permissions

Run after every major file operation (WordPress install, import, etc.):

```bash
sudo chown -R wpuser:www-data /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;

# wp-content needs write access for uploads, plugin installs, theme updates
sudo chmod -R 775 /var/www/wordpress/wp-content
```

**Permission Summary:**

| Resource | Owner | Group | Permissions |
|---|---|---|---|
| Directories | wpuser | www-data | 755 |
| Files | wpuser | www-data | 644 |
| wp-content/ | wpuser | www-data | 775 |

---

## Phase 13 — ALB Configuration

### Target Group Setup
1. AWS Console → EC2 → **Target Groups → Create Target Group**
2. Settings:
   - Target type: Instance
   - Name: `test-wp`
   - Protocol: HTTP, Port: 80
   - Health check path: `/`
3. Register your EC2 instance as a target

### HTTPS:443 Listener Rules
Go to **EC2 → Load Balancers → STAGING-example-domain → HTTPS:443 → Manage Rules**

Add rule with **Priority 2** (must be before the default rule):

| Setting | Value |
|---|---|
| Priority | 2 |
| Condition | Path = `/blog` OR `/blog/*` |
| Action | Forward to `test-wp` |

> **Critical:** Must include BOTH `/blog` AND `/blog/*` as OR conditions. Without `/blog` (exact), visiting `https://domain.com/blog` won't match and will fall through to the default Next.js frontend.

### HTTP:80 Listener
The existing HTTP:80 listener already has a global redirect to HTTPS:
```
Redirect to HTTPS://#{host}:443/#{path}?#{query}
Status: HTTP_301
```
This is correct — leave it as is. All HTTP traffic gets upgraded to HTTPS at the ALB level.

---

## Troubleshooting Log

This section documents every issue encountered and how it was resolved.

### Issue 1 — `unzip: command not found`
**Symptom:**
```
sudo: unzip: command not found
mv: cannot stat 'wordpress/*': No such file or directory
```
**Root Cause:** `unzip` not installed by default on Ubuntu  
**Fix:**
```bash
sudo apt install unzip -y
sudo unzip latest.zip
sudo mv wordpress/* .
sudo rm -rf wordpress latest.zip
```

### Issue 2 — MySQL Password Prompt on Fresh Install
**Symptom:** `sudo mysql -u root -p` asks for password immediately  
**Root Cause:** Ubuntu uses `auth_socket` by default — no password needed  
**Fix:** Use `sudo mysql` instead (no `-p` flag)

### Issue 3 — 502 Bad Gateway
**Symptom:** `curl -I http://localhost` returns `HTTP/1.1 502 Bad Gateway`  
**Root Cause:** Nginx config pointed to `php8.1-wordpress.sock` but PHP 8.3 was installed  
**Fix:**
```bash
sudo sed -i 's/php8.1-wordpress.sock/php8.3-wordpress.sock/' /etc/nginx/sites-available/wordpress
sudo nginx -t
sudo systemctl restart nginx  # must use restart, not reload, to fully apply socket change
```

### Issue 4 — WordPress Redirecting to HTTPS When Only HTTP is Configured
**Symptom:** `/wp-admin/` redirects to `https://...` but HTTPS isn't set up on EC2  
**Root Cause:** `$_SERVER['HTTPS'] = 'on'` was set in wp-config.php forcing all traffic to HTTPS  
**Fix:** Remove the static line and replace with dynamic detection:
```php
// Remove this:
$_SERVER['HTTPS'] = 'on';

// Replace with:
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

### Issue 5 — 404 on `preprod.example-domain.<company>.com/blog`
**Symptom:** Domain returns 404 with `x-powered-by: Next.js` header  
**Root Cause:** The request was hitting the `frontend` (Next.js) target group, not `test-wp`. The ALB `/blog` rule was missing or had wrong condition.  
**Fix:** Added rule to HTTPS:443 listener:
- Condition: Path = `/blog` OR `/blog/*`
- Action: Forward to `test-wp`

### Issue 6 — Static Files (JS/CSS) Returning 404 via /blog Path
**Symptom:**
```
open() "/var/www/wordpress/blog/wp-includes/js/dist/a11y.min.js" failed (2: No such file)
```
**Root Cause:** Static file regex block `~* \.(js|css...)` was intercepting requests before the `/blog/` rewrite could strip the prefix. Nginx was looking for files at `/var/www/wordpress/blog/...` instead of `/var/www/wordpress/...`  
**Fix:** Added `^~` prefix to `/blog/` location block. `^~` gives highest priority over regex blocks:
```nginx
# Before (broken):
location /blog/ {
    rewrite ^/blog/(.*)$ /$1 last;
}

# After (fixed):
location ^~ /blog/ {
    rewrite ^/blog/(.*)$ /$1 last;
}
```

### Issue 7 — `/blog/wp-login.php` Returns 404 but `/blog/wp-admin/` Returns 302
**Symptom:** Direct PHP files under `/blog/` path return 404, but directory-style paths work  
**Root Cause:** Using `break` flag in rewrite stopped processing after URI rewrite, preventing PHP location block from matching  
**Fix:** Changed from `break` to `last` flag:
```nginx
# Before (broken):
location /blog/ {
    rewrite ^/blog/(.*)$ /$1 break;
    try_files $uri $uri/ /index.php?$args;
}

# After (fixed):
location ^~ /blog/ {
    rewrite ^/blog/(.*)$ /$1 last;
}
```
`last` causes Nginx to restart location matching with the rewritten URI, allowing `\.php$` block to catch PHP files properly.

### Issue 8 — WordPress Showing IP Instead of Domain in Redirects
**Symptom:** `/blog/wp-admin/` redirects to `https://3.92.61.174/blog/wp-admin/` instead of the domain  
**Root Cause:** WordPress DB `siteurl` and `home` options still had old values  
**Fix:**
```bash
sudo -u wpuser wp option update siteurl 'https://preprod.example-domain.<company>.com/blog' --path=/var/www/wordpress
sudo -u wpuser wp option update home 'https://preprod.example-domain.<company>.com/blog' --path=/var/www/wordpress
```

### Issue 9 — SCP Permission Denied
**Symptom:**
```
Warning: Failed to open the file wp-cli.phar: Permission denied
curl: (23) Failure writing output to destination
```
**Root Cause:** Tried to download file directly into `/var/www/wordpress` which is owned by `wpuser`  
**Fix:** Always download to home directory first:
```bash
cd ~
curl -O https://...
sudo mv file /destination/
```

---

## Final Verification

Run these checks to confirm everything is working:

```bash
# Services
sudo systemctl status nginx
sudo systemctl status php8.3-fpm
sudo systemctl status mysql

# Socket exists
ls /run/php/php8.3-wordpress.sock

# WordPress responds locally
curl -I http://localhost/blog
curl -I http://localhost/blog/wp-login.php        # should be 302
curl -I http://localhost/blog/wp-admin/            # should be 302
curl -I http://localhost/blog/wp-includes/js/dist/a11y.min.js  # should be 200

# Via domain
curl -I https://preprod.example-domain.infinitelocus.com/blog
curl -I https://preprod.example-domain.infinitelocus.com/blog/wp-admin/

# WordPress DB options
sudo -u wpuser wp option get siteurl --path=/var/www/wordpress
sudo -u wpuser wp option get home --path=/var/www/wordpress
```

**Expected results:**

| URL | Expected |
|---|---|
| `/blog` | 301 → `/blog/` |
| `/blog/` | 200 OK |
| `/blog/wp-login.php` | 302 → login |
| `/blog/wp-admin/` | 302 → login |
| `/blog/wp-includes/js/*.js` | 200 OK |
| `siteurl` | `https://preprod.example-domain.infinitelocus.com/blog` |
| `home` | `https://preprod.example-domain.infinitelocus.com/blog` |

---

## Replication Guide for example-domain.com/blog

Use this section to set up WordPress for the main production domain on a new server in a different region. Only the differences from the preprod setup are noted — everything else is identical.

### Differences

| Setting | preprod | prod |
|---|---|---|
| Domain | `preprod.example-domain.infinitelocus.com` | `example-domain.com` |
| `WP_HOME` | `https://preprod.example-domain.infinitelocus.com/blog` | `https://example-domain.com/blog` |
| `WP_SITEURL` | same | `https://example-domain.com/blog` |
| Nginx `server_name` | `preprod.example-domain.infinitelocus.com` | `example-domain.com www.example-domain.com` |
| ALB target group | `test-wp` | `prod-wp` (create new) |
| WP core install `--url` | preprod URL | `https://example-domain.com/blog` |

### wp-config.php for Production
```php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
define('WP_HOME', 'https://example-domain.com/blog');
define('WP_SITEURL', 'https://example-domain.com/blog');
define('WP_MEMORY_LIMIT', '256M');
```

### Nginx server_name for Production
```nginx
server_name <NEW-EC2-IP> example-domain.com www.example-domain.com;
```

### WP Core Install for Production
```bash
sudo -u wpuser wp core install \
  --url="https://example-domain.com/blog" \
  --title="<website-name> Blog" \
  --admin_user="admin" \
  --admin_password="AdminPassword123!" \
  --admin_email="your@email.com" \
  --path=/var/www/wordpress
```

### URL Fix After Import for Production
```bash
sudo -u wpuser wp search-replace 'https://old-managed-host.com' 'https://example-domain.com' \
  --all-tables --path=/var/www/wordpress
sudo -u wpuser wp option update siteurl 'https://example-domain.com/blog' --path=/var/www/wordpress
sudo -u wpuser wp option update home 'https://example-domain.com/blog' --path=/var/www/wordpress
```

### ALB Rule for Production
- Create new target group: `prod-wp` (HTTP:80, register new EC2)
- Add rule to HTTPS:443 listener of production ALB:
  - Priority: 1
  - Condition: Path = `/blog` OR `/blog/*`
  - Action: Forward to `prod-wp`

---

## Quick Reference

### File Locations

| What | Path |
|---|---|
| WordPress files | `/var/www/wordpress/` |
| wp-config.php | `/var/www/wordpress/wp-config.php` |
| Uploads/media | `/var/www/wordpress/wp-content/uploads/` |
| Themes | `/var/www/wordpress/wp-content/themes/` |
| Plugins | `/var/www/wordpress/wp-content/plugins/` |
| Nginx site config | `/etc/nginx/sites-available/wordpress` |
| Nginx enabled symlink | `/etc/nginx/sites-enabled/wordpress` |
| PHP-FPM pool config | `/etc/php/8.3/fpm/pool.d/wordpress.conf` |
| PHP-FPM socket | `/run/php/php8.3-wordpress.sock` |
| Nginx error log | `/var/log/nginx/wordpress_error.log` |
| Nginx access log | `/var/log/nginx/wordpress_access.log` |
| MySQL database | `wordpress_db` |
| WP-CLI | `/usr/local/bin/wp` |

### Common Commands

```bash
# Restart all services
sudo systemctl restart nginx php8.3-fpm mysql

# Check logs
sudo tail -f /var/log/nginx/wordpress_error.log
sudo tail -f /var/log/nginx/wordpress_access.log

# WP-CLI commands
sudo -u wpuser wp option get siteurl --path=/var/www/wordpress
sudo -u wpuser wp option get home --path=/var/www/wordpress
sudo -u wpuser wp plugin list --path=/var/www/wordpress
sudo -u wpuser wp rewrite flush --path=/var/www/wordpress

# Fix permissions (run after any file changes)
sudo chown -R wpuser:www-data /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;
sudo chmod -R 775 /var/www/wordpress/wp-content

# Test Nginx config
sudo nginx -t

# Check PHP-FPM pool
grep -E "^\[|^user|^listen" /etc/php/8.3/fpm/pool.d/wordpress.conf
```

### URLs

| URL | Purpose |
|---|---|
| `https://preprod.example-domain.<company>.com/blog` | WordPress site (preprod) |
| `https://preprod.example-domain.<company>.com/blog/wp-admin` | Admin panel (preprod) |
| `https://preprod.example-domain.<company>.com/blog/wp-login.php` | Login page (preprod) |

### Credentials

| Service | Username | Notes |
|---|---|---|
| WordPress Admin | `admin` | Temporary — overwritten by .wpress import |
| MySQL DB User | `wp_user` | Access to `wordpress_db` only |
| System User | `wpuser` | No shell, owns WordPress files |
| EC2 SSH | `ubuntu` | Uses .pem key |
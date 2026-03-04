# WordPress Behind AWS ALB + Nginx — Routing, wp-admin & Favicon Setup

> **Reference Doc** | Author: Vishav Deshwal | Date: March 2026  
> **Repo Tag:** `wordpress-hacks`  
> **Applies To:** WordPress served under a subpath (`/blogs/`) behind AWS ALB + CloudFront, on an EC2 instance running Nginx + PHP-FPM

---

## Table of Contents

1. [Objective](#objective)
2. [Infrastructure Overview](#infrastructure-overview)
3. [Problem 1 — `/blogs/` returning 404 and redirecting to `/blog/`](#problem-1--blogs-returning-404-and-redirecting-to-blog)
4. [Problem 2 — `wp-admin` inaccessible, redirecting to wrong URL](#problem-2--wp-admin-inaccessible-redirecting-to-wrong-url)
5. [Problem 3 — wp-admin loads but CSS/JS missing](#problem-3--wp-admin-loads-but-cssjs-missing)
6. [Problem 4 — Favicon not set](#problem-4--favicon-not-set)
7. [Final Working Nginx Config](#final-working-nginx-config)
8. [Final wp-config.php Additions](#final-wp-configphp-additions)
9. [Key Lessons Learned](#key-lessons-learned)

---

## Objective

The goal was to:

- Serve a **WordPress blog** at `<root-domain>/blogs/` (subpath, not subdomain)
- Serve a **React frontend** at `<root-domain>/` (root)
- Route traffic correctly through **AWS CloudFront → ALB → EC2 (Nginx + PHP-FPM)**
- Make **WordPress Admin** (`<root-domain>/blogs/wp-admin/`) fully accessible with correct CSS/JS
- Set a **custom favicon** for the blog

---

## Background & Migration Context

> This section explains **why** these issues were encountered in the first place.

The WordPress blog was originally running and accessible at:
```
<root-domain>/blog      ← original path (singular)
```

A decision was made to change the public URL to:
```
<root-domain>/blogs     ← new path (plural)
```

This required changes at **three layers** simultaneously:

| Layer | What needed changing |
|---|---|
| `wp-config.php` | `WP_HOME` and `WP_SITEURL` constants |
| WordPress Database | `siteurl` and `home` options |
| AWS ALB | Listener rule path from `/blog*` to `/blogs*` |

Because these layers were not all updated consistently at the same time, a **cascade of issues** emerged in the following order:

1. **`/blogs/` returned 404** — `WP_HOME`/`WP_SITEURL` still pointed to `/blog`, so WordPress redirected all traffic back to the old path
2. **`wp-admin` became inaccessible** — once the URL was fixed, the Nginx rewrite stripped `/blogs/` before PHP received the request, causing WordPress to construct redirects without the `/blogs/` prefix
3. **wp-admin dashboard had no CSS/JS** — the Nginx `^~` block for `/blogs/wp-admin/` was intercepting static asset requests and routing them to PHP-FPM, which protected them behind authentication
4. **Favicon was missing** — had never been configured on the WordPress instance

Each of these issues is documented in detail in the sections below.

---

## Infrastructure Overview

```
User Browser
     │
     ▼
AWS CloudFront (CDN + SSL termination)
     │
     ▼
AWS Application Load Balancer (ALB)
     │
     ├── Path /blogs*        ──► wordpress-site Target Group (EC2)
     ├── Path /aboutus*      ──► aboutus Target Group
     └── Host <root-domain>    ──► PROD-tenxyou-fe Target Group (React app)
     │
     ▼
EC2 Instance (Ubuntu)
     │
     ├── Nginx (reverse proxy + static file server)
     └── PHP-FPM 8.3 (WordPress runtime)
          │
          └── WordPress installed at /var/www/wordpress
```

**Key constraint:** WordPress is installed at the server root (`/var/www/wordpress`) but must be publicly accessible under the `/blogs/` subpath. Nginx handles this by internally rewriting `/blogs/*` → `/*` before passing to PHP-FPM.

---

## Problem 1 — `/blogs/` returning 404 and redirecting to `/blog/`

### Symptom
Visiting `<root-domain>/blogs/` would 404 and redirect to:
```
https://<root-domain>/blog/2026/02/25/some-post-slug
```
Note the singular `/blog/` instead of `/blogs/`.

### Root Cause
`wp-config.php` had the WordPress home and site URL hardcoded with the wrong path:

```php
// WRONG — singular /blog instead of /blogs
define('WP_HOME', 'https://<root-domain>/blog');
define('WP_SITEURL', 'https://<root-domain>/blog');
```

`WP_HOME` and `WP_SITEURL` are the source of truth for all URL construction in WordPress. When set to `/blog`, every internally generated URL — post links, redirects, asset paths — would use `/blog/` as the base, overriding anything set in the database.

### Why These Constants Override Everything
WordPress checks `wp-config.php` constants **before** reading the database. So even if `siteurl` and `home` options in the database were correct, the hardcoded constants would win every time.

### Fix
```php
// CORRECT
define('WP_HOME', 'https://<root-domain>/blogs');
define('WP_SITEURL', 'https://<root-domain>/blogs');
```

Also verified the database values matched:
```bash
wp option get siteurl --allow-root
# https://<root-domain>/blogs ✓

wp option get home --allow-root
# https://<root-domain>/blogs ✓
```

Then flushed rewrite rules:
```bash
wp rewrite flush --hard --allow-root
```

---

## Problem 2 — `wp-admin` inaccessible, redirecting to wrong URL

### Symptom
Visiting `<root-domain>/blogs/wp-admin` redirected to `<root-domain>/wp-admin` which returned 404.

### Debugging Steps

**Step 1 — Identified where the redirect was happening:**
```bash
# Test bypassing CloudFront/ALB, hitting EC2 directly
curl -v -k https://3.6.59.24/blogs/wp-admin 2>&1 | grep -E "HTTP|[Ll]ocation"
# HTTP/1.1 301
# Location: https://3.6.59.24/wp-admin/
```
The redirect was coming from the EC2 itself — confirmed Nginx/WordPress was the culprit, not ALB or CloudFront.

**Step 2 — Simulated ALB headers:**
```bash
curl -v -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin 2>&1 | grep -E "HTTP|[Ll]ocation"
# Location: https://<root-domain>/wp-admin/
```
With correct headers, the domain was right but `/blogs/` prefix was still missing.

**Step 3 — Verified database and config were correct:**
```bash
wp option get siteurl --allow-root  # https://<root-domain>/blogs ✓
wp option get home --allow-root     # https://<root-domain>/blogs ✓
grep "WP_SITEURL\|WP_HOME" /var/www/wordpress/wp-config.php
# define('WP_HOME', 'https://<root-domain>/blogs');   ✓
# define('WP_SITEURL', 'https://<root-domain>/blogs'); ✓
```

### Root Cause
The Nginx rewrite was stripping `/blogs/` **before** PHP received the request:

```nginx
location ^~ /blogs/ {
    rewrite ^/blogs/(.*)$ /$1 last;
    # /blogs/wp-admin → /wp-admin (internally)
}
```

WordPress received the request as `/wp-admin` (without `/blogs/`). When WordPress does the trailing slash redirect (`/wp-admin` → `/wp-admin/`), it constructs the full URL using `WP_SITEURL` — but only for **authentication redirects**, not for the trailing slash 301. The trailing slash redirect uses the raw `REQUEST_URI` which at that point was already `/wp-admin`, producing `<root-domain>/wp-admin/` instead of `<root-domain>/blogs/wp-admin/`.

### Fix — Dedicated wp-admin block with correct REQUEST_URI

```nginx
location ^~ /blogs/wp-admin/ {
    rewrite ^/blogs/(wp-admin/.*)$ /$1 break;
    fastcgi_pass unix:/run/php/php8.3-wordpress.sock;
    fastcgi_param SCRIPT_FILENAME $document_root/wp-admin/index.php;
    fastcgi_param REQUEST_URI /blogs/$1;
    include fastcgi_params;
    fastcgi_read_timeout 300;
}
```

**Verification:**
```bash
curl -v -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin/ 2>&1 | grep -E "HTTP|[Ll]ocation"
# HTTP/1.1 302 Found
# Location: https://<root-domain>/blogs/wp-login.php?redirect_to=https%3A%2F%2F<root-domain>%2Fblogs%2Fwp-admin%2F&reauth=1
```
✅ Now correctly redirecting to `/blogs/wp-login.php` with the full `/blogs/` path preserved.

### ALB HTTPS Forwarding
WordPress also needed to know it was behind an HTTPS proxy. Added to `wp-config.php`:

```php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

This ensures WordPress constructs `https://` URLs instead of `http://` when behind ALB.

---

## Problem 3 — wp-admin loads but CSS/JS missing

### Symptom
After logging in, the WordPress dashboard rendered as an **unstyled HTML list** — all CSS and JS were missing. The login page itself rendered correctly.

### Debugging Steps

**Step 1 — Identified which asset types were failing:**
```bash
# CSS file — 302 (failing)
curl -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin/css/login.min.css -I 2>&1 | grep "HTTP"
# HTTP/1.1 302 Found  ✗

# wp-includes CSS — 200 (working)
curl -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-includes/css/dashicons.min.css -I 2>&1 | grep "HTTP"
# HTTP/1.1 200 OK  ✓

# load-styles.php (PHP CSS bundler) — 302 (failing)
curl -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin/load-styles.php -I 2>&1 | grep "HTTP"
# HTTP/1.1 302 Found  ✗
```

**Step 2 — Identified Nginx location block priority issue:**

The config at the time had:
```nginx
# Regex block for static assets
location ~* ^/blogs/(wp-admin|wp-includes|wp-content)/(.+\.(css|js|...))$ {
    alias /var/www/wordpress/$1/$2;
}

# Prefix block for wp-admin PHP
location ^~ /blogs/wp-admin/ {
    ...
}
```

In Nginx, **`^~` (non-regex prefix match) has higher priority than regex `~*` matches**. So `/blogs/wp-admin/css/login.min.css` was being caught by the `^~` PHP block instead of the regex static asset block. This sent CSS file requests to PHP-FPM → WordPress → which protected them behind authentication → 302 redirect.

**Step 3 — Identified `load-styles.php` issue:**

The wp-admin PHP block was hardcoding `SCRIPT_FILENAME` to `index.php`:
```nginx
fastcgi_param SCRIPT_FILENAME $document_root/wp-admin/index.php;
```

This meant `load-styles.php`, `load-scripts.php`, and every other PHP file inside `wp-admin/` were all being executed as `index.php` — causing them to fail or redirect incorrectly.

### Root Cause Summary
Two separate issues:
1. `^~` prefix blocks beat regex blocks in Nginx — CSS/JS requests hit the PHP block instead of the static file handler
2. Hardcoded `SCRIPT_FILENAME` meant only `index.php` ever ran inside `/wp-admin/`, breaking all other PHP files like `load-styles.php`

### Fix

**Replace the hardcoded wp-admin PHP block with a simple rewrite:**
```nginx
# This lets Nginx resolve the correct PHP file dynamically
# after the rewrite, the ~ \.php$ block handles execution correctly
location ^~ /blogs/wp-admin/ {
    rewrite ^/blogs/(.*)$ /$1 last;
}
```

**Why this works:**
- `/blogs/wp-admin/load-styles.php` → rewritten to `/wp-admin/load-styles.php`
- Falls through to the `location ~ \.php$` block
- `$fastcgi_script_name` resolves dynamically to the correct PHP file
- WordPress handles the request with correct `REQUEST_URI` context

**Add explicit blocks for wp-includes and wp-content too:**
```nginx
location ^~ /blogs/wp-includes/ {
    rewrite ^/blogs/(.*)$ /$1 last;
}
location ^~ /blogs/wp-content/ {
    rewrite ^/blogs/(.*)$ /$1 last;
}
```

**Verification:**
```bash
curl -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin/css/common.min.css -I 2>&1 | grep "HTTP"
# HTTP/1.1 200 OK ✓

curl -k -H "Host: <root-domain>" -H "X-Forwarded-Proto: https" \
  https://3.6.59.24/blogs/wp-admin/load-styles.php -I 2>&1 | grep "HTTP"
# HTTP/1.1 200 OK ✓
```

---

## Problem 4 — Favicon not set

### Symptom
Browser tab showed a generic globe icon instead of the Ten x You brand icon.

### Root Cause
The site icon had never been configured in WordPress.

### Fix

**Step 1 — Prepare the image**

WordPress requires a minimum **512×512px PNG** for the site icon. SVG uploads are blocked by WordPress by default for security reasons. Convert SVG to PNG using Preview on Mac:
- Open SVG in Preview → File → Export → PNG → 512×512px

**Step 2 — Upload via WordPress Admin**

Navigate to:
```
https://<root-domain>/blogs/wp-admin/media-new.php
```
Upload the PNG from your local machine.

**Step 3 — Set as Site Icon**

Navigate to:
```
https://<root-domain>/blogs/wp-admin/options-general.php
```
Under **Site Icon** → click **Change Site Icon** → select uploaded PNG → Save Changes.

**Step 4 — Invalidate CloudFront cache**

Go to AWS Console → CloudFront → Your Distribution → Invalidations → Create Invalidation:
```
/blogs/wp-content/*
/favicon.ico
```

**OR via WP-CLI (after uploading image and noting attachment ID):**
```bash
wp media import /tmp/favicon.png --allow-root
# Returns: Imported file as attachment ID 42

wp option update site_icon 42 --allow-root
wp cache flush --allow-root
```

---

## Final Working Nginx Config

```nginx
server {
    listen 80;
    listen 443 ssl;
    server_name 3.6.59.24 <root-domain> www.<root-domain> blogs.<root-domain>;
    root /var/www/wordpress;
    index index.php index.html;
    client_max_body_size 512M;

    ssl_certificate /etc/letsencrypt/live/blogs.<root-domain>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/blogs.<root-domain>/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Exact match for /blogs (no trailing slash) → WordPress index
    location = /blogs {
        rewrite ^ /index.php last;
    }

    # wp-admin static assets (CSS/JS/images) — MUST be before /blogs/wp-admin/
    # These are ^~ prefix blocks which beat other ^~ blocks by specificity
    # Without these, /blogs/wp-admin/css/* would fall into the generic
    # /blogs/wp-admin/ block and get processed as PHP → 302 auth redirect
    location ^~ /blogs/wp-admin/css/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }
    location ^~ /blogs/wp-admin/js/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }
    location ^~ /blogs/wp-admin/images/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }
    location ^~ /blogs/wp-admin/fonts/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }

    # wp-admin PHP — simple rewrite, let ~ \.php$ handle execution
    # DO NOT hardcode SCRIPT_FILENAME here — it breaks load-styles.php,
    # load-scripts.php and every other PHP file inside wp-admin/
    location ^~ /blogs/wp-admin/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }

    # wp-includes and wp-content — static assets + PHP (e.g. plugins)
    location ^~ /blogs/wp-includes/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }
    location ^~ /blogs/wp-content/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }

    # All other /blogs/* paths → WordPress frontend
    location ^~ /blogs/ {
        rewrite ^/blogs/(.*)$ /$1 last;
    }

    # Standard WordPress try_files for root
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # PHP-FPM handler — handles all .php files after rewrites resolve
    # $fastcgi_script_name resolves dynamically to the correct file
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-wordpress.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }

    # Static asset caching for files served directly (after rewrite)
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|svg|mp4)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location = /xmlrpc.php { deny all; }

    error_log /var/log/nginx/wordpress_error.log;
    access_log /var/log/nginx/wordpress_access.log;
}
```

---

## Final wp-config.php Additions

Add these **before** `/* That's all, stop editing! Happy publishing. */`:

```php
// Trust HTTPS from ALB — without this, WordPress constructs http:// URLs
// because the EC2 only receives HTTP from the load balancer internally
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

// Canonical URLs — must match exactly what users see in the browser
// These override database options — keep them in sync with the DB values
define('WP_HOME', 'https://<root-domain>/blogs');
define('WP_SITEURL', 'https://<root-domain>/blogs');
```

---

## Key Lessons Learned

### 1. Nginx location block priority order matters
```
Exact match (=)           → highest priority
Non-regex prefix (^~)     → beats regex, evaluated by specificity
Regex (~, ~*)             → evaluated in order, first match wins
Generic prefix (no ^~)    → lowest priority
```
Always place more specific `^~` blocks **before** less specific ones. A `^~` for `/blogs/wp-admin/css/` must come before `/blogs/wp-admin/` or the CSS block is never reached.

### 2. Never hardcode SCRIPT_FILENAME to a specific PHP file
```nginx
# WRONG — breaks load-styles.php, load-scripts.php, etc.
fastcgi_param SCRIPT_FILENAME $document_root/wp-admin/index.php;

# CORRECT — resolves dynamically after rewrite
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
```

### 3. WordPress behind ALB needs X-Forwarded-Proto handling
EC2 instances behind an ALB receive only HTTP internally. Without the `X-Forwarded-Proto` check, WordPress builds `http://` URLs for all redirects, breaking HTTPS sites.

### 4. WP_HOME and WP_SITEURL in wp-config.php override the database
Constants defined in `wp-config.php` always win over database options. Keep both in sync to avoid confusion:
```bash
wp option update siteurl 'https://<root-domain>/blogs' --allow-root
wp option update home 'https://<root-domain>/blogs' --allow-root
```

### 5. WordPress does not support SVG uploads by default
Use PNG (512×512px minimum) for the site icon. Convert SVG to PNG using Preview on Mac or any image editor before uploading.

### 6. Debugging redirect chains systematically
When chasing redirects, always test in this order:
```bash
# 1. Bypass everything — hit EC2 IP directly
curl -k https://<EC2-IP>/path -I

# 2. Simulate ALB headers
curl -k -H "Host: yourdomain.com" -H "X-Forwarded-Proto: https" https://<EC2-IP>/path -I

# 3. Follow the full redirect chain
curl -k -L -H "Host: yourdomain.com" -H "X-Forwarded-Proto: https" https://<EC2-IP>/path -I
```
This tells you exactly which layer (CloudFront, ALB, Nginx, or WordPress) is responsible for the redirect.

---

*Last updated: March 2026 — Vishav Deshwal*
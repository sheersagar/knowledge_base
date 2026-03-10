# Adding a New WordPress Site on a Subdirectory Path
### Server: <root-domain> production (EC2 + ALB + nginx)
> Tested and verified. Follow steps in order. No troubleshooting needed.

---

## Server Architecture (Know This First)

| Layer | Detail |
|-------|--------|
| Domain | `<root-domain>` |
| Load Balancer | AWS ALB → forwards `/path*` to `wordpress-site` target group |
| EC2 | Ubuntu, nginx, PHP 8.3-FPM, MySQL |
| WordPress files | `/var/www/<sitename>/` |
| PHP socket | `/run/php/php8.3-wordpress.sock` |
| nginx config | `/etc/nginx/sites-enabled/wordpress` |
| PHP user | `wpuser:www-data` |

**Key insight:** nginx root is `/var/www/wordpress` (for `/blogs`). Every new site gets its own directory under `/var/www/` and its own database. Never use `alias` or `fastcgi-php.conf` snippet for subdirectory WordPress installs — both break silently.

---

## Step 1 — Create Directory & Download WordPress

```bash
export SITE=newsite   # <-- change this to your site name (e.g. neverstopplaying)

sudo mkdir /var/www/$SITE
sudo chown wpuser:www-data /var/www/$SITE
cd /var/www/$SITE
sudo -u wpuser wp core download --allow-root
```

✅ Expected: `Success: WordPress downloaded.`

---

## Step 2 — Create Database & User

```bash
export SITE=newsite          # same as above
export DB_PASS=YourPass123   # choose a strong password

sudo mysql -u root -p -e "
  CREATE DATABASE ${SITE}_db;
  CREATE USER '${SITE}_user'@'localhost' IDENTIFIED BY '${DB_PASS}';
  GRANT ALL PRIVILEGES ON ${SITE}_db.* TO '${SITE}_user'@'localhost';
  FLUSH PRIVILEGES;
"
```

✅ Expected: No errors.

---

## Step 3 — Generate wp-config.php

```bash
sudo -u wpuser wp config create \
  --dbname=${SITE}_db \
  --dbuser=${SITE}_user \
  --dbpass="${DB_PASS}" \
  --dbhost=localhost \
  --path=/var/www/$SITE \
  --allow-root
```

✅ Expected: `Success: Generated 'wp-config.php' file.`

---

## Step 4 — Add HTTPS Proxy Fix to wp-config.php

This is required because ALB terminates HTTPS and forwards HTTP to nginx. Without this, WordPress will redirect loop forever.

```bash
sudo sed -i "s/\/\* That's all, stop editing! \*\//if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) \&\& \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\n    \$_SERVER['HTTPS'] = 'on';\n}\n\n\/\* That's all, stop editing! *\//" /var/www/$SITE/wp-config.php
```

Or manually add before `/* That's all, stop editing! */`:

```php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

---

## Step 5 — Install WordPress

```bash
sudo -u wpuser wp core install \
  --url="https://<root-domain>/${SITE}" \
  --title="Your Site Title" \
  --admin_user="admin" \
  --admin_password="Admin@123" \
  --admin_email="you@email.com" \
  --path=/var/www/$SITE \
  --allow-root
```

✅ Expected: `Success: WordPress installed successfully.`  
⚠️ `sendmail not found` warning is harmless — ignore it.

---

## Step 6 — Fix File Permissions

```bash
sudo chown -R wpuser:www-data /var/www/$SITE/wp-content
sudo chmod -R 755 /var/www/$SITE/wp-content
```

---

## Step 7 — Add nginx Location Blocks

Edit `/etc/nginx/sites-enabled/wordpress`:

```bash
sudo vi /etc/nginx/sites-enabled/wordpress
```

Add these **two blocks** inside the `server {}` block, **before** the global `location ~ \.php$` block:

```nginx
# ---- /newsite WordPress ---- (replace 'newsite' with your $SITE value)
location ~ ^/newsite/(.+\.php)$ {
    fastcgi_pass unix:/run/php/php8.3-wordpress.sock;
    fastcgi_param SCRIPT_FILENAME /var/www/newsite/$1;
    fastcgi_param SCRIPT_NAME /newsite/$1;
    fastcgi_param REQUEST_URI $request_uri;
    fastcgi_param QUERY_STRING $query_string;
    fastcgi_param REQUEST_METHOD $request_method;
    fastcgi_param CONTENT_TYPE $content_type;
    fastcgi_param CONTENT_LENGTH $content_length;
    fastcgi_param SERVER_NAME $server_name;
    fastcgi_param SERVER_PORT $server_port;
    fastcgi_param SERVER_PROTOCOL $server_protocol;
    fastcgi_param HTTP_HOST $http_host;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_read_timeout 300;
}
location /newsite {
    root /var/www;
    index index.php;
    try_files $uri $uri/ /newsite/index.php?$args;
}
```

Then reload:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

✅ Expected: `nginx: configuration file test is successful`

---

## Step 8 — Add ALB Listener Rule

In AWS Console → EC2 → Load Balancers → `prod-<root-domain>-fe-alb` → Listeners → HTTPS:443 → View/Edit Rules:

1. Click **Add rule**
2. **Condition:** Path is `/newsite*`
3. **Action:** Forward to `wordpress-site` target group
4. **Priority:** Set lower number than default (e.g. next available: 3, 4, 5...)
5. Save

---

## Step 9 — Verify

```bash
# Test locally first
curl -s -o /dev/null -w "%{http_code}" http://localhost/newsite/ -H "Host: <root-domain>"
# Expected: 200
```

Then open in browser: `https://<root-domain>/newsite/`  
Admin panel: `https://<root-domain>/newsite/wp-admin/`

---

## Useful WP-CLI Commands (Day-to-Day)

```bash
# List users
wp user list --path=/var/www/newsite --allow-root

# Create user
wp user create USERNAME email@example.com \
  --role=administrator \
  --user_pass='Password123' \
  --display_name='Full Name' \
  --path=/var/www/newsite \
  --allow-root

# Reset password
wp user update USERNAME --user_pass='NewPass123' --path=/var/www/newsite --allow-root

# Check site URL
wp option get siteurl --path=/var/www/newsite --allow-root
wp option get home --path=/var/www/newsite --allow-root

# Update site URL (if wrong)
wp option update siteurl 'https://<root-domain>/newsite' --path=/var/www/newsite --allow-root --skip-plugins --skip-themes
wp option update home 'https://<root-domain>/newsite' --path=/var/www/newsite --allow-root --skip-plugins --skip-themes
```

---

## Why These nginx Rules Work

**Rule 1 — PHP block** `location ~ ^/newsite/(.+\.php)$`:
- Regex captures the PHP filename as `$1` (e.g. `index.php`, `wp-login.php`)
- `SCRIPT_FILENAME` points directly to `/var/www/newsite/$1` — no ambiguity
- Does NOT use `fastcgi-php.conf` snippet — that snippet has its own `try_files` which checks against the wrong root and silently 404s
- All required FastCGI params set explicitly

**Rule 2 — Static/fallback block** `location /newsite`:
- `root /var/www` means nginx looks for files at `/var/www/newsite/...` ✅
- `try_files` checks for real files first, then falls back to `index.php` for WordPress routing
- No `alias` — alias breaks `try_files` fallback in subdirectory contexts

**Block order matters:** The PHP regex block must come before the global `location ~ \.php$` block — nginx matches regex locations in order of appearance.

---

## Troubleshooting (If Something Goes Wrong)

| Symptom | Cause | Fix |
|---------|-------|-----|
| PHP file downloads instead of executing | Wrong nginx block order or fastcgi-php.conf conflict | Ensure PHP block is before global `~ \.php$` and don't use the snippet |
| 404 from WordPress (not nginx) | WordPress doesn't recognize URL path | Check `siteurl`/`home` in DB match `https://<root-domain>/newsite` |
| Redirect loop on wp-admin | HTTPS proxy header missing | Add `X-Forwarded-Proto` check to wp-config.php (Step 4) |
| 404 from nginx | Files not found or wrong root | Check `root /var/www` and files exist at `/var/www/newsite/` |
| ALB returns 404 before hitting nginx | ALB listener rule missing | Add `/newsite*` rule in ALB (Step 8) |
| Permission errors in wp-admin | Wrong file ownership | `sudo chown -R wpuser:www-data /var/www/newsite/wp-content` |
| "Error establishing DB connection" | Wrong DB name/user or missing grant | Check wp-config.php and re-run GRANT PRIVILEGES |
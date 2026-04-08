# ERPNext / Frappe Debugging Runbook

> **Server:** TenXYou ERP (`erp.tenxyou.com`)
> **Site name:** `tenxyou`
> **Bench path:** `~/frappe-bench/frappe-bench`
> **DB:** RDS MariaDB (`erp-prod-db.cxs0iaws4vnr.ap-south-1.rds.amazonaws.com`)
> **Redis:** AWS-managed

---

## 1. Architecture Quick Reference

```
                         INTERNET
                            │
                         NGINX
                        ┌───┴───┐
                  Static Assets  Reverse Proxy
                  (CSS/JS/imgs)      │
                                 GUNICORN
                            (1 master + 17 workers)
                                    │
                         ┌──────────┼──────────┐
                      FRAPPE CODE   │          │
                      (Python)      │          │
                         │       REDIS         REDIS
                         │       CACHE         QUEUE
                         │    (sessions,     (job queue)
                         │     perms,            │
                         │     cache)        WORKERS
                         │                  ├─ 10 short
                       MariaDB              ├─  6 long
                       (data)               ├─  2 external-sync-high
                                            ├─  2 external-sync-retry
                                            ├─  2 inventory-high
                                            └─  2 inventory-retry
```

### Gunicorn Workers vs Frappe Workers

| | Gunicorn Workers (17) | Frappe Workers (24) |
|---|---|---|
| **What** | HTTP request handlers | Background job processors |
| **Talks to** | Browsers, APIs, webhooks | Redis queue → executes jobs |
| **Lifecycle** | Request in → process → respond → free | Poll queue → pick job → execute → repeat |
| **Should take** | Milliseconds to seconds | Can take minutes |
| **Managed by** | Gunicorn master process | Supervisor |

### How Sessions Work

```
1. User logs in → Frappe creates session → stores in Redis (key: "session:abc123")
2. Browser gets cookie: sid=abc123
3. Next request → browser sends cookie → Frappe asks Redis "who is abc123?"
   → Redis responds with user email → request proceeds
4. If Redis has NO entry → user = None → ValidationError: User None is disabled
```

---

## 2. Log File Map

### Which Log for Which Problem

| Symptom | Log File | Why |
|---|---|---|
| Website showing 500 / Server Error | `logs/frappe.log` | Python traceback lives here |
| Page is slow / timing out | `logs/web.log` | Request durations |
| Gunicorn worker killed / timeout | `logs/web.error.log` | Worker-level crashes (SystemExit) |
| Background job failed (email, webhook, sync) | `logs/worker.error.log` | Worker process errors |
| Scheduled task didn't run | `logs/scheduler.log` | Cron/scheduler issues |
| Site completely down / 502 | `/var/log/nginx/error.log` | Is nginx reaching gunicorn? |
| Process crash / OOM | `/var/log/supervisor/` | Per-process logs |
| PDF generation warnings | `logs/web.error.log` | CSS warnings from weasyprint (harmless) |
| Login / session issues | `logs/frappe.log` | Grep for "User None" / "SessionExpired" |
| Saleor/Shiprocket/API integration | `logs/frappe.log` (user-triggered) | |
| | `logs/worker.error.log` (background job) | |
| | `logs/web.error.log` (webhook timeout) | |

### Log File Locations

```bash
# Application logs (relative to bench directory)
logs/frappe.log          # Main error log — tracebacks
logs/web.log             # Web server request log
logs/web.error.log       # Gunicorn worker errors (SystemExit, timeouts)
logs/worker.log          # Background worker output
logs/worker.error.log    # Background worker errors
logs/scheduler.log       # Scheduled jobs

# System logs
/var/log/nginx/access.log
/var/log/nginx/error.log
/var/log/supervisor/supervisord.log
/var/log/supervisor/              # Per-process logs
```

### Note: `frappe.log_error()` vs File Logs

`frappe.log_error()` writes to the **MariaDB `tabError Log` table**, not to log files. File logs only capture tracebacks and process-level errors. To query programmatic error logs, use `bench console` or the Error Log doctype in the ERPNext UI.

---

## 3. Reading Python Tracebacks

### Rule: Always Read Bottom-Up

```
app.py line 100          ← WHERE: entry point (web request came in)
  auth.py line 44        ← HOW: the call chain (skip unless debugging deep)
    sessions.py line 314 ← HOW: intermediate step
      __init__.py line 525   ← WHO threw it
ValidationError: User None is disabled   ← WHAT: the actual error (read this FIRST)
```

### Mental Model

```
Last line               →  WHAT broke
Middle files            →  HOW it got there (skip unless debugging deep)
Any non-frappe path     →  WHO (your custom code) caused it
Top line                →  WHERE (web request? background job? scheduler?)
```

### Common Frappe Error Types

| Error | Meaning |
|---|---|
| `ValidationError` | Frappe intentionally rejected something (business logic) |
| `PermissionError` | User exists but lacks access |
| `DoesNotExistError` | DocType/record not found |
| `AuthenticationError` | Login credentials wrong |
| `User None is disabled` | No session/cookie → stale session, Redis flush, or Guest disabled |
| `pymysql.err.OperationalError` | DB connection issue |
| `ImportError` in apps/ | Missing app or broken install |
| `SystemExit: 1` | Gunicorn killed a worker (timeout exceeded) |
| `InterfaceError: (0, '')` | DB connection dropped mid-query |

### Noise to Ignore in `web.error.log`

```
WARNING Property: Unknown Property name [word-wrap]
WARNING Property: Unknown Property name [columns]
ERROR Property: Invalid value for "CSS Level 2.1" property: flex
```

These are **weasyprint** (Frappe's PDF engine) complaining about modern CSS. Fires every time someone generates a print format. Completely harmless.

---

## 4. Filtering & Pattern Matching Commands

### Finding Errors

```bash
# Top recurring errors by type
grep -oP '\w+Error: .{0,60}' logs/frappe.log | sort | uniq -c | sort -rn | head -20

# Extract unique exception types
grep -oP '\w+Error:\s.*' logs/frappe.log | cut -d: -f1 | sort | uniq -c | sort -rn

# Show ONLY errors and tracebacks (skip JSON payload noise)
grep -E "Traceback|Error:|Exception:|File \"" logs/frappe.log | tail -50

# Show complete traceback blocks (multi-line)
awk '/Traceback/,/Error:|Exception:/' logs/frappe.log | tail -100

# Full traceback for a specific error
grep -B 30 "User None is disabled" logs/frappe.log | tail -40
```

### Filtering by Time

```bash
# Errors in the last hour
HOUR=$(date +"%Y-%m-%d %H")
grep "$HOUR" logs/frappe.log | grep -E "Error:|Exception:"

# Timeline of errors (when do they spike?)
grep "Traceback" logs/frappe.log | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}' | uniq -c

# Find errors from last 24 hours
find logs/ -name "*.log" -mtime -1 -exec grep -l "ValidationError" {} \;
```

### Categorizing by Source

```bash
# DB connection issues
grep -i "operationalerror\|gone away\|lost connection" logs/*.log

# Redis/session issues
grep -c "User None\|SessionExpired\|redis.exceptions" logs/frappe.log

# Permission issues
grep -c "PermissionError\|Insufficient Permission" logs/frappe.log

# Custom code bugs (your code vs frappe core)
grep "Traceback" -A 20 logs/frappe.log | grep "apps/tenxyou\|apps/custom"

# API/integration failures
grep -E "requests\.exceptions|ConnectionError|Timeout|HTTPError" logs/frappe.log
```

### Webhook / Saleor Specific

```bash
# Webhook call frequency per hour
grep "handle_webhook" /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f1-2 | uniq -c | tail -20

# Webhook response codes (200=ok, 499=worker died)
grep "handle_webhook" /var/log/nginx/access.log | awk '{print $9}' | sort | uniq -c | sort -rn

# What code paths trigger SystemExit kills
grep -B 5 "SystemExit: 1" logs/web.error.log | grep -oP '[\w/]+\.py' | sort | uniq -c | sort -rn | head -10
```

### Live Monitoring

```bash
# Watch live errors only (ignore JSON noise)
tail -f logs/frappe.log | grep --line-buffered -E "Traceback|Error:|Exception:|WARNING"

# Colorized multi-file monitoring
multitail -ci green logs/web.log -ci red logs/frappe.log
```

### Recognizing Log Content Types

```
Starts with { or contains "doctype":     →  SKIP (request payload dump)
Says "Traceback (most recent call last)" →  READ (python exception, read bottom-up)
Says "Error:" or "Exception:"            →  READ (the conclusion/root cause)
Is a URL path like GET /api/...          →  SKIM (request log, useful for 500s)
CSS WARNING/ERROR Property               →  IGNORE (weasyprint noise)
```

---

## 5. Health Check One-Liner

Run this daily or after any incident:

```bash
echo "=== Top Errors (frappe.log) ===" && \
grep -oP '\w+Error: .{0,60}' logs/frappe.log | sort | uniq -c | sort -rn | head -10 && \
echo "=== Worker Failures ===" && \
grep -c "Traceback\|Error" logs/worker.error.log 2>/dev/null && \
echo "=== Gunicorn Kills ===" && \
grep -c "SystemExit" logs/web.error.log* 2>/dev/null && \
echo "=== Nginx 502/504s ===" && \
grep -c " 502 \| 504 " /var/log/nginx/access.log 2>/dev/null
```

---

## 6. Process Management

### Check Process Status

```bash
# All supervised processes
sudo supervisorctl status

# Gunicorn workers count (1 master + N workers)
ps aux | grep gunicorn | wc -l

# Redis status
redis-cli ping
redis-cli info memory | grep used_memory_human
redis-cli dbsize
redis-cli info server | grep uptime_in_days
```

### Session Health

```bash
# Check session expiry setting
grep -i "session_expiry" sites/tenxyou/site_config.json sites/common_site_config.json

# Check Redis memory policy (if allkeys-lru, sessions get evicted when full)
redis-cli info memory | grep -E "used_memory_human|maxmemory_human|maxmemory_policy"
```

### Gunicorn Timeout

```bash
# Find current timeout setting
grep -i timeout Procfile
grep -r "timeout" /etc/supervisor/conf.d/ 2>/dev/null
cat Procfile
```

---

## 7. Dangerous Commands — DO NOT Run on Production

### ❌ `bench clear-cache`

**This wipes ALL Redis keys including sessions.** Every logged-in user gets immediately logged out and sees "Server Error" / "User None is disabled."

### Use These Instead

```bash
# After code changes (keeps sessions alive):
bench restart

# After migrations:
bench migrate      # handles its own cache internally
bench restart      # pick up changes

# If page cache is stale:
bench --site tenxyou clear-website-cache   # page cache only, NOT sessions

# Nuclear option (only during off-hours, warn all users):
bench clear-cache
```

---

## 8. Database Quick Checks

```bash
# Connect to MariaDB
bench --site tenxyou mariadb

# Error Log table size (if bloated from frappe.log_error spam)
SELECT table_name, round(data_length/1024/1024) as size_mb, table_rows
FROM information_schema.tables
WHERE table_name = 'tabError Log';

# Truncate if huge (safe — these are debug logs, not business data)
TRUNCATE TABLE `tabError Log`;

# Check Error Log columns (varies by Frappe version)
DESCRIBE `tabError Log`;
```

---

## 9. Known Issues & Fixes (TenXYou)

### Issue: Saleor Webhook Sleep Loop

**File:** `apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py`

**Problem:** `FULFILLMENT_METADATAUPDATED` webhooks with status ≠ `RETURN_REQUESTED` enter a `time.sleep(5)` loop for 120 seconds inside a gunicorn web worker. The loop never re-checks the status (dead code). Worker gets killed by gunicorn timeout → `SystemExit: 1`.

**Impact:** ~812 worker kills/day, ~10% web capacity lost.

**Fix:** Replace the sleep loop (lines ~250-310) with an immediate return:

```python
if fulfillment_status != 'RETURN_REQUESTED':
    return {
        "status": "ignored",
        "message": f"Fulfillment status '{fulfillment_status}' is not a return request"
    }
```

**Backup before editing:**
```bash
cp apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py \
   apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py.bak.$(date +%Y%m%d)
```

### Issue: Error Log Table Bloated

**Problem:** Every webhook step writes `frappe.log_error()` to the database. Thousands of webhooks/day = millions of rows. DB queries on this table hang.

**Fix:** Truncate the table, strip debug logging from webhook.py.

### Issue: `bench clear-cache` Spam

**Problem:** Team members running `bench clear-cache` on production, wiping all user sessions.

**Fix:** Stop running it. Use `bench restart` instead. Enable bash history timestamps for accountability:

```bash
echo 'export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "' >> ~/.bashrc
```

---

## 10. Audit & Accountability

### Track Who Runs What

```bash
# Enable timestamps in bash history (add to ~/.bashrc)
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "

# Check who SSHed in recently
last -20

# Check all users' history for dangerous commands
sudo grep -r "clear-cache\|drop\|truncate\|rm -rf" /home/*/.bash_history 2>/dev/null

# Check for automated clear-cache
sudo crontab -l 2>/dev/null
crontab -l 2>/dev/null
grep -r "clear-cache" /etc/cron* 2>/dev/null
grep -r "clear-cache" ~/frappe-bench/ --include="*.sh" 2>/dev/null
```

### Recommendation: Separate SSH Users

Create individual accounts instead of sharing `ubuntu`:

```bash
sudo adduser vishav
sudo adduser dev-lead
# Each gets their own bash_history and shows up in `last`
```

---

## 11. Bench Console Quick Reference

```bash
bench --site tenxyou console
```

```python
# Check site config
frappe.conf.session_expiry

# Count records
frappe.db.count("Error Log")

# Raw SQL
frappe.db.sql("SELECT count(*) FROM `tabError Log`")

# Check table schema
frappe.db.sql("DESCRIBE `tabError Log`")
```

---

## Appendix: Log Triage Flowchart

```
START: Something went wrong
  │
  ├── User reported "Server Error" on browser?
  │     → grep "Traceback" logs/frappe.log | tail -50
  │     → Read the LAST LINE of the traceback
  │
  ├── User reported "502 Bad Gateway"?
  │     → sudo supervisorctl status (are processes running?)
  │     → tail /var/log/nginx/error.log
  │     → redis-cli ping
  │
  ├── Background job didn't complete?
  │     → grep "Error" logs/worker.error.log | tail -20
  │     → Check RQ queue: bench doctor
  │
  ├── Users getting randomly logged out?
  │     → history | grep clear-cache (did someone run it?)
  │     → redis-cli info server | grep uptime (did Redis restart?)
  │     → grep -c "SystemExit" logs/web.error.log (workers dying?)
  │
  └── Slow pages?
        → grep "handle_webhook\|slow" /var/log/nginx/access.log
        → ps aux | grep gunicorn | wc -l (how many workers available?)
```
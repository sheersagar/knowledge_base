# Playbook: ERPNext Gunicorn Worker Timeout Diagnosis

## When to use
ERP is intermittently unresponsive or "down". Server CPU and RAM look normal.
Client reports ERP not loading, usually during business hours.

---
## Background — How Gunicorn Works

Gunicorn runs 16 worker processes. Each worker handles one request at a time.
If a worker takes more than 120 seconds to finish, the master kills it and boots a new one.

```
Gunicorn Master (pid: 3059033)
    ├── Worker 1 (pid: 3121155)  ← handles request A
    ├── Worker 2 (pid: 3121156)  ← handles request B
    ├── ...
    └── Worker 16                ← handles request P

If all 16 are busy/dead → new requests get no response → ERP appears down
```

---

## Step 1 — Confirm workers are timing out

```bash
grep "$(date +%Y-%m-%d)" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep 'WORKER TIMEOUT' | wc -l
```

- `0` → workers are fine, look elsewhere (DB down, nginx issue, disk full)
- `1–20` → mild, monitor
- `20+` → active problem, continue diagnosis
- `100+` → severe, escalate immediately

For a past date replace `$(date +%Y-%m-%d)` with the date e.g. `"2026-03-26"`.

---

## Step 2 — Find which hour was worst (IST conversion: UTC + 5:30)

```bash
grep "<YYYY-MM-DD>" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep 'WORKER TIMEOUT' | awk '{print substr($2,1,2)}' | sort | uniq -c
```

Read the output:
```
104 10   ← hour 10 UTC = 15:30–16:30 IST
 77 15   ← hour 15 UTC = 20:30–21:30 IST
```

Match the worst UTC hour against the client's complaint time (subtract 5:30 from IST to get UTC).

---

## Step 3 — Confirm which endpoint is the culprit

```bash
grep "<YYYY-MM-DD>" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep 'Error handling request' | awk '{print $NF}' | sort | uniq -c | sort -rn
```

Expected output if it's the webhook issue:
```
695  /api/method/ecommerce_integrations.saleor.webhook.handle_webhook
```

- One endpoint = 90%+ of failures → problem is inside that function
- Spread across many endpoints → general server issue (DB, memory, CPU)

---

## Step 4 — Find the exact burst window (when ERP went dark)

Convert IST complaint time to UTC first. Then grep that hour:

```bash
grep "<YYYY-MM-DD> <HH-UTC>:" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep -E 'WORKER TIMEOUT|SIGKILL'
```

Look for lines where multiple workers die in the same second:
```
10:46:10 → WORKER TIMEOUT
10:46:11 → WORKER TIMEOUT
10:46:12 → WORKER TIMEOUT   ← 3 dead in 2 seconds = ERP dark
```

When you see 3+ timeouts in the same second + SIGKILL lines = that's the exact moment users saw ERP as unresponsive.

---

## Step 5 — Check if the debug code fix was applied

```bash
grep -c 'frappe.log_error' /home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py
```

- `0` → fix is applied, look for a different cause
- Any number > 0 → debug code still in production, this is the root cause

---

## Step 6 — Watch it live (if issue is currently happening)

```bash
tail -f /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep --line-buffered -E 'WORKER TIMEOUT|SIGKILL|Error handling'
```

Leave running. Each line = a worker dying. 3+ per second = users are affected right now.

---

## Understanding the Log Messages

| Message | Meaning |
|---|---|
| `[CRITICAL] WORKER TIMEOUT (pid:XXXXX)` | Worker took >120s, master sent SIGTERM — clean kill |
| `[ERROR] Worker (pid:XXXXX) was sent SIGKILL!` | Worker didn't respond to SIGTERM, master force-killed it |
| `[INFO] Booting worker with pid: XXXXX` | Replacement worker starting up |
| `"Perhaps out of memory?"` | Gunicorn's guess — **not always OOM**, in this case it's DB lock contention |

WORKER TIMEOUT → SIGTERM (polite) → if ignored → SIGKILL (force)

---

## Root Cause — This Specific Issue (TenXYou ERP)

File: `/home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py`

The `handle_webhook()` function has debug `frappe.log_error()` calls left in from development.
Each call = 1 synchronous RDS write. 41 calls = 41 DB writes per webhook request.

```
Saleor fires webhook burst
→ Each worker does 41 synchronous RDS writes
→ Multiple workers hit same RDS table simultaneously
→ Write lock contention → writes slow down
→ Workers exceed 120s timeout → SIGTERM → SIGKILL
→ All 16 workers exhausted → ERP unresponsive
→ Cycle repeats with each new webhook burst
```

**Why CPU and RAM look normal:** The server is not overloaded.
Workers are just sitting idle waiting for RDS to respond. No CPU, no RAM consumed.

---

## Fix

**Immediate (remove debug logging):**
```bash
# Confirm which lines to remove
grep -n 'frappe.log_error' /home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py
```

Remove all step-tracking `frappe.log_error()` calls. Only keep logging inside `except` blocks.

**Then deploy:**
```bash
cd /home/ubuntu/frappe-bench/frappe-bench
git pull
bench migrate
sudo supervisorctl restart all
sudo supervisorctl status   # verify all services RUNNING
```

**Verify fix worked:**
```bash
# Wait 10 minutes after restart, then check timeout count
grep "$(date +%Y-%m-%d)" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep 'WORKER TIMEOUT' | wc -l
# Should be 0 or near 0
```

---

## IST ↔ UTC Quick Reference

| Client complaint (IST) | grep for (UTC hour) |
|---|---|
| ~10:30 IST | `05:` |
| ~12:00 IST | `06:` |
| ~14:30 IST | `09:` |
| ~16:30 IST | `11:` |
| ~18:00 IST | `12:` |
| ~21:30 IST | `16:` |

Formula: IST hour - 5 = UTC hour (subtract extra 30 min if needed)

---

## Related Incidents
- `06-incidents/2026/tenxyou-erp-outage-2026-03-24.md`
- `06-incidents/2026/tenxyou-erp-outage-2026-03-26.md`

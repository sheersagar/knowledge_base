# RCA: TenXYou ERP Server Intermittent Outage
**Date:** 2026-03-24
**Severity:** P2 — Partial/intermittent outage, self-recovering
**System:** ERPNext (Frappe) on EC2 `erp-prod` (i-0b625f2bbc1955b52), ap-south-1
**Reported by:** Client complaint ~17:12 IST
**Investigated by:** Vishav Deshwal, Infinite Locus

---

## Summary

The ERP server experienced intermittent unavailability throughout the day on 2026-03-24. The primary cause was **excessive debug-level database logging inside the Saleor webhook handler**, which caused gunicorn workers to time out under load, exhausting the worker pool and making the ERP temporarily unresponsive to all users. A total of **1,074 worker timeouts** were recorded from 05:32 IST to 23:52 IST.

---

## Timeline of All Events

| Time (IST) | Time (UTC) | Event | Impact |
|---|---|---|---|
| 12:14 | 06:44 | `unattended-upgrades` triggered `systemctl daemon-reexec` → supervisord auto-restarted | ~10 sec downtime, auto-recovered |
| 14:15 | 08:45 | Team member (IP: 103.242.225.82) ran `sudo systemctl restart supervisor` manually | ~37 sec downtime |
| 05:32–23:52 | 00:02–18:22 | **1,074 gunicorn worker timeouts** on Saleor webhook endpoint (continuous all day) | Intermittent unresponsiveness, worst burst at ~17:26 IST |
| 17:22 | 11:52 | Vishav SSH'd in to investigate (via EC2 Instance Connect) | — |
| 21:58 | 16:28 | Planned deployment: `git pull + bench migrate + supervisorctl restart all` | ~8 sec downtime |

---

## Root Cause

### What broke:
File: `/home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py`

The `handle_webhook()` function contained **41 `frappe.log_error()` debug calls**, all executing synchronously inside the gunicorn web worker before the job was enqueued. Each call = 1 synchronous INSERT into `tabError Log` on RDS MariaDB.

### Failure chain:
```
Saleor fires webhook burst
→ Gunicorn assigns to worker
→ Worker executes 41 synchronous RDS INSERTs (tabError Log)
→ Multiple webhooks arrive simultaneously → all 16 workers busy with DB writes
→ Lock contention on tabError Log table → DB writes slow further
→ Workers exceed 120-second gunicorn timeout
→ Gunicorn sends SIGTERM, then SIGKILL ("Perhaps out of memory?" — misleading, not actual OOM)
→ Workers replaced → new workers hit same bottleneck
→ Cycle repeats 1,074 times throughout the day
→ During burst kills (multiple workers dying simultaneously), ERP web UI has no workers
→ Users see ERP as "down"
```

### Worst burst — 17:26–17:29 IST:
```
[11:57:30 UTC] WORKER TIMEOUT pid:2937436
[11:57:30 UTC] WORKER TIMEOUT pid:2940108
[11:57:30 UTC] WORKER TIMEOUT pid:2936903
[11:57:30 UTC] Worker pid:2940108 SIGKILL'd
[11:57:30 UTC] Worker pid:2936903 SIGKILL'd
```

### System resources — NOT the cause:
- CPU: 98%+ idle throughout the event
- Memory: Only 5.48% used (c5a.8xlarge has 64 GB)
- No OOM events in `dmesg`

---

## Secondary Events

### 12:14 IST — unattended-upgrades restarted supervisord (~10s downtime)
Ubuntu's `apt-daily-upgrade.service` triggered `systemctl daemon-reexec`. Supervisord restarted, all Frappe services auto-recovered. Fix: disable in `/etc/apt/apt.conf.d/50unattended-upgrades`.

### 14:15 IST — Manual supervisor restart (~37s downtime)
Team member SSH'd from IP `103.242.225.82`, ran `sudo systemctl restart supervisor` mid-deployment. Confirm with team who and why.

### 21:58 IST — Planned deployment (~8s downtime)
`git pull → bench migrate → supervisorctl restart all`. Clean graceful restart.

---

## Fix

Remove all step-tracking `frappe.log_error()` calls from `webhook.py`. Only keep logging inside `except` blocks.

```bash
# Confirm what needs removing
grep -n 'frappe.log_error' /home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py

# After removing, deploy:
cd /home/ubuntu/frappe-bench/frappe-bench
git pull && bench migrate && sudo supervisorctl restart all
sudo supervisorctl status

# Verify fix (wait 10 min)
grep "$(date +%Y-%m-%d)" /home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log | grep 'WORKER TIMEOUT' | wc -l
```

---

## Prevention

| Risk | Prevention |
|---|---|
| Debug code in production | Code review gate: no step-tracking `frappe.log_error()` in webhook handlers |
| Webhook handler blocking workers | Handler must only validate + enqueue. All DB work in background worker. |
| unattended-upgrades restarting services | Set `Unattended-Upgrade::Automatic-Reboot "false"` |
| No visibility into worker exhaustion | CloudWatch alarm on WORKER TIMEOUT count in web.error.log |

---

## Evidence Files (on server)
- `/var/log/syslog` — systemd daemon-reexec at 06:44 UTC
- `/var/log/auth.log` — SSH logins, sudo commands
- `/home/ubuntu/frappe-bench/frappe-bench/logs/web.error.log` — 1,074 WORKER TIMEOUT entries
- `/home/ubuntu/frappe-bench/frappe-bench/config/supervisor.conf` — 16 workers, 120s timeout

## Server Info
| Key | Value |
|---|---|
| Instance | i-0b625f2bbc1955b52 |
| Type | c5a.8xlarge (32 vCPU, 64 GB RAM) |
| DB | erp-prod-db.cxs0iaws4vnr.ap-south-1.rds.amazonaws.com |
| Cache | master.erp-prod-cache.tc40to.aps1.cache.amazonaws.com |
| Gunicorn | 16 workers, 120s timeout |

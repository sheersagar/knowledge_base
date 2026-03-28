# RCA: TenXYou ERP Outage — Recurrence
**Date:** 2026-03-26
**Severity:** P2 — Partial/intermittent outage, self-recovering
**System:** ERPNext (Frappe) on EC2 `erp-prod` (i-0b625f2bbc1955b52), ap-south-1
**Reported by:** Client complaint ~16:30 IST
**Investigated by:** Vishav Deshwal, Infinite Locus

---

## Summary

Same root cause as 2026-03-24. Fix was not deployed between incidents. **719 worker timeouts** recorded. Worst hour: 10:xx UTC (= 15:30–16:30 IST), matching the 16:30 IST client complaint.

---

## Key Metrics

| Metric | Value |
|---|---|
| Total WORKER TIMEOUT events | 719 |
| Worst UTC hour | 10:xx (= 15:30–16:30 IST) |
| Client complaint time | ~16:30 IST |
| Culprit endpoint | `/api/method/ecommerce_integrations.saleor.webhook.handle_webhook` |
| `frappe.log_error` count in webhook.py | 41 (fix NOT applied) |

---

## Root Cause

Identical to 2026-03-24. The `handle_webhook()` function still had 41 `frappe.log_error()` calls. The 2026-03-24 deployment (`git pull + bench migrate + restart`) ran but the code fix was not yet in the repository at that point.

```bash
# Confirmed during investigation:
grep -c 'frappe.log_error' .../saleor/webhook.py
# Output: 41
```

---

## Why This Recurred

The root cause analysis from 2026-03-24 identified the fix but it was not merged into the repo before the deployment. The deployment pulled code but `webhook.py` still had all 41 debug calls.

---

## Fix (same as 2026-03-24)

```bash
grep -n 'frappe.log_error' /home/ubuntu/frappe-bench/frappe-bench/apps/ecommerce_integrations/ecommerce_integrations/saleor/webhook.py
# Remove all step-tracking calls, keep only calls inside except blocks

cd /home/ubuntu/frappe-bench/frappe-bench
git pull && bench migrate && sudo supervisorctl restart all
sudo supervisorctl status
```

---

## Related
- First occurrence: `06-incidents/2026/tenxyou-erp-outage-2026-03-24.md`
- Playbook: `02-playbooks/cloud/erp-gunicorn-worker-timeout.md`

# Incident: Django BG Worker OOMKilled — Zippee Preprod
**Date:** 2026-03-26
**Severity:** P3 — Preprod only, recurring crash, no prod impact
**Cluster:** `arn:aws:eks:ap-south-1:139868136390:cluster/zfw-preprod-ind`
**Namespace:** `preprod`
**Investigated by:** Vishav Deshwal, Infinite Locus

---

## Summary

Both Django background worker pods (`django-bg-worker` and `django-bg-worker-ec`) in preprod were repeatedly OOMKilled. Root cause: `generate_report()` fetches all shipments for a date range in one query with no chunking, loading everything into Python memory at once. `django-bg-worker` had 9 restarts, `django-bg-worker-ec` had 5 restarts.

---

## Timeline

| Time (IST) | Event |
|---|---|
| 20:06 | `django-bg-worker-ec` OOMKilled mid-job (ran ~7 min) |
| 20:13 | `django-bg-worker-ec` restarted |
| 20:15 | `django-bg-worker` OOMKilled mid-job (ran ~47 min) |
| 21:01 | `django-bg-worker` restarted |

---

## Root Cause

File: `dashboard/apps/rider_admin_panel/helpers/static_payment_service.py` → `generate_report()`

```
Idle baseline:  ~125Mi
Memory limit:   1000Mi (request = limit = Guaranteed QoS → zero tolerance)
Spike caused by: generate_report() loading full queryset into RAM
Result:         OOMKill (exit code 137)
```

Both workers OOMKilled simultaneously because two report jobs queued at the same time — each worker grabbed one.

`django-bg-worker-ec` OOMKilled on just a 3-day range because the previous abandoned job left Python heap elevated (Python doesn't immediately return freed memory to OS).

---

## Why Grafana Showed Only ~128MB

Prometheus scrape interval is 30–60s. Memory spiked from 125Mi → >1000Mi and the process was killed before Prometheus captured it. **Never rely on Grafana for OOMKill diagnosis.** Use `kubectl logs --previous` instead.

Better metric: `container_memory_rss{pod=~"django-bg-worker.*", namespace="preprod"}` — tracks actual RSS, not `container_memory_working_set_bytes` which excludes page cache.

---

## Evidence Chain

```bash
# Confirm OOMKill
kubectl describe pod -n preprod <pod-name>
# Last State: Terminated, Reason: OOMKilled, Exit Code: 137

# Find what was running at kill time
kubectl logs -n preprod <pod-name> --previous | tail -10
# Last line: generate_report(..., {'created_from': '2026-03-01', 'created_to': '2026-03-31'})

# Confirm memory limit
kubectl describe deployment django-bg-worker -n preprod | grep -A4 Limits
# memory: 1000Mi (request = limit)

# Confirm healthy at idle
kubectl top pod -n preprod -l app=django-bgworker-preprod
# 125Mi at rest
```

---

## Architecture: bg-worker → ElastiCache

```
Django App (platform pod)
    │  rq_queue.enqueue(generate_report, job_id, filters)
    ▼
AWS ElastiCache (Redis)
host: preprod-india-1-001.z4inui.0001.aps1.cache.amazonaws.com:6379
    │  rq:queue:report_queue → [job1, job2, ...]
    ▼
bg-worker pod              bg-worker-ec pod
python manage.py rqworker  python manage.py rqworker
  report_queue               report_queue  ← both compete for same jobs
```

`-ec` suffix = NOT ElastiCache, likely "extended capacity". Both connect to same Redis endpoint. Both listen on same queues — horizontal scaling, which is why both OOMKilled at the same time.

---

## Worker Comparison

| | `django-bg-worker` | `django-bg-worker-ec` |
|---|---|---|
| Image | `dashboard:v0.5.226` | `dashboard:v0.5.250` |
| Memory request/limit | 1000Mi / 1000Mi | 1000Mi / 1000Mi |
| Restarts (2026-03-26) | 9 | 5 |

---

## Fix

**Immediate — raise memory limit:**
```yaml
resources:
  limits:
    memory: 2Gi
  requests:
    memory: 512Mi   # decouple so scheduling isn't blocked
```

**Permanent — chunk the report query (dev team):**
```python
# Bad — loads all into RAM
rows = list(Shipment.objects.filter(...).all())

# Good — streams in chunks
for chunk in Shipment.objects.filter(...).iterator(chunk_size=500):
    process(chunk)
```

**Alert:**
```promql
increase(kube_pod_container_status_restarts_total{
  pod=~"django-bg-worker.*", namespace="preprod"
}[1h]) > 2
```

---

## Prevention

| Risk | Prevention |
|---|---|
| Report query OOM | Chunk DB queries with `.iterator()` |
| Limit = Request | Set request < limit for burst headroom |
| Spike invisible in Grafana | Use `container_memory_rss` + 15s scrape interval for worker pods |
| Two workers OOMKill simultaneously | Separate `report_queue` into dedicated deployment with higher limit |

## Related
- Playbook: `02-playbooks/kubernetes/k8s-oomkill-debug.md`

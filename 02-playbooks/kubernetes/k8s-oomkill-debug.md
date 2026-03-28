# Playbook: Debugging OOMKilled Pods in Kubernetes

## When to use
Pod keeps restarting, Grafana shows normal memory, but `kubectl describe` shows `OOMKilled`.

---

## Step 1 — Verify current context
```bash
kubectl config current-context
```

## Step 2 — Find the crashing pod
```bash
kubectl get pods -n <namespace> -o wide
# Look for: high RESTARTS count, short AGE
```

## Step 3 — Confirm OOMKill (not app crash)
```bash
kubectl describe pod -n <namespace> <pod-name>
```
Look for:
```
Last State:  Terminated
  Reason:    OOMKilled    ← kernel killed it
  Exit Code: 137          ← always 137 for OOM, never anything else
```
- Exit 137 = OOMKill (kernel SIGKILL)
- Exit 1 = application crash
- Exit 0 = clean exit

## Step 4 — Check the memory limit it hit
```bash
kubectl describe deployment <name> -n <namespace> | grep -A4 "Limits:"
```
If `Limits.memory == Requests.memory` → Guaranteed QoS → zero tolerance, any spike = immediate kill.

## Step 5 — Find what was running at time of kill
```bash
kubectl logs -n <namespace> <pod-name> --previous | tail -20
```
The last log line before silence = the job/task that caused it.
No error, no traceback — the process was just killed mid-execution.

## Step 6 — Check current idle baseline
```bash
kubectl top pod -n <namespace> <pod-name>
```
Compare idle memory vs limit. Large gap = spike during specific task.
Small gap = slow memory leak.

---

## Why Grafana Shows Low Memory Despite OOMKill

Prometheus scrape interval is typically 30–60s. If a memory spike happens and kills the process within that window, Prometheus never captures the peak.

**Do not rely on Grafana for OOMKill diagnosis.** Use `--previous` logs instead.

**Better metric to watch:**
```promql
container_memory_rss{pod=~"<pod-name>.*", namespace="<ns>"}
```
Avoid `container_memory_working_set_bytes` — it excludes page cache and underreports actual usage.

**To catch spikes, reduce scrape interval for worker pods:**
```yaml
# In Prometheus scrape config
scrape_interval: 15s
```

---

## Common OOMKill Causes in Django/Python Workers

| Pattern | Symptom | Fix |
|---|---|---|
| Full queryset loaded at once | OOMKill on large date ranges | Use `.iterator(chunk_size=500)` |
| Python heap not released | Small job OOMKills after large job | Increase limit or restart worker after heavy jobs |
| Two jobs arrive simultaneously | Both workers OOMKill at same time | Separate heavy queue into dedicated deployment with higher limit |
| Memory leak | Restarts increase over days | Profile with `memory_profiler`, check for circular refs |

---

## Fix Templates

**Raise memory limit (quick fix):**
```yaml
resources:
  limits:
    memory: 2Gi
  requests:
    memory: 512Mi   # decouple so scheduling isn't blocked
```

**Fix bulk query (permanent fix):**
```python
# Bad — loads all into RAM
rows = list(MyModel.objects.filter(...).all())

# Good — streams in chunks
for obj in MyModel.objects.filter(...).iterator(chunk_size=500):
    process(obj)
```

**Alert on repeated restarts:**
```promql
increase(kube_pod_container_status_restarts_total{
  pod=~"<pod-name>.*",
  namespace="<namespace>"
}[1h]) > 2
```

---

## Related Incidents
- `06-incidents/2026/zippee-django-bgworker-oomkill-2026-03-26.md`

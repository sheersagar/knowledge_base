# ZFW Preprod EKS — Loki Log Aggregation Setup Documentation


---

## Table of Contents

1. [Why Loki — The Problem We Solved](#1-why-loki--the-problem-we-solved)
2. [Concepts — How Loki Works](#2-concepts--how-loki-works)
3. [Architecture — Our Setup](#3-architecture--our-setup)
4. [Loki Deployment Modes](#4-loki-deployment-modes)
5. [Pre-requisites & Validation](#5-pre-requisites--validation)
6. [Installation — Step by Step](#6-installation--step-by-step)
7. [Connecting Vector to Loki](#7-connecting-vector-to-loki)
8. [Adding Loki to Grafana](#8-adding-loki-to-grafana)
9. [Issues Faced & Resolutions](#9-issues-faced--resolutions)
10. [Memcached Caches — Why They Appeared & When You Need Them](#10-memcached-caches--why-they-appeared--when-you-need-them)
11. [Loki Storage & Retention](#11-loki-storage--retention)
12. [LogQL Query Reference](#12-logql-query-reference)
13. [Dashboards](#13-dashboards)
14. [Comparison — Loki vs CloudWatch vs ELK](#14-comparison--loki-vs-cloudwatch-vs-elk)
15. [Cleanup — Removing CloudWatch Integration](#15-cleanup--removing-cloudwatch-integration)
16. [Verification Checklist](#16-verification-checklist)
17. [Quick Reference — Common Commands](#17-quick-reference--common-commands)

---

## 1. Why Loki — The Problem We Solved

### Before Loki

The logging pipeline was:

```
Pods → Vector (DaemonSet) → CloudWatch Logs → Grafana (reads via API)
```

Problems with this approach:
- CloudWatch Logs ingestion costs $0.50/GB. At ~5GB/day, that's ~$75/month just for preprod logs.
- Grafana queries CloudWatch via API — each query takes 3-5 seconds due to network latency.
- CloudWatch Insights QL is limited compared to LogQL.
- Logs leave the cluster and go to an external AWS service — adds dependency.
- IRSA setup required (IAM role, OIDC trust, SA annotation) just for Grafana to read logs.

### After Loki

```
Pods → Vector (DaemonSet) → Loki (in-cluster, EBS storage) → Grafana (reads directly)
```

Benefits:
- Zero external costs — only EBS volume (~$4/month for 50GB).
- Grafana queries Loki directly inside the cluster — sub-second queries.
- LogQL is native to Grafana, much richer query language.
- Everything stays inside the cluster — no external dependencies.
- No IRSA needed — Loki and Grafana communicate via cluster DNS.
- Logs and metrics in the same Grafana instance, correlatable in same dashboards.

---

## 2. Concepts — How Loki Works

### 2.1 What Loki Is

Loki is a log aggregation system. Think of it as "Prometheus but for logs." Prometheus stores metrics (numbers over time), Loki stores logs (text over time). Both are queried from Grafana.

### 2.2 How Loki Stores Logs

Unlike Elasticsearch (ELK) which indexes every word in every log line, Loki only indexes **labels** (metadata). The actual log content is stored compressed without indexing.

```
Log arrives:
├── Labels: {source="dashboard", environment="preprod", region="india"}  ← indexed
└── Content: {"duration_ms": 23, "request": {"url": "GET /v1/health -> 301"}}  ← compressed, NOT indexed
```

This is why Loki is much lighter than Elasticsearch — it doesn't build massive inverted indexes. The tradeoff is that searching inside log content requires scanning (like grep), while label-based filtering is instant.

### 2.3 The Log Pipeline

```
Step 1: Log Collection (Vector)
  Pod writes to stdout/stderr
  → Vector DaemonSet on same node captures it
  → Vector parses JSON, extracts labels, cleans up fields
  → Sends to Loki via HTTP POST to /loki/api/v1/push

Step 2: Log Storage (Loki)
  Loki receives the log entry
  → Indexes the labels (source, environment, region)
  → Compresses the log content
  → Writes to disk in "chunks" (batches of compressed logs)
  → Maintains a TSDB index for label lookups

Step 3: Log Querying (Grafana)
  User writes LogQL query in Grafana
  → Grafana sends query to Loki via HTTP
  → Loki checks index: "which chunks have these labels?"
  → Reads matching chunks from disk, decompresses
  → Filters content if query has content filters (e.g., | json | duration_ms > 5000)
  → Returns results to Grafana
```

### 2.4 Key Terms

| Term | What it means |
|---|---|
| **Labels** | Key-value metadata attached to each log stream (like Prometheus labels). Example: `source="dashboard"` |
| **Stream** | A unique combination of labels. All logs with `{source="dashboard", environment="preprod"}` are one stream |
| **Chunks** | Batches of compressed log entries. Stored on disk (EBS in our case) |
| **Index** | TSDB index mapping labels → chunks. Tells Loki which chunks to read for a query |
| **TSDB** | Time Series Database — the index format Loki uses (same concept as Prometheus) |
| **LogQL** | Loki's query language. Similar to PromQL but for logs |
| **Schema** | Defines how Loki stores indexes and chunks. We use `v13` with `tsdb` store |

### 2.5 Loki vs Elasticsearch (ELK)

```
Loki  = indexes labels only, grep-like content search → lightweight, cheap
ELK   = indexes every word in every log → powerful search, expensive
```

| Aspect | Loki | Elasticsearch |
|---|---|---|
| What's indexed | Labels only | Every word in every log |
| Storage per GB of logs | ~0.1-0.3 GB (compressed + small index) | ~1.5-3 GB (full inverted index) |
| RAM requirement | 256MB - 1GB | 2GB minimum per node, 3 nodes minimum |
| Query speed (label filter) | Instant | Instant |
| Query speed (content search) | Slower (scans chunks) | Fast (uses inverted index) |
| Best for | DevOps observability with Prometheus/Grafana | Full-text search, SIEM, compliance |

---

## 3. Architecture — Our Setup

```
                    ┌──────────────────────────────────────────────────┐
                    │              Monitoring Namespace                 │
                    │                                                  │
                    │  Vector DaemonSet (x15 pods, 1 per node)        │
                    │     └── Collects pod stdout/stderr               │
                    │     └── Parses JSON, extracts source label       │
                    │     └── Sends to Loki via cluster DNS            │
                    │         POST http://loki.monitoring.svc:3100     │
                    │                     │                            │
                    │                     ▼                            │
                    │  Loki StatefulSet (1 pod, SingleBinary mode)     │
                    │     └── Receives logs via HTTP                   │
                    │     └── Indexes labels (source, env, region)     │
                    │     └── Compresses and stores chunks             │
                    │     └── Stores on 50Gi EBS volume (ebs-resize)  │
                    │     └── Retention: 7 days (168h)                │
                    │                     │                            │
                    │                     ▼                            │
                    │  Grafana StatefulSet (reads from Loki)           │
                    │     └── Data source: http://loki.monitoring:3100 │
                    │     └── Dashboard: Application Logs (Loki)       │
                    │     └── LogQL queries                            │
                    └──────────────────────────────────────────────────┘
```

### Components

| Component | Type | Pods | Storage | Purpose |
|---|---|---|---|---|
| Vector | DaemonSet | 15 (1/node) | None (stateless) | Collects and ships logs |
| Loki | StatefulSet | 1 | 50Gi EBS (ebs-resize) | Stores and indexes logs |
| Grafana | StatefulSet | 1 | 20Gi EBS (ebs-resize) | Queries and displays logs |

### Log Streams

| Stream (source label) | What it contains | Log format |
|---|---|---|
| `dashboard` | HTTP request/response logs | JSON with `request.url`, `duration_ms`, `trace_id` |
| `zorms` | Background job logs | JSON with `job_name`, `status`, `duration_ms`, `logs[]` |
| `unknown` | Logs without a source field | Various |

---

## 4. Loki Deployment Modes

Loki has three deployment modes. Understanding these is critical for choosing the right one.

### 4.1 SingleBinary (what we use)

```
Everything in one pod:
┌─────────────────────────┐
│       Loki Pod           │
│  ┌─────────────────────┐│
│  │ Ingester (writes)   ││
│  │ Querier (reads)     ││
│  │ Compactor (cleanup) ││
│  │ Index Gateway       ││
│  └─────────────────────┘│
│  Storage: local EBS disk │
└─────────────────────────┘
```

- One pod does everything
- Storage: local filesystem (EBS)
- Replication factor: 1 (no redundancy)
- Best for: preprod, dev, small clusters, < 100GB/day logs
- Limitation: can't scale horizontally, single point of failure

### 4.2 SimpleScalable (default in Helm chart)

```
Separate read and write paths:
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Write   │  │   Read   │  │ Backend  │
│ (3 pods) │  │ (3 pods) │  │ (3 pods) │
└──────────┘  └──────────┘  └──────────┘
       │              │            │
       └──────────────┼────────────┘
                      │
              ┌───────────────┐
              │  Object Store │
              │  (S3 bucket)  │
              └───────────────┘
```

- Separate read, write, backend pods (3 each = 9 pods minimum)
- Storage: S3 (object store required)
- Replication factor: 3
- Best for: production, medium scale
- Requires: S3 bucket, more resources

### 4.3 Distributed (microservices)

```
Full microservices:
Ingester, Distributor, Querier, Query Frontend, 
Query Scheduler, Index Gateway, Compactor, Ruler
(each as separate deployments)
```

- Every component runs independently
- Storage: S3
- Best for: very large scale (TB/day)
- Requires: significant infrastructure and tuning

### Why We Chose SingleBinary

| Requirement | SingleBinary | SimpleScalable |
|---|---|---|
| Preprod cluster | ✓ Perfect | Overkill |
| No S3 bucket needed | ✓ Uses EBS | ✗ Requires S3 |
| Minimal resources | ✓ 1 pod, ~256MB RAM | ✗ 9+ pods, 6GB+ RAM |
| Simple to manage | ✓ One StatefulSet | ✗ Multiple deployments |
| Cost | ~$4/month (EBS only) | ~$30+ (S3 + compute) |

---

## 5. Pre-requisites & Validation

Before installing Loki, verify:

### 5.1 Existing Log Pipeline

```bash
# Check what's collecting logs
kubectl get daemonset -n monitoring | grep vector

# Check where logs are currently going
kubectl get configmap vector -n monitoring -o yaml | grep -A20 "sinks:"

# Check Vector env vars (log group path, region)
kubectl get daemonset vector -n monitoring -o yaml | grep -A2 "BUSINESS_REGION\|ENVIRONMENT\|AWS_REGION"
```

### 5.2 Helm Repos

```bash
helm repo list | grep grafana
# If missing:
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 5.3 StorageClass

```bash
kubectl get storageclass
# Confirm ebs-resize exists with allowVolumeExpansion: true
```

### 5.4 Namespace

```bash
kubectl get namespace monitoring
# Should already exist from Prometheus setup
```

---

## 6. Installation — Step by Step

### 6.1 Pull Chart Locally

```bash
cd ~/IL_workspace/zippee  # or wherever you keep helm charts
helm pull grafana/loki --untar
cd loki
```

### 6.2 Edit values.yaml

The Loki Helm chart has a massive values file (~4400 lines). These are the exact changes needed for SingleBinary mode with EBS persistence.

**Edit 1 — Line 59: Deployment mode**

```yaml
# FROM:
deploymentMode: SimpleScalable
# TO:
deploymentMode: SingleBinary
```

**Edit 2 — Line 387: Disable multi-tenancy auth**

```yaml
# FROM:
  auth_enabled: true
# TO:
  auth_enabled: false
```

Without this, every request to Loki needs an `X-Scope-OrgID` header. Disabling simplifies everything for single-tenant preprod.

**Edit 3 — Line 425: Replication factor**

```yaml
# FROM:
    replication_factor: 3
# TO:
    replication_factor: 1
```

SingleBinary is one pod — can't replicate to 3.

**Edit 4 — Line 439: Storage type**

```yaml
# FROM:
    type: s3
# TO:
    type: filesystem
```

We're using local EBS disk, not S3.

**Edit 5 — Line ~497: Object store type (if present)**

```yaml
# FROM:
      type: s3
# TO:
      type: filesystem
```

**Edit 6 — Line ~532: Schema config**

Replace `schemaConfig: {}` with:

```yaml
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
```

This tells Loki: use TSDB for indexing, filesystem for chunk storage, v13 schema format, create a new index every 24 hours.

**Edit 7 — Line ~413: Add retention to limits_config**

Add `retention_period: 168h` under `limits_config`:

```yaml
  limits_config:
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    max_cache_freshness_per_query: 10m
    split_queries_by_interval: 15m
    query_timeout: 300s
    volume_enabled: true
    retention_period: 168h     # ← ADD THIS LINE
```

**Edit 8 — Line ~762: Disable Helm test**

```yaml
# FROM:
test:
  enabled: true
# TO:
test:
  enabled: false
```

**Edit 9 — Line ~792: Disable canary**

```yaml
# FROM:
lokiCanary:
  enabled: true
# TO:
lokiCanary:
  enabled: false
```

The Helm chart has a validation that requires canary for tests. Since we disabled tests (Edit 8), we can disable canary too.

**Edit 10 — Line 1054: Disable gateway**

```yaml
# FROM:
  enabled: true
# TO:
  enabled: false
```

Gateway is a reverse proxy in front of Loki — not needed in SingleBinary mode.

**Edit 11 — Line ~1554: SingleBinary persistence size**

```yaml
# FROM:
    size: 10Gi
# TO:
    size: 50Gi
```

**Edit 12 — Line ~1560: SingleBinary persistence StorageClass**

```yaml
# FROM:
    storageClass: null
# TO:
    storageClass: ebs-resize
```

**Edit 13 — Line ~1578: Write replicas**

```yaml
# FROM:
  replicas: 3
# TO:
  replicas: 0
```

**Edit 14 — Line ~1720: Read replicas**

```yaml
# FROM:
  replicas: 3
# TO:
  replicas: 0
```

**Edit 15 — Line ~1857: Backend replicas**

```yaml
# FROM:
  replicas: 3
# TO:
  replicas: 0
```

**Edit 16 — Line ~3669: Disable results cache**

```yaml
# FROM:
  enabled: true
# TO:
  enabled: false
```

**Edit 17 — Line ~3782: Disable chunks cache**

```yaml
# FROM:
  enabled: true
# TO:
  enabled: false
```

**Edit 18 — Line ~4422-4424: Enable retention deletes**

```yaml
# FROM:
  retention_deletes_enabled: false
  retention_period: 0
# TO:
  retention_deletes_enabled: true
  retention_period: 168h
```

### 6.3 Verify All Edits

```bash
echo "=== deploymentMode ===" && sed -n '59p' values.yaml
echo "=== auth ===" && sed -n '387p' values.yaml
echo "=== replication ===" && sed -n '425p' values.yaml
echo "=== storage type ===" && sed -n '439p' values.yaml
echo "=== gateway ===" && sed -n '1054p' values.yaml
echo "=== persistence size ===" && sed -n '1554p' values.yaml
echo "=== storageClass ===" && sed -n '1560p' values.yaml
echo "=== write replicas ===" && sed -n '1578p' values.yaml
echo "=== read replicas ===" && sed -n '1720p' values.yaml
echo "=== backend replicas ===" && sed -n '1857p' values.yaml
```

Note: Line numbers may shift slightly after edits. Use `grep -n` to find the exact lines if needed.

### 6.4 Install

```bash
helm install loki . -n monitoring
```

### 6.5 Verify

```bash
# Loki pod running
kubectl get pods -n monitoring | grep loki
# Expected: loki-0  2/2  Running

# PVC bound
kubectl get pvc -n monitoring | grep loki
# Expected: data-loki-0  Bound  50Gi

# StatefulSet ready
kubectl get statefulset -n monitoring | grep loki
# Expected: loki  1/1

# No cache or canary pods
kubectl get pods -n monitoring | grep -E "cache|canary"
# Expected: no output
```

### 6.6 Upgrade After Changes

```bash
cd ~/IL_workspace/zippee/loki
# Edit values.yaml
helm upgrade loki . -n monitoring
```

---

## 7. Connecting Vector to Loki

### 7.1 The Change

Vector was sending logs to CloudWatch. We change the sink from `aws_cloudwatch_logs` to `loki`.

### 7.2 Before (CloudWatch sink)

```yaml
sinks:
  cloudwatch_logs:
    type: aws_cloudwatch_logs
    compression: gzip
    create_missing_stream: true
    encoding:
      codec: json
    group_name: /applications/${BUSINESS_REGION}/${ENVIRONMENT}
    inputs:
    - clean_logs
    region: ${AWS_REGION}
    stream_name: '{{ source }}'
```

CloudWatch doesn't need an explicit endpoint — the AWS SDK resolves it from the `region` field internally (`logs.ap-south-1.amazonaws.com`).

### 7.3 After (Loki sink)

```yaml
sinks:
  loki:
    type: loki
    inputs:
    - clean_logs
    endpoint: http://loki.monitoring.svc.cluster.local:3100
    labels:
      source: '{{ source }}'
      environment: '${ENVIRONMENT}'
      region: '${BUSINESS_REGION}'
    encoding:
      codec: json
```

Key differences:
- `type` changes from `aws_cloudwatch_logs` to `loki`
- Explicit `endpoint` pointing to Loki's in-cluster service DNS
- `labels` replace `group_name`/`stream_name` — these become Loki labels for querying
- No AWS credentials needed — Loki is inside the cluster

### 7.4 How to Apply

The ConfigMap must have correct YAML indentation. Inside the `vector.yaml: |` block, all content is indented relative to the pipe character.

```
4 spaces  → top level keys (sinks, sources, transforms)
6 spaces  → sink name (loki)
8 spaces  → sink properties (type, inputs, endpoint, labels, encoding)
10 spaces → nested properties (source, environment, codec)
```

**Important:** Use spaces, never tabs. YAML rejects tabs. This was the most common error during setup.

Apply the ConfigMap:

```bash
kubectl apply -f cm_vector_loki.yaml
```

Restart Vector to pick up the new config:

```bash
kubectl rollout restart daemonset vector -n monitoring
```

Verify all 15 pods restart:

```bash
kubectl get pods -n monitoring | grep vector
```

### 7.5 The Sources and Transforms Stay the Same

The `sources` and `transforms` sections are unchanged. Vector still collects `kubernetes_logs`, parses JSON, extracts the `source` field, and cleans up metadata. Only the destination (sink) changed.

```yaml
sources:
  k8s_logs:
    type: kubernetes_logs        # ← unchanged, collects from all pods
transforms:
  clean_logs:
    inputs:
    - k8s_logs
    source: |                    # ← unchanged, same parsing logic
      parsed, err = parse_json(.message)
      if err == null && is_object(parsed) {
          . = merge!(., parsed)
      }
      if !exists(.source) || is_null(.source) {
        .source = "unknown"
      }
      del(.kubernetes)
      del(.message)
      del(.file)
      del(.source_type)
      del(.stream)
    type: remap
sinks:
  loki:                          # ← only this changed
    ...
```

---

## 8. Adding Loki to Grafana

### 8.1 Add Data Source

Go to Connections → Data sources → Add → Loki:
- **URL:** `http://loki.monitoring.svc.cluster.local:3100`
- **No authentication needed** — both are in the same cluster, auth is disabled
- Click **Save & Test**
- Expected: "Data source successfully connected"

### 8.2 Test in Explore

Go to Explore → select Loki → switch to Code mode → run:

```logql
{source="dashboard"} | json
```

Should return HTTP request logs from the dashboard service.

### 8.3 No IRSA Needed

Unlike CloudWatch, Loki doesn't need IAM roles. Grafana talks to Loki via cluster-internal DNS. No OIDC, no trust policies, no service account annotations. This is one of the key simplifications.

---

## 9. Issues Faced & Resolutions

### 9.1 Schema Config Missing

**Error:**

```
Error: INSTALLATION FAILED: You must provide a schema_config for Loki
```

**Cause:** The Helm chart ships with `schemaConfig: {}` (empty). Loki requires a schema config to know how to store data.

**Fix:** Added schema config in values.yaml:

```yaml
schemaConfig:
  configs:
    - from: "2024-04-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
```

**Lesson:** The Helm chart intentionally leaves this empty because schema config is unique per deployment. Always set it.

### 9.2 Chunks Cache Can't Schedule (9.8GB RAM)

**Error:**

```
Warning  FailedScheduling  0/15 nodes are available: 8 Insufficient memory
```

**Cause:** The default values.yaml enables Memcached chunks-cache requesting 9.8GB RAM. No node had that much free memory.

**Fix:** Disabled chunks-cache, results-cache, and canary. See Section 10 for full explanation.

### 9.3 Helm Test Requires Canary

**Error:**

```
Error: UPGRADE FAILED: Helm test requires the Loki Canary to be enabled
```

**Cause:** The chart's `validate.yaml` template checks: if canary is disabled but test is enabled, fail. We disabled canary but left test enabled.

**Fix:** Disabled both `test.enabled: false` and `lokiCanary.enabled: false`.

### 9.4 Vector ConfigMap YAML Indentation

**Error:**

```
error converting YAML to JSON: yaml: line 8: found a tab character where an indentation space is expected
```

**Cause:** When editing the Vector ConfigMap inline with `kubectl edit`, indentation broke. The `vector.yaml: |` block requires exact spacing — tabs are rejected.

**Fix:** Created the ConfigMap as a file with correct indentation and applied with `kubectl apply -f`. This is safer than inline editing for multi-line YAML blocks.

**Lesson:** For ConfigMaps with embedded YAML (the `|` pipe syntax), always edit as a file, not inline. The pipe block treats everything as a string, and indentation must be consistent with spaces only.

### 9.5 Storage Type Set to S3

**Cause:** Default values.yaml sets `type: s3` for storage. We're using filesystem (EBS), not S3.

**Fix:** Changed `type: s3` to `type: filesystem` in two places (line 439 and line 497).

**Lesson:** Always check storage type when switching to SingleBinary mode. The defaults assume SimpleScalable with S3.

---

## 10. Memcached Caches — Why They Appeared & When You Need Them

### 10.1 What Are They

The Loki Helm chart installs two Memcached instances by default:

| Component | What it caches | Default RAM | Purpose |
|---|---|---|---|
| **chunks-cache** | Recently accessed log content | 9.8 GB | Avoid re-reading chunks from disk |
| **results-cache** | Recent query results | ~1-2 GB | Avoid re-processing repeated queries |

Both are StatefulSets running `memcached` containers with Prometheus exporters.

### 10.2 How Caching Works

```
Without cache:
  Query → Loki reads chunks from EBS disk → decompresses → returns
  (Every query hits disk, slower for repeated queries)

With cache:
  First query → Loki reads from disk → stores in Memcached → returns
  Second identical query → Loki checks Memcached → data in RAM → returns instantly
  (Repeated queries are fast, disk I/O reduced)
```

### 10.3 Why We Don't Need Them

For preprod:
- **Log volume is small** — 3 streams, few GB per day
- **Query frequency is low** — one or two people checking dashboards
- **EBS is fast** — gp3 SSD, 3000 IOPS baseline, queries complete in milliseconds even without cache
- **Resources are limited** — chunks-cache alone wants 9.8GB RAM, which no node can provide
- **Complexity** — two extra StatefulSets to manage, monitor, and troubleshoot

The cache makes a noticeable difference only when:
- Log volume: 100+ GB/day
- Query concurrency: 10+ users querying simultaneously
- Query patterns: same dashboards refreshed every 30 seconds by multiple people
- Disk: slow storage where caching offloads I/O pressure

### 10.4 When to Enable Them

Enable caches when moving to production or when you notice:
- Grafana log queries taking > 5 seconds
- Loki pod CPU spiking on repeated queries
- Multiple users querying the same time ranges simultaneously

To enable in the future:

```yaml
# In values.yaml
chunksCache:
  enabled: true
  # Reduce RAM from default 9.8GB to something your nodes can handle
  allocatedMemory: 2048  # 2GB
  
resultsCache:
  enabled: true
  allocatedMemory: 1024  # 1GB
```

Then `helm upgrade loki . -n monitoring`.

### 10.5 What About the Canary

`lokiCanary` is not a cache — it's a testing DaemonSet that writes dummy logs to Loki and verifies they can be read back. It's useful for monitoring Loki's health but runs 1 pod per node (15 pods in our case), which is wasteful for preprod.

Enable it in production if you want automated Loki health monitoring.

---

## 11. Loki Storage & Retention

### 11.1 What Gets Stored

Loki stores two things on the EBS volume:

```
/var/loki/
├── tsdb-shipper-active/     ← Index files (which labels map to which chunks)
├── tsdb-shipper-cache/      ← Cached index data
├── chunks/                  ← Compressed log data
└── compactor/               ← Compaction state
```

### 11.2 Retention

Retention is set in two places (both needed):

```yaml
# In limits_config (application-level)
limits_config:
  retention_period: 168h     # 7 days

# In tableManager (cleanup-level)
retention_deletes_enabled: true
retention_period: 168h       # 7 days
```

Loki's compactor automatically deletes data older than 7 days. No manual cleanup needed.

### 11.3 Storage Estimation

| Factor | Value |
|---|---|
| Log volume per day | ~2-5 GB (estimated, 15 nodes, ~30 pods) |
| Compression ratio | ~10:1 (Loki compresses well) |
| Stored per day | ~0.2-0.5 GB |
| 7 day retention | ~1.5-3.5 GB |
| 50 GB volume | Enough for ~100+ days (massive headroom) |

### 11.4 Monitoring Storage

The EBS Volume Usage panel in the Cluster & Node Health Grafana dashboard tracks Loki's PVC usage. Also:

```bash
kubectl exec -it loki-0 -n monitoring -- df -h /var/loki
```

### 11.5 Expanding Storage

If ever needed (unlikely with 50GB and 7 day retention):

```bash
kubectl edit pvc data-loki-0 -n monitoring
# Change spec.resources.requests.storage to larger value
```

The `ebs-resize` StorageClass supports online expansion — no downtime.

---

## 12. LogQL Query Reference

### 12.1 Basic Queries

```logql
# All logs from dashboard service
{source="dashboard"}

# All logs from zorms
{source="zorms"}

# All logs from all sources
{source=~".+"}

# Parse JSON fields
{source="dashboard"} | json
```

### 12.2 Filtering

```logql
# HTTP 5xx errors
{source="dashboard"} | json | request_url=~".*-> 5.*"

# HTTP 4xx errors
{source="dashboard"} | json | request_url=~".*-> 4.*"

# Failed zorms jobs
{source="zorms"} | json | status!="finished"

# Slow requests (> 5 seconds)
{source="dashboard"} | json | duration_ms > 5000

# Text search (grep-like)
{source=~".+"} |~ "(?i)(error|exception|traceback)"

# Exclude health checks
{source="dashboard"} | json | request_url!~".*health.*"
```

### 12.3 Aggregations (for graphs)

```logql
# Log volume over time by source
sum(count_over_time({source=~".+"} [1m])) by (source)

# Error count over time
sum(count_over_time({source="dashboard"} | json | request_url=~".*-> [45].*" [1m]))

# Average response time
avg_over_time({source="dashboard"} | json | unwrap duration_ms [1m])

# Max response time
max_over_time({source="dashboard"} | json | unwrap duration_ms [1m])

# Job failure rate
sum(count_over_time({source="zorms"} | json | status!="finished" [5m]))
```

### 12.4 LogQL vs CloudWatch Insights QL

| Task | CloudWatch Insights | LogQL |
|---|---|---|
| Filter by field | `filter request.url like /-> 5/` | `\| json \| request_url=~".*-> 5.*"` |
| Count over time | `stats count(*) by bin(5m)` | `count_over_time({...} [5m])` |
| Average metric | `stats avg(duration_ms)` | `avg_over_time({...} \| unwrap duration_ms [5m])` |
| Text search | `filter @message like /error/` | `{...} \|~ "error"` |
| Parse JSON | Not needed (auto-parsed) | `\| json` (explicit parse step) |

---

## 13. Dashboards

### 13.1 Application Logs Dashboard (Loki)

Imported via JSON file: `zfw-loki-application-logs-dashboard.json`

14 panels across 5 sections:

| Section | Panels |
|---|---|
| **Overview** | Total log volume (stacked by service), Error rate (HTTP + job failures) |
| **HTTP Errors** | 5xx over time, 4xx over time, Recent HTTP error logs |
| **Performance** | Avg/max response time, Request volume, Slow requests (>5s) |
| **Zorms Jobs** | Job failures over time, Job duration, Slow jobs, Failed job logs |
| **Log Search** | All logs (filterable by service dropdown), Error-level logs (regex match) |

Features:
- Service dropdown filter at top — affects all panels
- Log panels are expandable — click to see all JSON fields
- Auto-refresh every 30 seconds

### 13.2 Updating Data Source UID

The dashboard JSON has the Loki UID hardcoded (`dfhncx8xlk8aob`). If redeploying on a different cluster, update the UID:

1. Find your Loki UID: Connections → Data sources → Loki → UID in URL
2. Find-and-replace in the JSON file: old UID → new UID
3. Import

---

## 14. Comparison — Loki vs CloudWatch vs ELK

| Factor | Loki (current) | CloudWatch (previous) | ELK Stack |
|---|---|---|---|
| **Monthly cost** | ~$4 (EBS only) | ~$75+ (ingestion + storage) | ~$50+ (3 ES nodes + EBS) |
| **Query speed** | Sub-second | 3-5 seconds | Sub-second |
| **Setup complexity** | Medium (Helm + values) | Medium (IRSA + IAM) | High (ES cluster management) |
| **Maintenance** | Low (single pod) | Zero (managed) | High (shards, indexes, upgrades) |
| **Grafana integration** | Native (LogQL) | Plugin (CloudWatch) | Plugin (Elasticsearch) |
| **Full-text search** | Basic (regex/grep) | Basic (Insights QL) | Excellent (inverted index) |
| **Retention** | Configurable (we set 7d) | Unlimited (pay per GB) | Configurable |
| **Scalability** | Vertical (SingleBinary) or horizontal (SimpleScalable) | Unlimited (managed) | Horizontal (add nodes) |
| **Data location** | Inside cluster (EBS) | AWS managed (external) | Inside cluster (EBS) |

---

## 15. Cleanup — Removing CloudWatch Integration

After confirming Loki works, remove the CloudWatch pieces:

### 15.1 Remove CloudWatch Data Source from Grafana

Connections → Data sources → cloudwatch → Delete

### 15.2 Remove IAM Role and Policy

```bash
# Detach policy from role
aws iam detach-role-policy \
  --role-name GrafanaCloudWatchRole \
  --policy-arn arn:aws:iam::139*******90:policy/GrafanaCloudWatchRead \
  --profile <profile-name>

# Delete role
aws iam delete-role --role-name GrafanaCloudWatchRole --profile zippee_vishv

# Delete policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::139*******90:policy/GrafanaCloudWatchRead \
  --profile <profile-name>
```

### 15.3 Remove SA Annotation

```bash
kubectl annotate serviceaccount prometheus-grafana -n monitoring eks.amazonaws.com/role-arn-
```

### 15.4 Delete Old CloudWatch Dashboard

In Grafana, delete the "ZFW Preprod - Application Observability" dashboard (the CloudWatch-based one).

### 15.5 Optionally Delete CloudWatch Log Group

```bash
aws logs delete-log-group \
  --log-group-name /applications/india/preprod \
  --region ap-south-1 \
  --profile zippee_vishv
```

Only do this if no other system reads from this log group.

---

## 16. Verification Checklist

### Loki

- [ ] `loki-0` pod running: `kubectl get pods -n monitoring | grep loki`
- [ ] PVC bound: `kubectl get pvc -n monitoring | grep loki`
- [ ] No cache/canary pods: `kubectl get pods -n monitoring | grep -E "cache|canary"` returns empty
- [ ] Loki is healthy: `kubectl logs loki-0 -n monitoring | tail -5` (no errors)

### Vector

- [ ] All 15 Vector pods running with new config: `kubectl get pods -n monitoring | grep vector`
- [ ] Sink is loki: `kubectl get cm vector -n monitoring -o yaml | grep "type: loki"`
- [ ] Endpoint is correct: `kubectl get cm vector -n monitoring -o yaml | grep endpoint`
- [ ] No errors in Vector logs: `kubectl logs $(kubectl get pods -n monitoring -l app.kubernetes.io/name=vector -o name | head -1) -n monitoring | tail -10`

### Grafana

- [ ] Loki data source connected: Connections → Data sources → Loki → Save & Test → success
- [ ] Logs visible in Explore: `{source="dashboard"} | json` returns results
- [ ] Dashboard imported and showing data
- [ ] Service dropdown works in dashboard

### End-to-End Test

- [ ] Generate a log from a pod: `kubectl exec -it <any-preprod-pod> -n preprod -- curl localhost:8000/v1/health`
- [ ] Wait 10 seconds
- [ ] Query in Grafana: `{source="dashboard"} | json | request_url=~".*health.*"` shows the request

---

## 17. Quick Reference — Common Commands

```bash
# Loki pod status
kubectl get pods -n monitoring | grep loki

# Loki logs (check for errors)
kubectl logs loki-0 -n monitoring --tail=20

# Loki storage usage
kubectl exec -it loki-0 -n monitoring -- df -h /var/loki

# Vector config check
kubectl get cm vector -n monitoring -o yaml | grep -A15 "sinks:"

# Restart Vector after config change
kubectl rollout restart daemonset vector -n monitoring

# Loki PVC status
kubectl get pvc -n monitoring | grep loki

# Helm release info
helm list -n monitoring | grep loki

# Upgrade Loki after values.yaml change
cd ~/IL_workspace/zippee/loki && helm upgrade loki . -n monitoring

# Check what labels Loki has
kubectl exec -it loki-0 -n monitoring -- wget -qO- http://localhost:3100/loki/api/v1/labels

# Check log streams
kubectl exec -it loki-0 -n monitoring -- wget -qO- "http://localhost:3100/loki/api/v1/label/source/values"

# Test Loki endpoint from inside cluster
kubectl run test-loki --rm -it --image=busybox --restart=Never -- wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready
```
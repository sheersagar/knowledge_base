# ZFW Preprod EKS — Observability Stack Setup Documentation

**Cluster:** zfw-preprod-ind  
**Region:** ap-south-1  
**Account:** 139868136390  
**Date:** 26 March 2026  
**Author:** Vishav Deshwal  

---

## Table of Contents

1. [Pre-requisites & Validation](#1-pre-requisites--validation)
2. [Kubeconfig Setup](#2-kubeconfig-setup)
3. [OIDC Provider Mapping](#3-oidc-provider-mapping)
4. [Helm Repository Setup](#4-helm-repository-setup)
5. [StorageClass Validation](#5-storageclass-validation)
6. [Installing kube-prometheus-stack](#6-installing-kube-prometheus-stack)
7. [Issues Faced & Resolutions](#7-issues-faced--resolutions)
8. [Grafana Ingress Setup](#8-grafana-ingress-setup)
9. [CloudWatch Logs Integration](#9-cloudwatch-logs-integration)
10. [Grafana Dashboards](#10-grafana-dashboards)
11. [Verification Checklist](#11-verification-checklist)

---

## 1. Pre-requisites & Validation

Before starting, validate the following. Each check prevents backtracking later.

### 1.1 Cluster Access

```bash
# Confirm you're on the correct cluster
kubectl config current-context
# Expected: arn:aws:eks:ap-south-1:139*****6390:cluster/<cluster-name>

# Verify nodes are reachable
kubectl get nodes
# Expected: 15 nodes in Ready state
```

### 1.2 AWS Profile

```bash
# Confirm the correct AWS profile is configured in kubeconfig
cat ~/.kube/config | grep -A5 "<cluster-name>" | grep AWS_PROFILE
# Expected: value should be set (e.g., <profile-name>)
```

**Issue we hit:** The kubeconfig entry for <cluster-name> had `env: null` — missing `AWS_PROFILE`. This causes authentication failures. Always verify the env block exists.

### 1.3 EBS CSI Driver

```bash
# Confirm EBS CSI driver is running
kubectl get pods -n kube-system | grep ebs-csi
# Expected: ebs-csi-controller (2 pods) + ebs-csi-node DaemonSet (1 per node)

# Confirm StorageClass exists
kubectl get storageclass
# Expected: ebs-resize (or similar) with provisioner ebs.csi.aws.com
```

### 1.4 ALB Ingress Controller

```bash
# Confirm ALB controller is running
kubectl get pods -n kube-system | grep aws-load-balancer
# Expected: 2 pods running

# Check existing ingress for reference (annotations, subnets, security groups)
kubectl get ingress -A -o yaml
```

### 1.5 Existing Monitoring Components

```bash
# Check if any monitoring is already deployed
helm list -A | grep -i "prom\|grafana\|monitor\|vector\|loki"
kubectl get pods -A | grep -i "prom\|grafana\|vector"
```

**What we found:** Vector was already running as a DaemonSet (15 pods) in the monitoring namespace, shipping logs to CloudWatch. This meant we didn't need Promtail/Loki for log collection.

### 1.6 OIDC Provider

```bash
# Get cluster OIDC issuer
aws eks describe-cluster \
  --name <cluster-name> \
  --region ap-south-1 \
  --profile <your-profile> \
  --query "cluster.identity.oidc.issuer" \
  --output text

# Confirm it's registered in IAM
aws iam list-open-id-connect-providers --profile <your-profile> | grep <OIDC_ID>
```

This is needed later for IRSA (IAM Roles for Service Accounts) when connecting Grafana to CloudWatch.

---

## 2. Kubeconfig Setup

### 2.1 Generate kubeconfig from EKS

Always generate kubeconfig from the cluster rather than manually editing. This ensures correct endpoint, CA cert, and auth config.

```bash
aws eks update-kubeconfig \
  --name <cluster-name> \
  --region ap-south-1 \
  --profile <your-profile>
```

### 2.2 Verify connectivity

```bash
kubectl config use-context arn:aws:eks:ap-south-1:13*****6390:cluster/<cluster-name>
kubectl get pods -A
```

### 2.3 Common issues

**"no such host" error:** Either the cluster API endpoint is private-only (check EKS > Networking tab), or kubeconfig has stale endpoint. Fix: regenerate kubeconfig with `aws eks update-kubeconfig`.

**"env: null" in kubeconfig:** The user entry is missing `AWS_PROFILE`. Add it:

```yaml
env:
- name: AWS_PROFILE
  value: <your-profile>
```

---

## 3. OIDC Provider Mapping

Each EKS cluster has a unique OIDC provider. The OIDC ID matches the hash in the cluster's API server endpoint.

### 3.1 Map all clusters to OIDC IDs

```bash
for c in $(aws eks list-clusters --region ap-south-1 --profile <your-profile> --query "clusters[]" --output text); do
  echo "$c → $(aws eks describe-cluster --name $c --region ap-south-1 --profile <your-profile> --query 'cluster.identity.oidc.issuer' --output text)"
done
```

### 3.2 Check IAM roles trusting an OIDC provider

```bash
aws iam list-roles --profile <your-profile> --output json | grep -B5 "<OIDC_ID>"
```

### 3.3 Inspect a role's trust policy and permissions

```bash
# Trust policy (who can assume it)
aws iam get-role --role-name <role-name> --profile <your-profile> --query "Role.AssumeRolePolicyDocument"

# Attached managed policies
aws iam list-attached-role-policies --role-name <role-name> --profile <your-profile>

# Inline policies
aws iam list-role-policies --role-name <role-name> --profile <your-profile>
```

---

## 4. Helm Repository Setup

### 4.1 Add repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 4.2 Verify

```bash
# Shows added repos (NOT installed releases)
helm repo list

# Shows installed releases across all namespaces
helm list -A
```

**Note:** `helm list` (without `-A`) defaults to the `default` namespace. Always use `-A` to see everything.

---

## 5. StorageClass Validation

This is a critical pre-check. Without a valid StorageClass, PVCs will stay Pending and pods won't start.

### 5.1 List available StorageClasses

```bash
kubectl get storageclass
```

Our output:

```
NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
ebs-resize   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true
gp2          kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   false
```

**We chose `ebs-resize`** because it uses the CSI driver (not the legacy in-tree provisioner), supports volume expansion, and was already proven working (Redis PVCs use it).

### 5.2 Check if a default StorageClass is set

```bash
kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

**Issue we hit:** No default StorageClass was set. The Helm chart created PVCs without specifying a StorageClass, so the provisioner never kicked in and PVCs stayed Pending.

### 5.3 Option A: Set a default (one-time, cluster-wide)

```bash
kubectl patch storageclass ebs-resize -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 5.4 Option B: Specify StorageClass in Helm values (what we did)

Explicitly set `storageClassName: ebs-resize` in the values file. See section 6.

---

## 6. Installing kube-prometheus-stack

### 6.1 Create namespace

```bash
kubectl create namespace monitoring
```

### 6.2 Pull chart locally

This lets you edit values.yaml directly before installing.

```bash
helm pull prometheus-community/kube-prometheus-stack --untar
cd kube-prometheus-stack
```

### 6.3 Edit values.yaml

Three changes required:

**Change 1 — Disable Alertmanager (line ~388):**

```yaml
alertmanager:
  enabled: false
```

Without this, Alertmanager creates a PVC without StorageClass and gets stuck.

**Change 2 — Uncomment Grafana persistence (line ~1421-1431):**

```yaml
  persistence:
    enabled: true
    type: sts
    storageClassName: "ebs-resize"
    accessModes:
      - ReadWriteOnce
    size: 20Gi
    finalizers:
      - kubernetes.io/pvc-protection
```

Without persistence, Grafana dashboards and config are lost on pod restart.

**Change 3 — Uncomment Prometheus storageSpec (line ~4462-4472):**

```yaml
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ebs-resize
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
```

**Critical:** Do NOT include `selector: {}` — the EBS CSI driver doesn't support selectors and will throw `claim Selector is not supported`.

### 6.4 Install

```bash
helm install prometheus . -n monitoring
```

`prometheus` is the release name — can be anything. Referenced later for upgrades/uninstalls.

### 6.5 Verify

```bash
# All pods running
kubectl get pods -n monitoring

# PVCs bound
kubectl get pvc -n monitoring

# PVs created
kubectl get pv
```

Expected pods:
- prometheus-grafana-0 (StatefulSet, 3/3)
- prometheus-kube-prometheus-operator (Deployment, 1/1)
- prometheus-kube-state-metrics (Deployment, 1/1)
- prometheus-prometheus-kube-prometheus-prometheus-0 (StatefulSet, 2/2)
- prometheus-prometheus-node-exporter (DaemonSet, 1 per node)
- vector (DaemonSet, pre-existing, 1 per node)

### 6.6 Upgrade after changes
 
Editing `values.yaml` on your laptop does NOT auto-sync to the cluster. You must explicitly apply changes:
 
```bash
cd ~/kube-prometheus-stack
# Edit values.yaml
helm upgrade prometheus . -n monitoring
```
 
`helm upgrade` compares your values.yaml with what's currently deployed, generates new Kubernetes manifests, and applies the differences. Pods that need changes get rolling-restarted automatically.
 
```
values.yaml (on your laptop) → helm upgrade → Kubernetes manifests → applied to cluster
```
 
Nothing happens until you run `helm upgrade`.
 
### 6.7 Storage Deep Dive — What Gets Stored Where
 
Two EBS volumes are created. Each serves a different purpose:
 
**Prometheus Volume (50Gi EBS) — mounted at `/prometheus`:**
 
This stores the TSDB (time-series database) — all the metrics Prometheus scrapes from nodes, pods, kube-state-metrics, etc. This is the actual metrics data (CPU, memory, restarts, etc.) that powers the Grafana dashboards.
 
**Grafana Volume (20Gi EBS) — mounted at `/var/lib/grafana/`:**
 
This stores Grafana's SQLite database (`grafana.db`) which contains:
- Data source configurations (Prometheus, CloudWatch connections)
- All dashboards (imported and custom-built)
- Users, passwords, org settings
- Preferences, starred dashboards, annotations
- Plugin data, snapshots
 
Without this persistent volume, every pod restart would wipe all dashboards and settings. With it, everything survives pod restarts, node failures, and cluster upgrades.
 
**Verify the volumes:**
 
```bash
# Check PVCs
kubectl get pvc -n monitoring
 
# Check actual disk usage
kubectl exec -it prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring -- df -h /prometheus
kubectl exec -it prometheus-grafana-0 -n monitoring -- df -h /var/lib/grafana
 
# Check what's inside Grafana storage
kubectl exec -it prometheus-grafana-0 -n monitoring -- ls -lh /var/lib/grafana/
```
 
**Verify in AWS Console:**
 
Go to EC2 > Volumes. You'll see the EBS volumes with tags like `zfw-preprod-ind-dynamic-pvc-<id>`. These are real gp3 disks being billed.
 
**Note:** If you see an extra volume without a name tag that isn't referenced by any PVC, it's likely orphaned from a failed install attempt. Check with `kubectl get pv -A | grep <volume-id>` — if nothing references it, delete it from AWS Console to stop paying for it.
 
### 6.8 Prometheus Data Retention & Cleanup
 
Prometheus handles cleanup **automatically** — you don't need to manually delete old data.
 
**Check current retention setting:**
 
```bash
kubectl get pod prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring -o yaml | grep retention
```
 
Our setting: `--storage.tsdb.retention.time=10d` — Prometheus automatically deletes data older than 10 days.
 
**How it works:**
 
```
Day 1:  Scrapes metrics → writes blocks → uses ~1.5-2 GB
Day 2:  More blocks → ~4 GB
...
Day 10: ~15-20 GB used
Day 11: Day 1 data automatically deleted → usage stabilizes at ~15-20 GB
```
 
Storage usage plateaus. Old data is pruned as new data comes in.
 
**Storage estimation for this cluster:**
 
| Factor | Value |
|---|---|
| Approximate time series | ~50,000 (15 nodes, ~30 pods, all exporters) |
| Scrape interval | 30 seconds |
| Samples per day | ~144 million |
| Disk per day | ~1.5-2 GB (compressed) |
| 10 day retention | ~15-20 GB |
| 50 GB volume | Enough for ~25-30 days |
 
With 10 day retention on a 50GB volume, disk will never fill up under normal operation.
 
**Two types of retention controls:**
 
| Setting | What it does | Current value |
|---|---|---|
| `retention` (time-based) | Delete data older than X days | 10d |
| `retentionSize` (size-based) | Delete oldest data when disk exceeds X | Not set |
 
**Optional: Set both as a safety net in values.yaml:**
 
```yaml
prometheus:
  prometheusSpec:
    retention: 10d           # time-based
    retentionSize: "40GB"    # size-based safety net
```
 
This means "keep 10 days of data, BUT if disk hits 40GB before 10 days, start deleting oldest first." Prevents disk-full scenarios where Prometheus stops ingesting.
 
**To change retention:**
 
```bash
cd ~/kube-prometheus-stack
# Edit values.yaml → change retention/retentionSize
helm upgrade prometheus . -n monitoring
```
 
**Monitor storage usage:**
 
The EBS Volume Usage (PVCs) panel in the Cluster & Node Health Grafana dashboard already tracks this. If it creeps above 80%, either reduce retention or expand the volume using:
 
```bash
# Expand PVC (ebs-resize StorageClass supports this)
kubectl edit pvc prometheus-prometheus-kube-prometheus-prometheus-db-prometheus-prometheus-kube-prometheus-prometheus-0 -n monitoring
# Change spec.resources.requests.storage to a larger value (e.g., 100Gi)
```
 
The EBS CSI driver will expand the volume online — no downtime needed.
 
### 6.9 Grafana Storage Sizing
 
Grafana's storage requirements are minimal compared to Prometheus:
 
| Content | Typical size |
|---|---|
| grafana.db (SQLite) | 10-50 MB |
| Plugin data | 50-200 MB |
| Total | Under 500 MB for most setups |
 
20Gi is generous. Even with hundreds of dashboards and heavy snapshot usage, Grafana rarely exceeds 1-2 GB. The extra space provides long-term headroom.
 
**Check current usage:**
 
```bash
kubectl exec -it prometheus-grafana-0 -n monitoring -- du -sh /var/lib/grafana/
```

---

## 7. Issues Faced & Resolutions

### 7.1 PVCs stuck in Pending — no StorageClass

**Symptom:**

```
Events:
  Normal  FailedBinding  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

**Cause:** Helm chart created PVCs without `storageClassName`. No default StorageClass was set on the cluster.

**Fix:** Uninstall, delete stuck PVCs, reinstall with `storageClassName: ebs-resize` explicitly set in values.yaml.

```bash
helm uninstall prometheus -n monitoring
kubectl delete pvc <pvc-name> -n monitoring
# Edit values.yaml, then reinstall
helm install prometheus . -n monitoring
```

**Lesson:** Always check `kubectl get storageclass` before installing any Helm chart that needs persistent storage.

### 7.2 PVC Pending — "claim Selector is not supported"

**Symptom:**

```
Events:
  Warning  ProvisioningFailed  ebs.csi.aws.com  claim Selector is not supported
```

**Cause:** The uncommented storageSpec block in values.yaml included `selector: {}` from the template. EBS CSI driver doesn't support selectors on PVCs.

**Fix:** Remove the `selector: {}` line from the storageSpec block, then upgrade and recreate PVC.

```bash
helm upgrade prometheus . -n monitoring
kubectl delete pvc <pvc-name> -n monitoring
kubectl delete pod <prometheus-pod> -n monitoring
```

**Lesson:** When uncommenting template blocks, remove the `selector` line.

### 7.3 Prometheus pod Pending — no events

**Symptom:** Pod shows `Pending` status, `Node: <none>`, but Events section is empty.

**Cause:** The PVC was also Pending. With `WaitForFirstConsumer` volume binding mode, the scheduler needs to place the pod first, then provision the volume in the same AZ. If the PVC can't provision (selector issue), both pod and PVC wait on each other.

**Fix:** Always check the PVC when a pod is Pending.

```bash
kubectl describe pvc <pvc-name> -n monitoring
```

### 7.4 Alertmanager data source health check failed in Grafana

**Symptom:** Grafana shows "Health check failed" for the Alertmanager data source.

**Cause:** Alertmanager was disabled (`enabled: false`) — no pod running to connect to.

**Fix:** Delete the Alertmanager data source in Grafana (Connections > Data sources > Alertmanager > Delete). Not needed.

---

## 8. Grafana Ingress Setup

### 8.1 Pre-checks

Before creating ingress, verify:

```bash
# ALB controller is running
kubectl get pods -n kube-system | grep aws-load-balancer

# Get existing ingress annotations for reference (subnets, SGs, certs)
kubectl get ingress -n preprod -o yaml
```

Note down: subnets, security groups, certificate ARN, group name.

### 8.2 ACM Certificate

The ALB needs an ACM certificate that covers your Grafana subdomain.

```bash
# List all certificates
aws acm list-certificates --region ap-south-1 --profile <your-profile>

# Check what domains a cert covers
aws acm describe-certificate \
  --certificate-arn <cert-arn> \
  --profile <your-profile> \
  --query "Certificate.SubjectAlternativeNames"
```

**Important:** Wildcard `*.<root-domain>` only covers ONE level. It covers `grafana.<root-domain>` but NOT `preprod.grafana.<root-domain>`. Use single-level subdomains like `preprod-grafana.<root-domain>`.

**Issue we hit:** Created `preprod-grafana.<root-domain>` — SSL failed because the wildcard cert didn't cover two levels. Changed to `preprod-grafana.<root-domain>`.

### 8.3 Create Ingress

The Grafana ingress must be in the **monitoring namespace** (same namespace as the service). ALB ingress can't route to services in a different namespace.

**Issue we hit:** Initially added the Grafana rule to the existing preprod namespace ingress. It couldn't find the `prometheus-grafana` service because it's in the monitoring namespace. Had to create a separate ingress in monitoring.

Use the same `group.name` annotation to share the existing ALB instead of creating a new one.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/group.name: alb-preprod-ind
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: <your-wildcard-cert-arn>
    alb.ingress.kubernetes.io/subnets: <subnet-1>,<subnet-2>,<subnet-3>
    alb.ingress.kubernetes.io/security-groups: <security-group-id>
    alb.ingress.kubernetes.io/tags: Environment=preprod
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - host: preprod-grafana.<root-domain>
      http:
        paths:
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: prometheus-grafana
                port:
                  number: 80
```

### 8.4 DNS Record

Add a CNAME record in your DNS provider:

```
preprod-grafana.<root-domain> → <alb-dns-name>.ap-south-1.elb.amazonaws.com
```

Get the ALB DNS:

```bash
kubectl get ingress grafana -n monitoring
```

### 8.5 Verify

```bash
# Ingress created with ALB address
kubectl get ingress -n monitoring

# No conflict with preprod ingress (same host shouldn't exist in both)
kubectl get ingress -n preprod

# Test HTTPS
curl -I https://preprod-grafana.<root-domain>
```

### 8.6 Login

Get the admin password:

```bash
kubectl get secret prometheus-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

Username: `admin`

---

## 9. CloudWatch Logs Integration

### 9.1 Understand existing log pipeline

```bash
# Check Vector config to see where logs go
kubectl get configmap vector -n monitoring -o yaml | grep -A20 "sinks:"

# Check env vars for log group path
kubectl get daemonset vector -n monitoring -o yaml | grep -A2 "BUSINESS_REGION\|ENVIRONMENT\|AWS_REGION"
```

Our setup: Vector collects logs from all pods → ships to CloudWatch log group `/applications/india/preprod` with three streams: `dashboard`, `zorms`, `unknown`.

### 9.2 Create IAM Policy

```bash
aws iam create-policy \
  --policy-name GrafanaCloudWatchRead \
  --profile <your-profile> \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "logs:GetLogEvents",
          "logs:GetLogRecord",
          "logs:GetLogGroupFields",
          "logs:GetQueryResults",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:FilterLogEvents"
        ],
        "Resource": "*"
      }
    ]
  }'
```

### 9.3 Create IAM Role with OIDC Trust

```bash
OIDC_ID="<your-cluster-oidc-id>"
ACCOUNT_ID="139xxxxxxxx0"

aws iam create-role \
  --role-name GrafanaCloudWatchRole \
  --profile <your-profile> \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::'$ACCOUNT_ID':oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/'$OIDC_ID'"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "oidc.eks.ap-south-1.amazonaws.com/id/'$OIDC_ID':sub": "system:serviceaccount:monitoring:prometheus-grafana"
          }
        }
      }
    ]
  }'
```

**Pre-check before creating:** Validate the OIDC ID, IAM registration, and service account name:

```bash
# Confirm OIDC ID matches the cluster
aws eks describe-cluster --name zfw-preprod-ind --region ap-south-1 --profile <your-profile> --query "cluster.identity.oidc.issuer" --output text

# Confirm OIDC is registered in IAM
aws iam list-open-id-connect-providers --profile <your-profile> | grep <OIDC_ID>

# Confirm service account exists
kubectl get serviceaccount prometheus-grafana -n monitoring
```

### 9.4 Attach Policy to Role

```bash
aws iam attach-role-policy \
  --role-name GrafanaCloudWatchRole \
  --policy-arn arn:aws:iam::13xxxxxxx390:policy/GrafanaCloudWatchRead \
  --profile <your-profile>
```

### 9.5 Annotate Service Account

```bash
kubectl annotate serviceaccount prometheus-grafana -n monitoring \
  eks.amazonaws.com/role-arn=arn:aws:iam::13xxxxxxx390:role/GrafanaCloudWatchRole
```

### 9.6 Restart Grafana

The pod must restart to pick up the IRSA token.

```bash
kubectl delete pod prometheus-grafana-0 -n monitoring
```

### 9.7 Configure Data Source in Grafana

Go to Connections > Data sources > Add > CloudWatch:
- **Authentication Provider:** AWS SDK Default
- **Assume Role ARN:** leave empty (IRSA handles it)
- **Default Region:** ap-south-1
- Click **Save & Test**

**Issue we hit:** Initially put the role ARN in the "Assume Role ARN" field. This caused auth failures because IRSA already provides credentials via the SDK chain. Leave it empty.

**Expected result:** "Successfully queried the CloudWatch logs API." The metrics error about `cloudwatch:ListMetrics` is expected — our policy only has logs permissions.

### 9.8 Test Logs Query

Go to Explore > select cloudwatch > CloudWatch Logs mode:
- Log group: `/applications/india/preprod`
- Query:

```
fields @timestamp, @message
| sort @timestamp desc
| limit 20
```

---

## 10. Grafana Dashboards

### 10.1 Custom Dashboards (imported via JSON)

Three custom dashboards were created with queries tailored to our workload:

| Dashboard | Panels | Data Source | Coverage |
|---|---|---|---|
| Cluster & Node Health | 22 | Prometheus | Node CPU/memory/disk, network, EBS volumes, node conditions |
| Workload & Pod Health | 28 | Prometheus | Deployments, pod restarts, OOMKills, container resources, Redis, KEDA, workload tiles |
| Application Observability | 11 | CloudWatch | HTTP errors, job failures, slow endpoints, response times |

Import: Dashboards > New > Import > Upload JSON file > Select appropriate data source.

**Important:** The JSON files have the data source UID hardcoded. If your Prometheus or CloudWatch data source UIDs differ, update them in the JSON before importing. Find your UIDs at: Connections > Data sources > click the data source > UID is in the URL.

### 10.2 Community Dashboards (imported by ID)

Go to Dashboards > New > Import > Enter ID > Select Prometheus as data source.

| ID | Dashboard | What it shows |
|---|---|---|
| 15760 | Kubernetes Views / Pods | Per-pod CPU, memory, network, restarts |
| 15758 | Kubernetes Views / Namespaces | Per-namespace resource usage |
| 15757 | Kubernetes Views / Global | Cluster-wide overview |
| 1860 | Node Exporter Full | Deep per-node metrics |
| 13770 | Kubernetes / Pod Details | Individual pod deep dive, OOMKill tracking |
| 7249 | Kubernetes Cluster Overview | Single-pane cluster health |
| 11454 | K8s StatefulSet | StatefulSet health (Prometheus, Grafana, Redis) |
| 14584 | K8s Deployment | Deployment rollout status, HPA |
| 16567 | EBS CSI Driver | Volume provisioning, attach/detach latency |

### 10.3 Useful CloudWatch Logs Queries

**HTTP 5xx errors:**

```
fields @timestamp, source, request.url, duration_ms, trace_id
| filter request.url like /-> 5/
| sort @timestamp desc
| limit 100
```

**HTTP 4xx errors:**

```
fields @timestamp, source, request.url, duration_ms, trace_id
| filter request.url like /-> 4/
| sort @timestamp desc
| limit 100
```

**Error count by status code over time:**

```
fields @timestamp, request.url
| filter request.url like /-> [45]/
| parse request.url "* -> *" as method_path, status_code
| stats count(*) by bin(5m), status_code
```

**Failed Zorms jobs:**

```
fields @timestamp, source, job_name, status, duration_ms, trace_id
| filter source = "zorms" and status != "finished"
| sort @timestamp desc
| limit 100
```

**Slow jobs (over 5 seconds):**

```
fields @timestamp, source, job_name, duration_ms, status, trace_id
| filter duration_ms > 5000
| sort duration_ms desc
| limit 50
```

**Which services have HTTP logs:**

```
fields @timestamp, source, request.url, duration_ms
| filter ispresent(request.url)
| stats count(*) by source
```

---

## 11. Verification Checklist

Run through this after setup to confirm everything is working.

### Infrastructure

- [ ] All monitoring pods running: `kubectl get pods -n monitoring`
- [ ] All PVCs bound: `kubectl get pvc -n monitoring`
- [ ] Node exporter running on all nodes: `kubectl get daemonset -n monitoring`

### Grafana Access

- [ ] Grafana accessible via ingress URL (HTTPS)
- [ ] Login works with admin credentials
- [ ] Prometheus data source: Save & Test shows success
- [ ] CloudWatch data source: Save & Test shows "Successfully queried CloudWatch logs API"
- [ ] Alertmanager data source deleted (if alertmanager is disabled)

### Dashboards

- [ ] Cluster & Node Health dashboard shows data
- [ ] Workload & Pod Health dashboard shows deployments and pod metrics
- [ ] Application Observability dashboard shows log volume
- [ ] Community dashboards imported and showing data

### CloudWatch Logs

- [ ] Explore > CloudWatch Logs > query returns results
- [ ] Log group `/applications/india/preprod` visible
- [ ] All three streams accessible: dashboard, zorms, unknown

### IRSA

- [ ] Service account annotated: `kubectl get sa prometheus-grafana -n monitoring -o yaml | grep role-arn`
- [ ] IAM role exists: `aws iam get-role --role-name GrafanaCloudWatchRole`
- [ ] Policy attached: `aws iam list-attached-role-policies --role-name GrafanaCloudWatchRole`
- [ ] OIDC trust policy references correct cluster and service account

---

## Quick Reference — Common Commands

```bash
# Check all monitoring resources
kubectl get all -n monitoring

# Grafana password
kubectl get secret prometheus-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# Helm release status
helm list -n monitoring

# Upgrade after values.yaml changes
helm upgrade prometheus . -n monitoring

# Restart Grafana (after IRSA changes)
kubectl delete pod prometheus-grafana-0 -n monitoring

# Port-forward for local access (no ingress needed)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# Check Prometheus targets
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# Then open localhost:9090/targets

# Vector log pipeline check
kubectl get configmap vector -n monitoring -o yaml | grep -A20 "sinks:"
```

---

## Architecture Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │              Monitoring Namespace            │
                    │                                             │
  User/Browser ───► │  ALB ───► Grafana (port 80)                │
                    │              │                               │
                    │              ├── Data Source: Prometheus     │
                    │              │     └── kube-state-metrics    │
                    │              │     └── node-exporter (x15)  │
                    │              │     └── kubelet metrics       │
                    │              │                               │
                    │              └── Data Source: CloudWatch     │
                    │                    └── IRSA ──► CloudWatch  │
                    │                                  Logs API   │
                    │                                             │
                    │  Vector DaemonSet (x15)                     │
                    │     └── Collects pod stdout/stderr          │
                    │     └── Ships to CloudWatch Logs            │
                    │         └── /applications/india/preprod     │
                    │                                             │
                    │  Prometheus StatefulSet (50Gi EBS)          │
                    │     └── Scrapes metrics every 30s           │
                    │     └── Retains 10 days                     │
                    │                                             │
                    │  Grafana StatefulSet (20Gi EBS)             │
                    │     └── Dashboards persisted                │
                    └─────────────────────────────────────────────┘
```
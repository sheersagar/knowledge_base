## 1. Internal Service-to-Service Communication (ECS Service Connect)

### Context
Multiple backend components and microservices were deployed inside a VPC
(private subnets). These services needed to communicate with each other using
**service names**, while ensuring traffic remained **internal to the VPC**.

Some dependent systems (ERP, Saleor) were deployed on standalone servers and
had to call backend APIs that were running on ECS.

---

### Problem Statement
Internal backend services were communicating via **public domain names**,
which caused:

- Traffic to exit the VPC and re-enter via NAT / Internet Gateway
- Unnecessary latency and cost
- Dependency on external DNS for internal calls
- Blurred separation between internal and external traffic paths

The goal was to enable **internal service-to-service communication** without:
- exposing services publicly
- managing IPs manually
- introducing heavy operational overhead

---

### Existing / Naive Approaches
The following options were considered but had drawbacks:

#### 1. Public ALB + Public DNS
- Simple to set up
- ❌ Internal traffic still goes via internet/NAT
- ❌ Security exposure

#### 2. Private ALB + Custom DNS
- Keeps traffic internal
- ❌ Requires manual ALB management
- ❌ Scaling and service discovery become complex

#### 3. Hardcoded IPs / Host Entries
- ❌ Not viable due to dynamic ECS tasks
- ❌ Operationally unsafe

---

### Chosen Solution
**ECS Service Connect backed by AWS Cloud Map namespace**
#### Implementation Reference 
see: [ECS Service connect - Implementation notes](../../05-labs-poc/cloud/ecs-service-connect-implementation.md)

Service Connect allows ECS services to:
- register themselves in a private namespace
- discover each other using **internal DNS names**
- communicate without routing traffic outside the VPC

---

### High-Level Architecture
<img src="../../Images/tenxyou_backend_communication.png" alt="Backend Communication" width="900">

---

### How Service Connect Works (Conceptual)
- A **private Cloud Map namespace** is created
- ECS services are associated with the namespace
- Each service gets a stable internal DNS name
- An Envoy sidecar is injected per task
- Traffic is routed via the sidecar using service discovery

Key point:
> **Service identity is decoupled from task IPs**

---

### Why Service Connect Fit This Use Case
- No NAT Gateway traversal for internal calls
- DNS-based discovery (natural for services)
- Native ECS integration
- No separate service mesh to manage
- Minimal configuration compared to App Mesh

---

### Traffic Flow (Before vs After)

#### Before
saleor-api or erp-prod → public domain → internet/NAT → ALB → backend service

#### After
saleor-api or erp-prod → internal DNS (namespace) → backend service


---

### Integration with External Components
- ERP and Saleor (standalone servers) continued using public endpoints
- Internal ECS services used Service Connect DNS names
- Clear separation between:
  - internal east-west traffic
  - external north-south traffic

---

### Trade-offs & Limitations
- Envoy sidecar adds memory/CPU overhead
- ECS-specific abstraction (not portable)
- Limited traffic shaping compared to full service mesh
- Debugging adds another layer (sidecar)

---

### When to Use Service Connect
- ECS-based microservices
- Internal-only communication
- DNS-based discovery is sufficient
- Want minimal operational overhead

### When NOT to Use
- Cross-VPC or cross-account communication
- Advanced traffic routing (canary, mirroring)
- Non-ECS workloads

---

### Operational Notes / Gotchas
- Account for sidecar resource usage in task sizing
- Namespace choice impacts discoverability
- Misconfigured security groups can still block traffic
- Logs are split between app container and sidecar

---

### Related Sections
- `ecs.md#networking`
- `ecs.md#iam`
- `02-playbooks/cloud/ecs-internal-traffic-via-nat.md`
- `05-labs-poc/ecs-service-connect.md`

---

### Tags
#aws #ecs #service-connect #cloud-map #networking #microservices

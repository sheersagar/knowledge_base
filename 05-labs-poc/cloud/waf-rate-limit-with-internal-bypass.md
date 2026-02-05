## Problem Statement
External traffic to api.tenxyou.com needed rate limiting via AWS WAF.
However, internal services were also calling the same endpoint, which might cause:
- Unnecessary rate limit consumption
- Increased latency
- Risk of internal service disruption

Goal:
Apply rate limiting only to external traffic while keeping internal calls unrestricted.

![](../../Images/tenxyou_architecture.png)

## Existing Architecture (Before)
- api.tenxyou.com → CloudFront → ALB → backend
- All traffic (external + internal) used the same public endpoint
- No traffic separation
- WAF planned but not yet enforced

![](../../Images/tenxyou_backend_communication.png)

## Target Architecture (After)
External traffic:
Internet → api.tenxyou.com → CloudFront → WAF → ALB

Internal traffic:
VPC services → internal.api.tenxyou.com → ALB (direct)

Key properties:
- WAF attached only to CloudFront
- Internal traffic bypasses CloudFront and WAF
- DNS-based traffic separation

![](../../Images/tenxyou_new_flow.png)

---
---

## Step-by-Step Configuration

### Step 1: Identify WAF Scope (Critical)
WAF must be attached to **CloudFront**, not ALB.
![](../../Images/waf_scope.png)

**Why**
- WAF on ALB would affect both internal and external traffic
- CloudFront scope isoltes external traffic only

---

### Step2: Create IP Set (If Allowlisting  Is Needed)
Created IP set for trusted sources.
- Mention IP that needs to be included in IP set

**Important**

- Scope must be `CLOUDFRONT`
- Region must be `us-east-1` (CloudFront global requirement)


### Step 3: Create Rule groups
- Create rule group and make sure scope is configured correctly
- Then Manage rule ---> Add rule --> IP based or Geo-based or Rate-based or Custom

Configuration:
- Rule type: IP-based
- Action: ALLOW
- Priority: Highest


**Effect**
- Whitelisted IPs bypass all further evaluation
- Once rules are done, make sure the sequence has to be right.
    - This will determine the flow of rule, as to which one apply first.

---

### Step $: 




# MailEnable on AWS — Full Migration & Configuration Story

> **Organisation:** Infinite Locus Private Limited  
> **Author:** Vishav Deshwal (DevOps Engineer)  
> **Date:** March 2026  
> **Server:** Windows Server EC2 (`<your-elastic-ip>`, `ca-central-1`)  
> **Test Domain:** `<project-name>.staging.<testing-root-domain>`  
> **Production:** Still running on original on-premise server (untouched)

---

## 1. Background — What We Started With

### The On-Premise Setup

The production environment was running on a physical/on-premise Windows Server with:

- **Plesk** — web hosting control panel managing multiple domains and websites
- **MailEnable** — Windows mail server handling email for multiple domains:
  - `<production-domain>`
  - `<production-domain-1>`
  - `<production-domain-3>`
  - `<production-domain-4>`
  - `<production-domain-2>`
- All domains, mailboxes, DNS records, and SSL certificates configured and working in production

### The Goal

Migrate the entire server to AWS EC2 and validate that mail services work before cutting over production DNS. The approach:

```
Phase 1: Migrate server to AWS using AWS MGN (Application Migration Service)
Phase 2: Test everything on a staging domain (<project-name>.staging.<testing-root-domain>)
Phase 3: Once validated, cut production DNS over to AWS server
```

---

## 2. The Migration — AWS MGN (Application Migration Service)

### How MGN Works

![MGN Migration Dashboard](../../Images/13-mgn-dashboard.png)

AWS MGN (Application Migration Service) replicates a server at the byte level from source to destination:

```
On-Premise Windows Server
        |
        | MGN Agent installed → continuous replication
        ↓
AWS MGN Staging Area (internal)
        |
        | "Launch Test Instance" →
        ↓
AWS EC2 Instance (exact copy of production)
```

The test EC2 is a **point-in-time snapshot** launched from replicated data. It is isolated — MGN continues replicating to its staging area but does NOT push changes into the running test EC2.

### What This Means Practically

- The test EC2 has **all production Post Offices, mailboxes, Plesk sites, IIS config** — everything
- Production server continues running independently — no impact
- Any configurations made on the test EC2 are **not reflected back to production**
- On eventual cutover, MGN launches a **fresh instance** from latest replicated data — so MailEnable configs made during testing need to be redone on the cutover instance

### MGN Status at Time of Testing

```
Lifecycle:              Test in progress
Replication progress:   Initial replication finished
Lag:                    — (no pending changes)
Backlog:                — (nothing queued)
```

Safe to configure the test instance without risk of changes being overwritten.

---

## 3. The Complication — Plesk + MailEnable Together

### What Plesk Is

Plesk is a web hosting control panel that manages:
- IIS websites and virtual hosts
- DNS zones
- SSL certificates
- FTP accounts
- And optionally — mail (but in this case MailEnable handles mail, not Plesk)

### Why This Matters for Mail

Because Plesk manages IIS, the webmail interface for MailEnable runs under an IIS site that Plesk controls. This created a specific challenge: the MailEnable webmail IIS binding was tied to `mewebmail` hostname on `127.0.0.1` only — not publicly accessible until we explicitly added a binding.

### The Coexistence Architecture

```
Windows Server EC2
├── Plesk
│   ├── IIS → <production-domain> website
│   ├── IIS → <production-domain-1> website
│   ├── IIS → <production-domain-3> website
│   └── IIS → (other Plesk-managed sites)
│
└── MailEnable (independent of Plesk)
    ├── SMTP Connector → handles send/receive
    ├── Post Offices → <production-domain>, <production-domain-1>, etc.
    ├── IMAP/POP3 → client mail retrieval
    └── Webmail → IIS site "MailEnable WebMail"
                   (bound to mewebmail:127.0.0.1 — localhost only by default)
```

---

## 4. Why We Needed a Test Domain

### The Problem With Testing on Production Domains

The production domains (`<production-domain>`, `<production-domain-1>` etc.) have their DNS MX records pointing to the **production server**. We cannot point them to the test server without breaking live production mail.

### The Solution — Staging Subdomain

Create a brand new domain/subdomain that has never had DNS records, configure everything from scratch on the test server, and use it to validate the entire mail flow end-to-end:

```
Production flow (untouched):
[Gmail] → MX lookup <production-domain> → production server → production mailbox

Test flow (new):
[Gmail] → MX lookup <project-name>.staging.<testing-root-domain> → test EC2 (<your-elastic-ip>) → test mailbox
```

This lets us test everything in complete isolation without touching production.

---

## 5. How Email Works — The Foundation

Before diving into configuration, understanding the mail flow is essential.

### The Protocols

| Protocol | Port | Direction | Purpose |
|---|---|---|---|
| SMTP | 25 | Server → Server | Mail transfer between mail servers |
| SMTP Submission | 587 | Client → Server | Authenticated mail from mail clients |
| IMAP | 993 (SSL) | Client → Server | Read mail (stays on server) |
| POP3 | 995 (SSL) | Client → Server | Download mail (removed from server) |

### The Complete Mail Flow

```
OUTBOUND (You sending mail):
[Mail Client] 
    → port 587 + auth credentials
    → [Your MailEnable Server]
    → DNS MX lookup for recipient domain
    → port 25 SMTP handshake with destination server
    → [Gmail / Outlook / destination]
    → Spam checks (SPF, DKIM, DMARC)
    → Delivered to recipient mailbox

INBOUND (Someone sending to you):
[Gmail / external sender]
    → DNS MX lookup for your domain
    → port 25 SMTP handshake with your server
    → [Your MailEnable Server]
    → Spam checks, local delivery
    → Written to mailbox on disk
    → [Mail Client connects via IMAP/POP3 to fetch]
```

### What Happens on Google's Side After Your MTA Hands Off

This is the detailed inbound flow once your MTA connects to Google's inbound MTA on port 25:

```
Your MTA
    |
    | port 25 — SMTP handshake
    | "Here is the mail for user@gmail.com"
    ↓
Google's MTA
    |
    ↓
[Inbound Queue]
    Mail sits here temporarily while checks run
    |
    ↓
[Spam + Virus Checks]
    - SPF  → Is the sending IP authorized for this domain?
    - DKIM → Is the cryptographic signature valid?
    - DMARC → What's the domain policy if above fail?
    - ML spam filters → Content analysis
    |
    ↓
[MDA — Mail Delivery Agent]
    "Does this user exist?"
    "Which folder does it go into?"
    → Inbox, Spam, Promotions, Social — decided here
    |
    ↓
[MDA writes the message to disk as a file]
    Mail is now stored on Google's infrastructure
    Nothing pushes it to the user — it waits
    |
    ↓
[IMAP/POP3 daemon sits idle — waiting]
    |
    ↓ (when user opens Gmail app or client)
[MUA — Mail User Agent]
    Reads from storage where MDA wrote it
    Displays mail in inbox
```

### The Key Insight — Push vs Pull

This is the most important concept to internalize:

```
SMTP = PUSH protocol
    Your MTA pushes mail TO the destination MTA
    The destination never calls you back
    Delivery is fire-and-forget from your side

IMAP/POP3 = PULL protocol
    The recipient's client pulls mail FROM the server
    Nothing is pushed to the client automatically
    Client checks for new mail on a schedule
```

This is why email is not instant like WhatsApp — each leg (MTA→MTA, client→server) is independent and asynchronous.

### MTA vs MDA — The Distinction

| | MTA | MDA |
|---|---|---|
| Full name | Mail Transfer Agent | Mail Delivery Agent |
| Job | Move mail between servers | Drop mail into correct mailbox |
| Talks to | Other MTAs on port 25 | Local mailbox storage on disk |
| Analogy | Post van delivering to the building | Building receptionist sorting into pigeonholes |
| MailEnable equivalent | SMTP Connector | Postoffice Connector |
| Linux equivalent | Postfix, Sendmail | Dovecot, Procmail |

In MailEnable both are bundled — SMTP Connector is the MTA, Postoffice Connector is the MDA. On Linux these are often separate software packages.

### The SMTP Handshake (What Happens on Port 25)

SMTP is a plain text conversation:

```
Sender MTA                    Receiver MTA
   |                               |
   |--- TCP connect port 25 ------>|
   |<-- 220 Ready -----------------|
   |--- EHLO yourdomain.com ------>|
   |<-- 250 OK + capabilities -----|
   |--- MAIL FROM:<sender> ------->|
   |<-- 250 OK --------------------|
   |--- RCPT TO:<recipient> ------>|
   |<-- 250 OK --------------------|
   |--- DATA ---------------------->|
   |<-- 354 Start input ------------|
   |--- [headers + body + .] ------>|
   |<-- 250 OK queued --------------|
   |--- QUIT ----------------------->|
```

### The Components Inside MailEnable

| Component | Role | Analogy |
|---|---|---|
| SMTP Connector | MTA — moves mail between servers | Post van |
| Postoffice Connector | MDA — delivers to correct mailbox | Building receptionist |
| IMAP/POP3 Service | Mail retrieval for clients | Mailbox key |
| Mail Transfer Agent | Queue processor + retry logic | Dispatch scheduler |
| List Connector | Mailing list fan-out | Distribution list manager |
| Webmail | Browser-based client | Web interface |

---

## 6. AWS-Specific Constraints and Why They Exist

### Port 25 Blocked by Default

AWS blocks outbound port 25 on all new accounts to prevent spam. This is the single biggest blocker for running a mail server on AWS.

```
Default state:
Inbound port 25  → OPEN (configure in Security Group)
Outbound port 25 → BLOCKED (must request removal via AWS Support)
```

To unblock: AWS Console → Support → Create Case → "Request to remove email sending limitations". Include your EC2 instance ID, Elastic IP, and use case. Approved in 24-48hrs.

### Why Elastic IP is Mandatory

Mail servers need a static IP because:
- PTR (reverse DNS) records point an IP to a hostname — this cannot work with dynamic IPs
- Gmail and other mail servers check PTR on every inbound connection
- If your IP changes, PTR breaks, mail gets rejected

### Why PTR (Reverse DNS) Matters

![AWS Elastic IP with PTR Record Set](../../Images/09-aws-elastic-ip-ptr.png)

When your server connects to Gmail:
```
Your server: "EHLO mail.<project-name>.staging.<testing-root-domain>"
Gmail:       "Let me check who IP <your-elastic-ip> says it is"
PTR lookup:  <your-elastic-ip> → mail.<project-name>.staging.<testing-root-domain> ✅ matches
```

If PTR is missing or mismatches EHLO → Gmail rejects or spam-folders.

AWS lets you set PTR via: EC2 → Elastic IPs → Actions → Update Reverse DNS. AWS validates the A record must exist first before allowing PTR to be set.

---

## 7. DNS Records — What Each One Does and Why

All records were added in GoDaddy under `<testing-root-domain>` for the subdomain `<project-name>.staging`.

### A Record — The Foundation

![AWS Security Group Inbound Rules](../../Images/10-aws-security-group.png)

```
mail.<project-name>.staging.<testing-root-domain>  →  <your-elastic-ip>
```

Maps the mail server hostname to the IP. Every other record references this. Must exist before PTR can be set.

### MX Record — Inbound Mail Routing

```
<project-name>.staging.<testing-root-domain>  MX 10  mail.<project-name>.staging.<testing-root-domain>
```

When anyone sends to `@<project-name>.staging.<testing-root-domain>`, the sending server asks DNS: "who accepts mail for this domain?" MX answers that question. Without MX — nobody can email you.

### SPF Record — Outbound Authorization

```
<project-name>.staging.<testing-root-domain>  TXT  "v=spf1 ip4:<your-elastic-ip> ~all"
```

Tells the world that `<your-elastic-ip>` is the only authorized IP to send mail for this domain. When Gmail receives mail claiming to be from `@<project-name>.staging.<testing-root-domain>`, it checks: "is the sending IP in the SPF record?" `~all` means soft fail (suspicious but don't reject) — change to `-all` for hard reject once stable.

### DKIM Record — Cryptographic Signature

```
default._domainkey.<project-name>.staging.<testing-root-domain>  TXT  "v=DKIM1; k=rsa; p=<public key>"
```

MailEnable signs every outbound mail with a private key. Gmail verifies the signature using the public key in DNS. This proves the mail genuinely came from your server and wasn't tampered with in transit.

### DMARC Record — Policy Enforcement

```
_dmarc.<project-name>.staging.<testing-root-domain>  TXT  "v=DMARC1; p=none; rua=mailto:admin@<project-name>.staging.<testing-root-domain>"
```

Sits on top of SPF and DKIM. Tells receivers what to do if SPF/DKIM fail:
- `p=none` → just monitor, don't reject (safe for initial setup)
- `p=quarantine` → send to spam if checks fail
- `p=reject` → reject outright if checks fail

`rua=` sends aggregate failure reports to the specified address.

### PTR Record — Reverse DNS

Set in AWS Console (not DNS provider):
```
<your-elastic-ip>  →  mail.<project-name>.staging.<testing-root-domain>
```

The only record set at the IP level rather than domain level.

### The Full Consistency Chain

```
<your-elastic-ip>
    ↕ PTR / A must match
mail.<project-name>.staging.<testing-root-domain>
    ↕ A record / SMTP EHLO must match
EHLO: mail.<project-name>.staging.<testing-root-domain>
    ↕ MX must point here
<project-name>.staging.<testing-root-domain> MX → mail.<project-name>.staging.<testing-root-domain>
```

All four must be consistent. One mismatch = deliverability problems.

---

## 8. MailEnable Configuration — Every Setting Explained

### Post Office vs Domain vs Mailbox

This is the most confusing part of MailEnable's structure:

![MailEnable MMC Full Tree](../../Images/01-mailenable-mmc-tree.png)

```
Post Office (internal name, max 20 chars, no dots)
    └── Domain (the actual email domain — can have dots)
    └── Mailboxes (individual inboxes)
    └── Groups
    └── Lists
```

Because the domain `<project-name>.staging.<testing-root-domain>` exceeds 20 characters and contains dots, the Post Office was named `<project-name>staging` (short internal identifier) with the domain `<project-name>.staging.<testing-root-domain>` added separately under it.

**Critical implication:** SMTP authentication uses the Post Office name, not the domain:
```
✅ testuser@<project-name>staging           ← works for SMTP auth
❌ testuser@<project-name>.staging.<testing-root-domain>  ← fails for SMTP auth
```

### SMTP Connector — Tab by Tab

![<project-name>staging Mailboxes — admin, postmaster, testuser](../../Images/02-mailenable-mailboxes.png)

**General tab:**

![SMTP Connector — General Tab](../../Images/03-smtp-general.png)

```
Local Domain Name:          mail.<project-name>.staging.<testing-root-domain>
Default mail domain name:   <project-name>.staging.<testing-root-domain>
DNS Addresses:              8.8.8.8 8.8.4.4
Notification email:         postmaster@<project-name>.staging.<testing-root-domain>
```
This is the server's identity. `Local Domain Name` becomes the EHLO value during SMTP handshakes.

**Inbound tab:**

![SMTP Connector — Inbound Tab](../../Images/04-smtp-inbound.png)

```
Port 25: enabled          ← receives mail from other servers
Port 587: enabled         ← receives mail from authenticated clients
Max connections: 32
```
Port 25 is for server-to-server (unauthenticated). Port 587 is for mail clients (authenticated).

**Relay tab:**

![SMTP Connector — Relay Tab](../../Images/05-smtp-relay.png)

```
✅ Enable Mail Relay
✅ Allow relay for authenticated senders only
❌ Allow relay for privileged IP ranges    ← disabled
❌ Allow relay for local sender addresses  ← disabled (this opens relay to spammers)
```
This is the most security-critical setting. An open relay means anyone can use your server to send spam, which leads to IP blacklisting within hours. Only authenticated users should be able to relay to external addresses.

**Security tab:**

![SMTP Connector — Security Tab](../../Images/06-smtp-security.png)

```
✅ Reject mail if sender address is from an invalid domain
✅ Authenticated senders must use valid sender address
✅ Require PTR DNS entry for unauthenticated connections
```
These three settings reject a large percentage of spam at the connection level before it even enters the queue.

**DNS Blacklisting tab:**

![SMTP Connector — DNS Blacklisting Tab](../../Images/07-smtp-dnsbl.png)

```
✅ Enable DNS blacklisting
Added: SpamhausZEN, Spamcop, Barracuda Reputation Block List
Action: Don't accept the email
```
Before accepting any inbound mail, MailEnable checks if the connecting server's IP is on any of these blacklists. SpamhausZEN alone blocks the majority of spam IPs worldwide.

**Delivery tab:**
```
Failed message lifetime:    72 hours (allows destination server recovery time)
NDR generation:             Only for authenticated senders
Max concurrent connections: 20 (prevents hammering single destinations)
```

**Advanced SMTP tab:**
```
✅ Add required headers for authenticated senders
❌ EXPN command disabled (prevents address harvesting)
```
Gmail enforces RFC 5322 — all outbound mail must have `From:`, `To:`, `Date:`, and `Subject:` headers. MailEnable adds missing headers automatically when this is checked.

**Smart Host tab:**
```
Disabled (left blank)
```
Smart Host would route all outbound mail through a relay (like AWS SES). Since AWS unblocked port 25 directly, mail is delivered directly to destination servers — no relay needed.

---

## 9. DKIM Setup — The Manual Process

### Why It Was Manual

MailEnable Standard edition manages DKIM through config files rather than a GUI tab. The files live at:

```
Config file:   C:\Program Files (x86)\Mail Enable\Config\DKIM-<domain>.SYS
Private key:   C:\Program Files (x86)\Mail Enable\Config\DKIM\default-<domain>.key
```

### How It Was Done

Generated an RSA 2048-bit key pair using PowerShell's built-in cryptography:

```powershell
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)

# Save private key
$privateKeyBytes = $rsa.ExportCspBlob($true)
$privateKeyB64 = [Convert]::ToBase64String($privateKeyBytes, 'InsertLineBreaks')
$privateKeyPem = "-----BEGIN RSA PRIVATE KEY-----`r`n$privateKeyB64`r`n-----END RSA PRIVATE KEY-----"
$privateKeyPem | Out-File "C:\Program Files (x86)\Mail Enable\Config\DKIM\default-<project-name>.staging.<testing-root-domain>.key" -Encoding ASCII
```

Created the SYS config file matching the exact XML format of existing production domain DKIM files:

```xml
<BASEELEMENT>
  <ELEMENT>
    <TYPE>Selector</TYPE>
    <SELECTORNAME>default</SELECTORNAME>
    <DNS-TXT>v=DKIM1; </DNS-TXT>
  </ELEMENT>
  <ELEMENT>
    <TYPE>Options</TYPE>
    <ACTIVESELECTOR>default</ACTIVESELECTOR>
    <KEYFILE>default-<project-name>.staging.<testing-root-domain>.key</KEYFILE>
    <SIGN>1</SIGN>
    <HASHALGORITHM>rsa-sha256</HASHALGORITHM>
    <HEADERCANONICALIZATION>relaxed</HEADERCANONICALIZATION>
    <BODYCANONICALIZATION>relaxed</BODYCANONICALIZATION>
    <LIMITBODYHASHLENGTH>-1</LIMITBODYHASHLENGTH>
    <INCLUDEUSERIDENTITY>0</INCLUDEUSERIDENTITY>
  </ELEMENT>
</BASEELEMENT>
```

Extracted the public key in PKCS#1 DER format for the DNS TXT record and added to GoDaddy:

```
default._domainkey.<project-name>.staging  TXT  "v=DKIM1; k=rsa; p=<public key>"
```

---

## 10. The Webmail Access Problem

![MailEnable Webmail Login Page](../../Images/12-webmail-login.png)

### What Happened

The MailEnable webmail IIS site had this binding:
```
http 127.0.0.1:80:mewebmail
```

This means it only responds to requests from localhost with hostname `mewebmail`. Accessing it from outside the server was impossible.

### Why This Is the Default

Plesk manages IIS on this server. When MailEnable is installed alongside Plesk, it binds webmail to localhost only to avoid conflicting with Plesk's domain-based virtual host routing.

### The Fix

Added a public binding to the IIS site:

```powershell
New-WebBinding -Name "MailEnable WebMail" -Protocol "http" -Port 80 -HostHeader "webmail.<project-name>.staging.<testing-root-domain>"
```

Added DNS A record:
```
webmail.<project-name>.staging  A  <your-elastic-ip>
```

Webmail now accessible at:
```
http://webmail.<project-name>.staging.<testing-root-domain>/Mondo/lang/sys/Login.aspx
```

Login format:
```
Username: testuser@<project-name>staging    ← Post Office name, not full domain
Password: Admin@123
```

---

## 11. Issues Encountered and How They Were Resolved

### Issue 1 — PTR Set Before A Record Existed
AWS validates the forward A record before allowing PTR to be set. Setting PTR before adding the DNS A record causes "Update reverse DNS failed."

**Resolution:** Add A record in GoDaddy first, wait for propagation, then set PTR.

### Issue 2 — DNSBL Blocking Test Machine
When testing from a Mac on a business/ISP network, the Mac's IP (`103.242.225.82`) was on Spamhaus/SpamCop blacklists. Every inbound test connection was rejected with `554 The IP address was found in a DNS blacklist`.

**Resolution:** Create `SMTP-WHITELIST.SYS` with whitelisted IP:
```
C:\Program Files (x86)\Mail Enable\Config\SMTP-WHITELIST.SYS
```
File must contain one IP per line. The "Enable Whitelist" checkbox in SMTP Properties → Whitelist tab must also be checked.

### Issue 3 — SMTP AUTH Username Format
Authentication with `testuser@<project-name>.staging.<testing-root-domain>` (full domain) failed. MailEnable SMTP AUTH requires the Post Office name.

**Resolution:** Use `testuser@<project-name>staging` (Post Office name) for SMTP auth.

### Issue 4 — Base64 Newline in Password
Encoding password with `echo "password" | base64` on Mac adds a trailing newline, producing `QWRtaW5AMTIzCg==` instead of `QWRtaW5AMTIz`. The trailing `Cg==` (base64 for `\n`) causes auth failure.

**Resolution:** Always use `-n` flag: `echo -n "password" | base64`

### Issue 5 — Gmail Rejecting Mail (Missing From Header)
Raw telnet test sent DATA without required RFC 5322 headers, causing Gmail to reject with:
```
550 5.7.1 'From' header is missing
```

**Resolution:** Always include full headers in DATA section:
```
From: sender@domain.com
To: recipient@domain.com
Subject: Subject here
Date: Thu, 19 Mar 2026 01:00:00 +0000

Body here.
.
```

### Issue 6 — Webmail 404 at /Mondo/lang/sys/Login.aspx via IP
Accessing webmail via direct IP failed because IIS requires hostname matching. The site has no binding for the bare IP.

**Resolution:** Add DNS A record + IIS binding for `webmail.<project-name>.staging.<testing-root-domain>`.

---

## 12. Security Configuration Summary

### What Was Locked Down

| Control | Setting | Why |
|---|---|---|
| Relay | Authenticated senders only | Prevents open relay / spam abuse |
| Sender validation | From must match authenticated user | Prevents spoofing |
| DNSBL | SpamhausZEN + Spamcop + Barracuda | Blocks known spam IPs at connection |
| PTR requirement | Unauthenticated connections must have PTR | Blocks throwaway spam servers |
| Invalid domain rejection | Enabled | Blocks mail from fake domains |
| EXPN command | Disabled | Prevents address harvesting |
| Outbound rate limit | 20 max concurrent connections | Limits blast radius if compromised |
| NDR generation | Auth senders only | Prevents directory harvest attacks |

### What an Open Relay Looks Like (and Why It's Dangerous)

```
# Test to verify relay is CLOSED (run from external machine):
telnet mail.<project-name>.staging.<testing-root-domain> 25
EHLO test.com
MAIL FROM:<random@random.com>
RCPT TO:<victim@gmail.com>   ← external address, not your domain

# Expected (correct):
554 Relay not permitted

# If you see this instead — you have an open relay, fix immediately:
250 OK
```

---

## 13. Test Results — Final Verification

![Gmail Show Original — SPF PASS, DMARC PASS](../../Images/11-gmail-spf-dmarc-pass.png)

| Test | Result |
|---|---|
| Port 25 inbound reachable | ✅ |
| Port 587 inbound reachable | ✅ |
| Port 993 (IMAP SSL) reachable | ✅ |
| SMTP authentication working | ✅ |
| Inbound mail from Gmail | ✅ Delivered to mailbox |
| Outbound mail to Gmail | ✅ Landed in Primary inbox |
| SPF check | ✅ PASS (IP <your-elastic-ip>) |
| DMARC check | ✅ PASS |
| TLS on outbound | ✅ TLS1_2 |
| TLS on inbound | ✅ TLS1_3 |
| DKIM signing | ✅ Confirmed in SMTP logs |
| Webmail accessible | ✅ via webmail.<project-name>.staging.<testing-root-domain> |

---

## 14. Architecture Diagram

```
INTERNET
    |
    | DNS: <project-name>.staging.<testing-root-domain>
    | MX → mail.<project-name>.staging.<testing-root-domain>
    | A  → <your-elastic-ip>
    |
AWS NETWORK (ca-central-1)
    |
    | Elastic IP: <your-elastic-ip>
    | PTR: mail.<project-name>.staging.<testing-root-domain>
    |
SECURITY GROUP (windows-server-sg)
    | Inbound: 25, 587, 993, 995, 143, 3389
    |
WINDOWS SERVER EC2 (2CBDA56, m6i.xlarge)
    |
    ├── Windows Firewall
    │   Inbound: 25, 587, 993, 995, 143
    |
    ├── Plesk (web hosting panel)
    │   ├── <production-domain> website
    │   ├── <production-domain-1> website
    │   └── (other production sites — not active on test server)
    |
    └── MailEnable
        ├── SMTP Connector (port 25/587)
        │   ├── Relay: auth only
        │   ├── DNSBL: Spamhaus, Spamcop, Barracuda
        │   └── DKIM signing enabled
        ├── IMAP Service (port 993)
        ├── POP3 Service (port 995)
        ├── Postoffice Connector
        └── Post Offices
            ├── <project-name>staging (NEW — test)
            │   ├── Domain: <project-name>.staging.<testing-root-domain>
            │   └── Mailboxes: postmaster, admin, testuser
            ├── <production-domain> (migrated from prod — inactive)
            ├── <production-domain-1> (migrated from prod — inactive)
            └── (other migrated post offices — inactive)
```

---

## 15. File Locations Reference

| File/Directory | Purpose |
|---|---|
| `C:\Program Files (x86)\Mail Enable\Config\DKIM\` | DKIM private key files |
| `C:\Program Files (x86)\Mail Enable\Config\DKIM-<domain>.SYS` | DKIM config per domain |
| `C:\Program Files (x86)\Mail Enable\Config\SMTP-WHITELIST.SYS` | IP whitelist for DNSBL bypass |
| `C:\Program Files (x86)\Mail Enable\Queues\SMTP\Outgoing\Messages\` | Outbound mail queue |
| `C:\Program Files (x86)\Mail Enable\Logging\SMTP\` | SMTP activity and debug logs |
| `C:\Program Files (x86)\Mail Enable\POSTOFFICES\<project-name>staging\MAILROOT\` | Mailbox storage |
| `C:\Program Files (x86)\Mail Enable\Bin\NetWebMail\Mondo\` | Webmail application |

---

## 16. Production Cutover Plan

When testing is complete and ready to migrate production:

### Pre-Cutover (Do 24hrs Before)
```
1. Lower TTL on all production DNS records to 300 (5 mins)
   → Allows DNS change to propagate quickly on cutover day
2. Document all existing production mailboxes and passwords
3. Verify all production Post Offices exist on the new server
   (they were migrated via MGN but verify nothing is missing)
```

### Cutover Day
```
1. AWS MGN → mark server "Ready for cutover"
2. AWS MGN → launch cutover instance (fresh from latest replicated data)
3. Associate Elastic IP <your-elastic-ip> to the NEW cutover instance
4. RDP into cutover instance → redo MailEnable configurations:
   - SMTP Connector General tab → hostname
   - SMTP Connector Security/Relay/DNSBL tabs
   - Any new Post Offices created during testing
5. Update DNS:
   - MX records for all production domains → point to new server
   - SPF records → update IP to <your-elastic-ip>
   - DKIM TXT records → add for each production domain
   - PTR → already set on Elastic IP
6. Monitor MailEnable SMTP logs for 30 mins:
   C:\Program Files (x86)\Mail Enable\Logging\SMTP\
7. Send test mail from each production domain immediately after DNS switch
8. Verify inbound by sending to each production domain from Gmail
```

### Post-Cutover
```
1. Raise TTL on DNS records back to 3600
2. Keep old production server running for 48hrs (fallback)
3. After 48hrs stable → decommission old server
4. Update Plesk SSL certificates (expired Plesk cert noted in logs)
```

### ⚠️ Note on Plesk SSL Certificate

During testing, logs showed:
```
Warning. Current certificate Plesk expired (expiry date: 2024-9-18)
```

This expired certificate needs to be renewed before production cutover to avoid SSL warnings on web services.

---

## 17. Quick Reference — Credentials and URLs

| Item | Value |
|---|---|
| Server IP | `<your-elastic-ip>` |
| RDP | `<your-elastic-ip>:3389` |
| Webmail URL | `http://webmail.<project-name>.staging.<testing-root-domain>/Mondo/lang/sys/Login.aspx` |
| Webmail login | `testuser@<project-name>staging` / `Admin@123` |
| IMAP server | `mail.<project-name>.staging.<testing-root-domain>:993` |
| SMTP server | `mail.<project-name>.staging.<testing-root-domain>:587` |
| SMTP auth format | `username@postOfficeName` (e.g. `testuser@<project-name>staging`) |
| MailEnable logs | `C:\Program Files (x86)\Mail Enable\Logging\SMTP\` |
| MailEnable queues | `C:\Program Files (x86)\Mail Enable\Queues\SMTP\` |
| MailEnable Admin Console | Start Menu → MailEnable Administration (MMC) |

---

*Document prepared for Infinite Locus Pvt. Ltd.*  
*Full migration story: On-Premise → AWS MGN → EC2 Windows Server → MailEnable test domain setup*

---

## Phase 3B — Fresh Server MailEnable Configuration

This section covers configuring MailEnable on a freshly launched MGN test instance. This is required every time a new test instance is launched because MGN spawns a clean EC2 from replicated data — any previous MailEnable configurations are not carried over.

---

### Opening MailEnable Admin Console

Unlike the previous server where `MEAdmin.exe` was available, this version of MailEnable uses a different admin console located at:

```
C:\Program Files (x86)\Mail Enable\Admin\MailEnableAdmin.msc
```

Open via **Windows + R**:
```
C:\Program Files (x86)\Mail Enable\Admin\MailEnableAdmin.msc
```

Or create a persistent shortcut via PowerShell:

```powershell
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("C:\Users\Public\Desktop\MailEnable Admin.lnk")
$Shortcut.TargetPath = "mmc.exe"
$Shortcut.Arguments = "`"C:\Program Files (x86)\Mail Enable\Admin\MailEnableAdmin.msc`""
$Shortcut.WorkingDirectory = "C:\Program Files (x86)\Mail Enable\Admin"
$Shortcut.Save()

$Shortcut2 = $WshShell.CreateShortcut("C:\ProgramData\Microsoft\Windows\Start Menu\Programs\MailEnable Admin.lnk")
$Shortcut2.TargetPath = "mmc.exe"
$Shortcut2.Arguments = "`"C:\Program Files (x86)\Mail Enable\Admin\MailEnableAdmin.msc`""
$Shortcut2.WorkingDirectory = "C:\Program Files (x86)\Mail Enable\Admin"
$Shortcut2.Save()
```

> **Note:** The console opens at Post Offices view by default. Press the **Home key** in the left panel to navigate up to the full `MailEnable Management` root tree.

![MailEnable Admin Console Full Tree — New Server](../../Images/14-new-server-mmc-tree.png)

---

### Creating the Post Office

Right-click **Post Offices** in the left panel → **New Post Office**:

![Create New Post Office Dialog](../../Images/15-create-postoffice.png)

```
Post Office Name: <project-name>staging
Password:         <set a strong password>
Confirm Password: <same>
→ OK
```

> **Why short name:** Post Office names must be under 20 characters with no dots or special characters. Use a short identifier — the actual domain is added separately under Domains.

Then add the domain:
```
Post Offices → <project-name>staging → Domains
→ Right-click → Add Domain
    Domain Name: <project-name>.staging.<testing-root-domain>
    Postmaster:  postmaster
    → OK → No (when aliases popup appears)
```

---

### Creating Mailboxes

```
Post Offices → <project-name>staging → Mailboxes
→ Right-click → New Mailbox
```

![Create New Mailbox Dialog](../../Images/16-create-mailbox.png)

Create two mailboxes:

```
Mailbox 1:
  Name:     admin
  Password: <set password>
  Type:     USER

Mailbox 2:
  Name:     testuser
  Password: Admin@123
  Type:     USER
```

After creation, three mailboxes should be listed:
```
admin        Enabled  Unlimited
postmaster   Enabled  Unlimited  ← auto-created with Post Office
testuser     Enabled  Unlimited
```

![Mailboxes List — admin, postmaster, testuser](../../Images/02-mailenable-mailboxes.png)

---

### SMTP Connector Configuration

```
Servers → localhost → Services and Connectors → SMTP
→ Right-click → Properties
```

**General tab:**

![SMTP Connector — General Tab](../../Images/03-smtp-general.png)

```
Local Domain Name:          mail.<project-name>.staging.<testing-root-domain>
Default mail domain name:   <project-name>.staging.<testing-root-domain>
DNS Address(es):            8.8.8.8 8.8.4.4
Notification email:         postmaster@<project-name>.staging.<testing-root-domain>
```

**Inbound tab:**

![SMTP Connector — Inbound Tab](../../Images/04-smtp-inbound.png)

```
Port 25:  enabled  ← server-to-server inbound
Port 587: enabled  ← authenticated client submission
✅ STARTTLS enabled
```

**Relay tab:**

![SMTP Connector — Relay Tab](../../Images/05-smtp-relay.png)

```
✅ Allow Mail Relay
✅ Allow relay for authenticated senders only
❌ Allow relay for privileged IP ranges
❌ Allow relay for local sender addresses  ← NEVER enable this
```

**Security tab:**

![SMTP Connector — Security Tab](../../Images/06-smtp-security.png)

```
✅ Sender email domain must be local or resolvable through DNS
✅ Authenticated senders must use address from their postoffice
PTR Record Check: Reject mail from senders without PTR records
```

**DNS Blacklisting tab:**

![SMTP Connector — DNS Blacklisting Tab](../../Images/07-smtp-dnsbl.png)

```
✅ Enable DNS blacklisting
→ Add: SpamhausZEN
→ Add: Spamcop
→ Add: Barracuda Reputation Block List

✅ Enable URL Blacklisting
→ Add: dbl.spamhaus.org
```

**Delivery tab:**
```
Failed message lifetime: 72 hours
✅ Only generate NDRs for senders who authenticate
✅ Limit concurrent connections: 20
```

**Advanced SMTP tab:**
```
✅ Add required headers for authenticated senders
❌ EXPN command  ← disable
❌ HELP command  ← disable
```

**Smart Host tab:**
```
❌ Smart Host Enabled  ← leave disabled (direct delivery via port 25)
```

→ **Apply → OK**

---

### DKIM Key Generation

Run in PowerShell as Administrator:

```powershell
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
$privateKeyBytes = $rsa.ExportCspBlob($true)
$privateKeyB64 = [Convert]::ToBase64String($privateKeyBytes, 'InsertLineBreaks')
$privateKeyPem = "-----BEGIN RSA PRIVATE KEY-----`r`n$privateKeyB64`r`n-----END RSA PRIVATE KEY-----"
$privateKeyPem | Out-File "C:\Program Files (x86)\Mail Enable\Config\DKIM\default-<project-name>.staging.<testing-root-domain>.key" -Encoding ASCII

$dkimConfig = '<BASEELEMENT><ELEMENT><TYPE>Selector</TYPE><SELECTORNAME>default</SELECTORNAME><DNS-TXT>v=DKIM1; </DNS-TXT></ELEMENT><ELEMENT><TYPE>Options</TYPE><ACTIVESELECTOR>default</ACTIVESELECTOR><KEYFILE>default-<project-name>.staging.<testing-root-domain>.key</KEYFILE><SIGN>1</SIGN><HASHALGORITHM>rsa-sha256</HASHALGORITHM><HEADERCANONICALIZATION>relaxed</HEADERCANONICALIZATION><BODYCANONICALIZATION>relaxed</BODYCANONICALIZATION><LIMITBODYHASHLENGTH>-1</LIMITBODYHASHLENGTH><INCLUDEUSERIDENTITY>0</INCLUDEUSERIDENTITY></ELEMENT></BASEELEMENT>'
$dkimConfig | Out-File "C:\Program Files (x86)\Mail Enable\Config\DKIM-<project-name>.staging.<testing-root-domain>.SYS" -Encoding ASCII
```

Extract public key for DNS:

```powershell
$rsa2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rawKey = (Get-Content "C:\Program Files (x86)\Mail Enable\Config\DKIM\default-<project-name>.staging.<testing-root-domain>.key" -Raw)
$b64 = $rawKey -replace "-----BEGIN RSA PRIVATE KEY-----|-----END RSA PRIVATE KEY-----" -replace "\s",""
$rsa2.ImportCspBlob([Convert]::FromBase64String($b64))
$params = $rsa2.ExportParameters($false)

function Encode-DERLength($len) {
    if ($len -lt 128) { return [byte[]]@($len) }
    elseif ($len -lt 256) { return [byte[]]@(0x81, $len) }
    else { return [byte[]]@(0x82, [byte](($len -shr 8) -band 0xFF), [byte]($len -band 0xFF)) }
}
function Encode-DERInteger($bytes) {
    if ($bytes[0] -band 0x80) { $bytes = @([byte]0x00) + $bytes }
    return @([byte]0x02) + (Encode-DERLength $bytes.Length) + $bytes
}
$modInt = Encode-DERInteger $params.Modulus
$expInt = Encode-DERInteger $params.Exponent
$seqContent = $modInt + $expInt
$sequence = @([byte]0x30) + (Encode-DERLength $seqContent.Length) + $seqContent
Write-Host "p=$([Convert]::ToBase64String([byte[]]$sequence))"
```

Add the output to GoDaddy DNS:

```
Type:   TXT
Name:   default._domainkey.<project-name>.staging
Value:  v=DKIM1; k=rsa; p=<output from above>
TTL:    600
```

---

### Webmail IIS Binding

```powershell
New-WebBinding -Name "MailEnable WebMail" -Protocol "http" -Port 80 -HostHeader "webmail.<project-name>.staging.<testing-root-domain>"
```

Add DNS A record in GoDaddy:
```
Type:  A
Name:  webmail.<project-name>.staging
Value: <your-elastic-ip>
TTL:   600
```

Access webmail at:
```
http://webmail.<project-name>.staging.<testing-root-domain>/Mondo/lang/sys/Login.aspx
```

![MailEnable Webmail Login Page](../../Images/21-webmail-login-new.png.png)

Login format:
```
Username: testuser@<project-name>staging    ← Post Office name, not full domain
Password: <your password>
```

---

### Restart Services

```powershell
Restart-Service "MailEnable SMTP Connector"
Restart-Service "MailEnable Mail Transfer Agent"
```

---

### Plesk License Retrieval

```powershell
& "C:\Program Files (x86)\Plesk\bin\plesk.exe" bin license --retrieve
```

Expected output:
```
Updating license key EXT.XXXXXXXXX.XXXX: Done
```

---

### Windows Firewall Rules

```powershell
New-NetFirewallRule -DisplayName "MailEnable SMTP" -Direction Inbound -Protocol TCP -LocalPort 25 -Action Allow
New-NetFirewallRule -DisplayName "MailEnable Submission" -Direction Inbound -Protocol TCP -LocalPort 587 -Action Allow
New-NetFirewallRule -DisplayName "MailEnable IMAP SSL" -Direction Inbound -Protocol TCP -LocalPort 993 -Action Allow
New-NetFirewallRule -DisplayName "MailEnable POP3 SSL" -Direction Inbound -Protocol TCP -LocalPort 995 -Action Allow
New-NetFirewallRule -DisplayName "MailEnable IMAP" -Direction Inbound -Protocol TCP -LocalPort 143 -Action Allow
```

---

### Phase 3B Checklist

```
□ Windows Firewall rules added
□ Post Office created (<project-name>staging)
□ Domain added (<project-name>.staging.<testing-root-domain>)
□ Mailboxes created (admin, testuser)
□ SMTP Connector configured (all tabs)
□ DKIM key generated
□ DKIM TXT record added to GoDaddy
□ Webmail IIS binding added
□ Services restarted
□ Plesk license retrieved
□ Send test mail → confirm delivery
□ Receive test mail → confirm inbound
```
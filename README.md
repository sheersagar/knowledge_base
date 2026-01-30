# DevOps Personal Knowledge Base

This repository is a **private, problem-oriented knowledge base** for recording:
- troubleshooting journeys
- architectural understanding
- cloud service behavior
- experiments, PoCs, and incidents
- frequently used commands and references

The goal is **fast retrieval under pressure**, not documentation completeness.

---

## Core Philosophy

This knowledge base is structured around **intent**, not tools.

When something breaks, future-me should know:
- *where to look*
- *what kind of information to expect*
- *how deep to read*

Folders are intentionally **few and stable**.  
Complexity lives **inside files**, not in directory trees.

---

## Folder Overview


---

## 00-index/

**Purpose:**  
High-level navigation and planning.

**Contains:**
- `README.md` – how to use this knowledge base
- `search-map.md` – where to look when stuck
- `tags.md` – tag taxonomy
- `learning-backlog.md` – topics to explore later

**Does NOT contain:**
- Technical knowledge
- Commands
- Troubleshooting steps

---

## 01-concepts/

**Purpose:**  
Explain **how systems work**.

This folder builds **mental models**, not solutions.

**Typical content:**
- Networking fundamentals
- Linux internals
- Kubernetes architecture
- Cloud-agnostic concepts
- Security theory

**Examples:**
- `dns-resolution-flow.md`
- `pod-lifecycle.md`
- `iam-fundamentals.md`

**Rules:**
- No step-by-step debugging
- No command dumps
- Should still make sense years later

---

## 02-playbooks/

**Purpose:**  
Answer: **“Something is broken — what do I do?”**

This is the **on-call survival folder**.

**Typical content:**
- Symptom-based troubleshooting
- Investigation order
- Decision trees
- What to check next

**Examples:**
- `dns-not-resolving.md`
- `pods-in-crashloop.md`
- `aws-access-denied.md`

**Rules:**
- Must be actionable
- Optimized for stress situations
- Can reference `03-reference` for commands
- Can link to `01-concepts` for understanding

---

## 03-reference/

**Purpose:**  
Answer: **“What command / syntax do I need?”**

This is **lookup-only**, not reading material.

**Typical content:**
- CLI cheat sheets
- Command flags
- YAML snippets
- Option mappings
- Tool quirks

**Examples:**
- `kubectl-cheatsheet.md`
- `networking-commands.md`
- `dockerfile-patterns.md`

**Rules:**
- No explanations or storytelling
- No troubleshooting flow
- Scannable, copy-paste friendly

---

## 04-cloud/

**Purpose:**  
Document **cloud-provider-specific behavior and services**.

This is **how AWS/Azure/GCP actually implement things**.

**Structure:**
- One file per major service
- Flat structure inside each provider

**Examples:**
- `aws/ecs.md`
- `aws/iam.md`
- `azure/aks.md`
- `gcp/iam.md`

**Rules:**
- One service = one primary file
- Use headings instead of subfolders
- High-level failure patterns allowed
- Deep troubleshooting goes to `02-playbooks`

---

## 05-labs-poc/

**Purpose:**  
Capture **experiments, proofs-of-concept, and learning exercises**.

This is where exploration lives.

**Typical content:**
- Kubernetes labs
- Terraform experiments
- CI/CD tests
- Performance experiments

**Examples:**
- `hpa-testing.md`
- `network-policy-lab.md`
- `blue-green-deploy.md`

**Rules:**
- Not production incidents
- Can be messy and exploratory
- Valuable for future reference

---

## 06-incidents/

**Purpose:**  
Record **real production issues and postmortems**.

This is the **most valuable folder over time**.

**Typical content:**
- Timeline of events
- Root cause
- Fix
- Prevention steps

**Structure:**
- One file per incident
- Grouped by year

**Rules:**
- No theory
- No hypotheticals
- Only what actually happened

---

## assets/

**Purpose:**  
Store supporting material.

**Contains:**
- Images
- Diagrams
- Screenshots
- GIFs

Referenced from markdown files only.

---

## Naming Convention (Important)

Files are named using **problem-first language**:


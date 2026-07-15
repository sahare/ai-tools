# agentic-ols Knowledge Base

Everything learned through deep-dive and live testing (Jun 2026).
Use this as the reference for adding new ACM component skills.

**Repo:** https://github.com/stolostron/agentic-ols
**Local clone:** `/Users/sahare/workspace/src/github.com/sahare/agentic-ols`

---

## What is agentic-ols?

It turns ACM expert knowledge into **AI-readable "skills"** that an autonomous agent
can follow to diagnose live clusters — without a chat UI.

**What it is NOT:** It is not an application you deploy. It is a **content library**:
Markdown skill files + shell scripts packaged as an OCI container image, mounted into
an AI agent sandbox pod at runtime.

**The runtime (OpenShift Lightspeed)** is the actual operator that:
1. Receives a `Proposal` CR from a user/automation
2. Spins up a sandbox pod with your skills image mounted
3. Connects the sandbox to an LLM
4. Runs the analysis and writes an `AnalysisResult` CR

**Simple analogy:** agentic-ols = the troubleshooting runbooks. Lightspeed = the SRE
who reads them and does the work.

---

## Architecture

```
You apply a Proposal YAML
        ↓
Lightspeed Agentic Operator
  - creates sandbox pod
  - mounts skills OCI image as volume
  - injects LLM credentials
        ↓
Sandbox pod (Python FastAPI + OpenAI Agents SDK)
  - reads SKILL.md + scripts from /skills/...
  - calls LLM for reasoning
  - runs kubectl/curl/psql on the cluster
  - writes structured AnalysisResult
        ↓
AnalysisResult CR in openshift-lightspeed namespace
```

### Key CRDs

| CRD | Purpose |
|---|---|
| `LLMProvider` | Configures which LLM backend to use (OpenAI, Vertex, Bedrock) |
| `Agent` | References an LLMProvider + model name |
| `Proposal` | The "question" you submit — references a skills image + request text |
| `AnalysisResult` | The agent's structured answer written back to the cluster |

### Skill taxonomy (three types)

| Type | Folder pattern | Purpose |
|---|---|---|
| **Expertise** | `{component}/` | Architecture docs, code analysis — "how does this work" |
| **Impact** | `{component}-impact/` | Live diagnostics with scripts — "is it healthy right now" |
| **Architecture** | `{pillar}-architecture/` | Cross-component routing — "which skill handles this symptom" |

For ACM Search, only `search-indexer-impact` has working scripts today.
`search-api-impact`, `search-collector-impact`, `search-operator-impact` are new/stubs.

---

## LLM Setup — Vertex AI / Claude (Recommended)

The team uses **Google Cloud Vertex AI with Claude** via a shared GCP project.
This is the standard setup — production quality, no personal cost, no networking hacks needed.

### GCP Project Details

- **Project:** `itpc-gcp-hcm-pe-eng-claude`
- **Region:** `us-east5`
- **Model:** `claude-sonnet-4@20250514` (Vertex uses `@date` versioning; Vertex auto-selects latest if omitted)
- **Admin:** Ask jbanerje for access — he manages service accounts in this project

Service accounts follow the pattern:
`ls-<name>@itpc-gcp-hcm-pe-eng-claude.iam.gserviceaccount.com`

### Step 1: Get a service account key

```bash
# Ask jbanerje to create one for you, or if you have access:
gcloud iam service-accounts keys create /tmp/vertex-sa-key.json \
  --iam-account=ls-<yourname>@itpc-gcp-hcm-pe-eng-claude.iam.gserviceaccount.com \
  --project=itpc-gcp-hcm-pe-eng-claude
```

### Step 2: Create credentials secret on cluster

```bash
# Key name MUST be GOOGLE_APPLICATION_CREDENTIALS (entire JSON key file as value)
oc create secret generic llm-creds-vertex \
  --from-file=GOOGLE_APPLICATION_CREDENTIALS=/tmp/vertex-sa-key.json \
  -n openshift-lightspeed
```

### Step 3: Create LLMProvider

```bash
cat <<EOF | oc apply -f -
apiVersion: agentic.openshift.io/v1alpha1
kind: LLMProvider
metadata:
  name: vertex-anthropic
  namespace: openshift-lightspeed
spec:
  type: GoogleCloudVertex
  googleCloudVertex:
    projectID: "itpc-gcp-hcm-pe-eng-claude"
    region: "us-east5"
    modelProvider: Anthropic
    credentialsSecret:
      name: llm-creds-vertex
EOF
```

### Step 4: Create Agent

```bash
cat <<EOF | oc apply -f -
apiVersion: agentic.openshift.io/v1alpha1
kind: Agent
metadata:
  name: default
  namespace: openshift-lightspeed
spec:
  llmProvider:
    name: vertex-anthropic
  model: "claude-sonnet-4@20250514"
  timeouts:
    analysisSeconds: 120
    executionSeconds: 120
    verificationSeconds: 120
EOF
```

---

## Full Setup Guide (Fresh Cluster)

### Prerequisites checklist

- [ ] OpenShift cluster (OCP 4.21+, Kubernetes 1.34+)
- [ ] ACM 5.0 installed (use `install-acm.sh` from acm-cluster-setup)
- [ ] GCP service account key file at `/tmp/vertex-sa-key.json`

### Step 1: Install agentic operator

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/openshift/lightspeed-agentic-operator/main/hack/quickstart/install.sh)
```

Wait for pods:
```bash
oc get pods -n openshift-lightspeed -w
# Expected: lightspeed-agentic-operator + lightspeed-agentic-console-plugin running
```

### Step 2: Configure LLM (Vertex/Claude)

Follow the four steps in the **LLM Setup** section above.

### Step 3: Apply extended RBAC

```bash
oc apply -f /path/to/agentic-ols/rbac/agent-extended.yaml
```

This grants Prometheus access + pod exec (needed for database diagnostics).

### Step 4: Add pull secret for skills image

The sandbox pod pulls the skills OCI image. If it's in a private quay repo:
```bash
oc create secret docker-registry quay-skills \
  --docker-server=quay.io \
  --docker-username=<user> \
  --docker-password='<password>' \
  -n openshift-lightspeed

oc patch serviceaccount default -n openshift-lightspeed \
  --type=json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-skills"}}]'
oc patch serviceaccount lightspeed-agent -n openshift-lightspeed \
  --type=json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-skills"}}]'
```

### Step 5: Submit a proposal and verify

```bash
oc apply -f proposals/search-indexer-health.yaml

# Read the result
RESULT=$(oc get proposal search-indexer-health -n openshift-lightspeed \
  -o jsonpath='{.status.steps.analysis.results[0].name}')
oc get analysisresult "$RESULT" -n openshift-lightspeed \
  -o jsonpath='{.status.options[0].diagnosis.summary}'
```

---

## Known Issues and Gotchas

### 1. LLMProvider type and secret key differ by backend

| Backend | `spec.type` | Secret key name | Secret value |
|---|---|---|---|
| Vertex / Claude | `GoogleCloudVertex` | `GOOGLE_APPLICATION_CREDENTIALS` | Full JSON SA key file |
| OpenAI | `OpenAI` | `OPENAI_API_KEY` | API key string |

Do not mix them up — e.g. using `OPENAI_API_KEY` for a Vertex provider will fail silently.

### 2. Skills image pull fails (ImagePullBackOff)

The sandbox pod pulls the skills image at runtime. If your quay.io repo is private,
the cluster needs a pull secret (see Step 4 above). Alternatively, make the image public
on quay.io to skip this step entirely.

### 3. Building skills image requires linux/amd64

The Makefile uses `podman`. If you only have Docker:
```bash
docker buildx build --platform linux/amd64 \
  -t quay.io/<user>/acm-agentic-skills:tag . --push
```

---

## How to Build a New Skill (Step-by-Step)

Use `search-indexer-impact` as the reference. Here's the pattern:

### Step 1: Create the directory structure

```bash
mkdir -p skills/search/search-COMPONENT-impact/scripts
mkdir -p skills/search/search-COMPONENT-impact/templates
```

### Step 2: Write diagnostic scripts

Each script should:
- Collect one category of data (Prometheus, kubectl, psql, etc.)
- Print human-readable output (the agent reads it)
- Exit cleanly even if data is unavailable

```bash
# scripts/component-health.sh
#!/bin/bash
NAMESPACE="${NAMESPACE:-open-cluster-management}"
echo "=== Component Status ==="
kubectl get pods -n "$NAMESPACE" -l app=my-component 2>/dev/null
```

### Step 3: Write generate-assessment.sh (orchestrator)

This calls all the other scripts and prints a combined report that the agent reads.

### Step 4: Write SKILL.md

Structure:
1. `name` + `description` in YAML frontmatter
2. **Purpose** — when to use this skill
3. **When to Use** — specific symptoms that trigger this skill
4. **Key Concepts** — architecture the agent needs to understand
5. **Assessment Methodology** — step-by-step what the agent should do
6. **Health Thresholds** — table of healthy vs degraded vs critical values
7. **Confidence Scoring** — how to assign confidence level
8. **Output Format** — explicit list of all required AnalysisResult fields
9. **Standalone Usage** — how to run scripts manually

### Step 5: Build and push

```bash
docker buildx build --platform linux/amd64 \
  -t quay.io/<user>/acm-agentic-skills:tag . --push
```

### Step 6: Create a Proposal CR

```bash
cat <<EOF | oc apply -f -
apiVersion: agentic.openshift.io/v1alpha1
kind: Proposal
metadata:
  name: my-component-health
  namespace: openshift-lightspeed
spec:
  request: |
    Using the search-COMPONENT-impact skill, assess the health of...
  tools:
    skills:
      - image: quay.io/<user>/acm-agentic-skills:tag
        paths:
          - /skills/search/search-COMPONENT-impact
  analysis:
    agent: default
EOF
```

---

## Applying This to cluster-backup-operator

For a `cluster-backup-operator-impact` skill, you would check:

**Diagnostic scripts to write:**

1. **`backup-schedule-health.sh`** — check `BackupSchedule` phase
   (New/Enabled/FailedValidation/BackupCollision/Paused)
2. **`restore-status.sh`** — check active `Restore` CRs and their phases
3. **`oadp-health.sh`** — check OADP operator, DataProtectionApplication, BSL availability
4. **`velero-pods.sh`** — check Velero pod health and recent backup/restore objects
5. **`collision-check.sh`** — detect BackupCollision (two hubs writing to same S3)
6. **`bsl-connectivity.sh`** — test if BackupStorageLocation is actually reachable

**SKILL.md would document:**
- The 5 BackupSchedule phases and what causes each
- The active/passive hub pattern
- The collision detection logic
- The MSA auto-import flow for managed cluster reconnection
- When to recommend `cleanupBeforeRestore: None` vs `CleanupRestored` vs `CleanupAll`

Reference the existing backup triage knowledge at `ai-tools/projects/acm-backup-triage/KNOWLEDGE_BASE.md`.

---

## Quick Reference

```bash
# Install agentic operator
bash <(curl -fsSL https://raw.githubusercontent.com/openshift/lightspeed-agentic-operator/main/hack/quickstart/install.sh)

# Create Vertex/Claude credentials secret
oc create secret generic llm-creds-vertex \
  --from-file=GOOGLE_APPLICATION_CREDENTIALS=/tmp/vertex-sa-key.json \
  -n openshift-lightspeed

# Apply RBAC
oc apply -f /path/to/agentic-ols/rbac/agent-extended.yaml

# Read proposal result
RESULT=$(oc get proposal <name> -n openshift-lightspeed \
  -o jsonpath='{.status.steps.analysis.results[0].name}')
oc get analysisresult "$RESULT" -n openshift-lightspeed \
  -o jsonpath='{.status.options[0].diagnosis.summary}'

# Build and push skills image
cd /path/to/agentic-ols
docker buildx build --platform linux/amd64 \
  -t quay.io/saharebrahimi/acm-agentic-skills:tag . --push
```

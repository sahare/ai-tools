# agentic-ols Knowledge Base

Everything learned through deep-dive and live testing (Jun 22 2026).
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
| `LLMProvider` | Configures which LLM backend to use (OpenAI, Ollama, Vertex, Bedrock) |
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

## What Ollama Is

**Ollama** is a tool that runs AI language models locally on your computer.
Instead of sending data to OpenAI's servers, the model runs on your Mac.

- Model file (`granite3.3:8b` = ~5GB) lives on your disk
- Ollama loads it into your GPU/CPU RAM
- Exposes an OpenAI-compatible HTTP API on port 11434
- The agentic operator calls `http://your-ip:11434/v1` like it calls OpenAI

**Why use it:** free, private, no internet dependency, no per-token cost.

**Limitation:** smaller local models (8B params) may not follow complex JSON schemas
reliably. GPT-4 or Claude follow structured outputs much more precisely.

### Ollama setup for agentic-ols

```bash
# Install
brew install ollama

# Start with external access (so cluster pods can reach it)
# CRITICAL: OLLAMA_ORIGINS=* is needed to allow cross-origin requests from the cluster
OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS=* ollama serve &

# Verify it's accessible externally
curl http://$(ipconfig getifaddr en0):11434/v1/models

# List available models
ollama list
```

**Recommended models for agentic-ols:**

| Model | Size | Quality | Notes |
|---|---|---|---|
| `granite3.3:8b` | 5GB | Medium | IBM's enterprise model, good for infra reasoning. May miss schema fields. |
| `llama3:8b` | 5GB | Medium | Good general reasoning |
| `mistral:7b` | 4GB | Medium | Fast, decent structured output |
| `llama3:70b` | 40GB | High | Much better schema compliance, needs more RAM |
| GPT-4 (cloud) | — | Best | Most reliable structured output, requires OpenAI API key |
| Claude 3.5 (cloud) | — | Best | Also excellent, requires Anthropic key |

**Known issue with granite3.3:8b:** It often misses the `proposal.estimatedImpact`
field in the AnalysisResult schema. The skill's SKILL.md output format section must
explicitly mention this field with an example for it to reliably include it.

### Ollama alternatives

| Tool | What it is | Use when |
|---|---|---|
| **Ollama** (recommended) | Easy local model runner | Hackathons, dev testing |
| **LM Studio** | GUI for running models locally | If you prefer a UI |
| **llama.cpp server** | Bare-metal local inference | Maximum performance control |
| **OpenAI API** | Cloud, paid, most reliable | Production, when schema compliance matters |
| **AWS Bedrock** | Cloud, IAM-auth, enterprise | If already on AWS |
| **Red Hat RHAI** | Internal Red Hat AI service | Work projects (no personal API key needed) |

---

## What ngrok Is

**ngrok** is a tool that creates a secure tunnel from the public internet to a port
on your local machine.

The cluster runs in AWS. Your Mac is on your home network. They can't communicate.
ngrok gives your Ollama a public URL that the cluster can reach:

```
Cluster (AWS) → https://abc123.ngrok-free.app → ngrok tunnel → your Mac:11434 → Ollama
```

**Nothing special about your data** — ngrok just forwards encrypted bytes. The actual
AI inference still happens on your Mac.

### ngrok setup

```bash
# Install
brew install ngrok/ngrok/ngrok

# Sign up (free, just email) at dashboard.ngrok.com
ngrok config add-authtoken <your-token>

# Start tunnel to Ollama
ngrok http 11434
```

ngrok prints: `Forwarding https://abc123.ngrok-free.app -> http://localhost:11434`
Use that URL as the `openAI.url` in your LLMProvider CR.

### ngrok alternatives

| Tool | What it is | Notes |
|---|---|---|
| **ngrok** (recommended) | Tunnel service | Free tier, fast setup |
| **cloudflared** | Cloudflare Tunnel | Free, no account limit |
| **tailscale** | VPN mesh | More permanent solution, integrates with corp VPN |
| **Deploy Ollama on cluster** | Kubernetes pod | Most permanent, requires GPU node or lots of CPU |
| **Cloud LLM** | OpenAI/Bedrock/RHAI | Eliminates the networking problem entirely |

---

## Full Setup Guide (Fresh Cluster)

### Prerequisites checklist

- [ ] OpenShift cluster (OCP 4.21+, Kubernetes 1.34+)
- [ ] ACM 5.0 installed (use `install-acm.sh` from acm-cluster-setup)
- [ ] Ollama running with `OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS=* ollama serve`
- [ ] ngrok tunnel running: `ngrok http 11434`
- [ ] Note your ngrok URL: `https://xxx.ngrok-free.app`

### Step 1: Install agentic operator

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/openshift/lightspeed-agentic-operator/main/hack/quickstart/install.sh)
```

Wait for pods:
```bash
oc get pods -n openshift-lightspeed -w
# Expected: lightspeed-agentic-operator + lightspeed-agentic-console-plugin running
```

### Step 2: Create credentials secret

The secret key MUST be `OPENAI_API_KEY` (even for Ollama — it's just an API compatibility convention):
```bash
oc create secret generic ollama-credentials \
  --from-literal=OPENAI_API_KEY=ollama-no-key \
  -n openshift-lightspeed
```

### Step 3: Create LLMProvider

```bash
cat <<EOF | oc apply -f -
apiVersion: agentic.openshift.io/v1alpha1
kind: LLMProvider
metadata:
  name: ollama-granite
  namespace: openshift-lightspeed
spec:
  type: OpenAI
  openAI:
    url: https://YOUR-NGROK-URL.ngrok-free.app/v1
    credentialsSecret:
      name: ollama-credentials
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
    name: ollama-granite
  model: granite3.3:8b
EOF
```

### Step 5: Apply extended RBAC

```bash
oc apply -f /path/to/agentic-ols/rbac/agent-extended.yaml
```

This grants Prometheus access + pod exec (needed for database diagnostics).

### Step 6: Verify sandbox readiness

Submit a test proposal and check the sandbox pod's `/ready` endpoint:
```bash
# Submit proposal
oc apply -f proposals/search-indexer-health.yaml

# Wait for sandbox pod, then check readiness
oc exec -n openshift-lightspeed ls-analysis-search-indexer-health -- \
  curl -s http://localhost:8080/ready
# Should return: {"status":"ok"}
```

If `/ready` returns `{"status":"error","checks":{"provider_env":"error: missing OPENAI_API_KEY"}}`:
→ The secret key name is wrong. Recreate it with key `OPENAI_API_KEY` (not `apiKey`).

If `/ready` returns 503 with `"provider_endpoint":"error"`:
→ The sandbox can't reach your Ollama. Check ngrok is running and Ollama has `OLLAMA_ORIGINS=*`.

---

## Known Issues and Gotchas

### 1. Secret key must be `OPENAI_API_KEY`

Even for Ollama (which doesn't use an API key), the sandbox reads the `OPENAI_API_KEY`
env var. If you create the secret with a different key name (like `apiKey`), the sandbox
reports `/ready` → 503 with "missing OPENAI_API_KEY". Fix:
```bash
oc delete secret ollama-credentials -n openshift-lightspeed
oc create secret generic ollama-credentials \
  --from-literal=OPENAI_API_KEY=ollama-no-key \
  -n openshift-lightspeed
```

### 2. Ollama CORS blocks cluster requests (403 Forbidden)

By default Ollama only accepts connections from known origins. The cluster pods
are treated as foreign and get 403. Fix: always start Ollama with `OLLAMA_ORIGINS=*`:
```bash
OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS=* ollama serve &
```

### 3. Smaller LLMs miss AnalysisResult schema fields

The AnalysisResult CRD has strict required fields in `status.options[0]`:
- `diagnosis.confidence`, `diagnosis.rootCause`, `diagnosis.summary` (required)
- `proposal.description`, `proposal.estimatedImpact`, `proposal.actions`, `proposal.risk` (required)
- `verification.description` (required)

granite3.3:8b often misses `proposal.estimatedImpact` or `proposal.actions`.
**Fix:** Make the skill's SKILL.md output section explicitly list all required fields
with examples. The sandbox includes the SKILL.md in the LLM prompt.

Example of what to add to SKILL.md:
```
## Output Format

Your response MUST include ALL these fields:

diagnosis.confidence: "High" | "Medium" | "Low"
diagnosis.rootCause: one sentence
diagnosis.summary: paragraph

proposal.description: what to do
proposal.estimatedImpact: "Expected improvement (e.g. latency reduced by X%)"
proposal.actions:
  - Step 1
  - Step 2
proposal.risk: "Low" | "Medium" | "High"

verification.description: how to verify the fix
```

### 4. Skills image pull fails (ImagePullBackOff)

The sandbox pod tries to pull your custom skills image. If it's in a private quay repo:
```bash
# Create pull secret in openshift-lightspeed namespace
oc create secret docker-registry quay-skills \
  --docker-server=quay.io \
  --docker-username=<user> \
  --docker-password='<password>' \
  -n openshift-lightspeed

# Patch the service accounts
oc patch serviceaccount default -n openshift-lightspeed \
  --type=json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-skills"}}]'
oc patch serviceaccount lightspeed-agent -n openshift-lightspeed \
  --type=json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-skills"}}]'
```

### 5. Building skills image requires podman not docker

The Makefile uses `podman`. If you only have Docker:
```bash
# Override in Makefile or use directly:
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
8. **Output Format** — EXPLICIT list of all required AnalysisResult fields (critical for small LLMs)
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
    [Include explicit reminder about required output fields]
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
# Ollama start (correct)
OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS=* ollama serve &

# ngrok tunnel
ngrok http 11434

# Install agentic operator
bash <(curl -fsSL https://raw.githubusercontent.com/openshift/lightspeed-agentic-operator/main/hack/quickstart/install.sh)

# Check sandbox readiness
oc exec -n openshift-lightspeed <sandbox-pod> -- curl -s http://localhost:8080/ready

# Read proposal result
RESULT=$(oc get proposal <name> -n openshift-lightspeed \
  -o jsonpath='{.status.steps.analysis.results[0].name}')
oc get analysisresult "$RESULT" -n openshift-lightspeed \
  -o jsonpath='{.status.options[0].diagnosis.summary}'

# Build skills image with Docker (not podman)
cd /path/to/agentic-ols
docker buildx build --platform linux/amd64 \
  -t quay.io/saharebrahimi/acm-agentic-skills:tag . --push

# Check if agent can reach Ollama (from inside sandbox)
oc exec -n openshift-lightspeed <sandbox-pod> -- \
  python3 -c "
import urllib.request, ssl, json
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
req = urllib.request.Request(
  'https://YOUR-NGROK-URL/v1/chat/completions',
  data=json.dumps({'model':'granite3.3:8b','messages':[{'role':'user','content':'hi'}],'max_tokens':5}).encode(),
  headers={'Content-Type':'application/json','Authorization':'Bearer ollama-no-key'}
)
r = urllib.request.urlopen(req, context=ctx, timeout=30)
print('Status:', r.status)
"
```

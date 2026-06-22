# agentic-ols

Knowledge base and skills for the [stolostron/agentic-ols](https://github.com/stolostron/agentic-ols) project.

## Contents

- **[KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md)** — Deep-dive reference: what agentic-ols is, Ollama/ngrok setup, LLM options, known issues, how to build new skills, and a roadmap for cluster-backup-operator skills

---

## How It All Works — Simple End-to-End Flow

This explains what actually happened during the live test (Jun 22 2026), in simple terms.

### Where everything runs

```
Your Mac (Sahar's laptop)
  └── Ollama (granite3.3:8b model, port 11434)
  └── ngrok (tunnel, port 4040)

OpenShift Cluster (AWS us-west-2)
  └── Namespace: open-cluster-management
  │     └── ACM Search components (search-collector, search-indexer, etc.)
  └── Namespace: openshift-lightspeed
        └── lightspeed-agentic-operator     ← the "director"
        └── lightspeed-agentic-console-plugin
        └── ls-analysis-search-indexer-health  ← the "sandbox" (temporary pod)
```

### What is the "sandbox pod"?

The sandbox is a **temporary worker pod** the operator creates for each Proposal.
Think of it like a contractor hired for one job:
1. Created when you submit a Proposal
2. Given the skills (SKILL.md + scripts) as a mounted volume
3. Connected to the LLM
4. Does the analysis work
5. Writes the result
6. Sits idle (stays running for debugging, but the job is done)

The sandbox runs a Python FastAPI server that:
- Exposes `/health` (is it alive?)
- Exposes `/ready` (can it reach the LLM?)
- Accepts `/v1/agent/run` (run the analysis)

### The end-to-end flow in plain English

```
STEP 1 — You apply a Proposal YAML to the cluster
   oc apply -f proposals/search-indexer-health.yaml
   → This creates a Proposal CR in openshift-lightspeed namespace

STEP 2 — The Lightspeed Agentic Operator sees the new Proposal
   → It creates a "sandbox" pod: ls-analysis-search-indexer-health
   → It injects environment variables: LIGHTSPEED_MODEL=granite3.3:8b,
     LIGHTSPEED_PROVIDER_URL=https://ngrok-url/v1, OPENAI_API_KEY=...
   → It mounts the skills image as a volume at /skills/

STEP 3 — The sandbox pod starts up
   → Runs a Python server on port 8080
   → /health returns 200 immediately (server is alive)
   → /ready tests the LLM connection:
       POST https://ngrok-url/v1/chat/completions with a test message
       Returns 200 if LLM responds, 503 if not
   → Operator polls /ready waiting for it to become 200

STEP 4 — Operator sends the analysis request to the sandbox
   → POST http://sandbox-pod:8080/v1/agent/run
   → Payload: the request text from the Proposal + skill paths

STEP 5 — The sandbox reads the skill and calls the LLM
   → Reads /skills/search/search-indexer-impact/SKILL.md
   → Reads the scripts under /skills/.../scripts/
   → Sends ALL of this to granite3.3:8b as context
   → Asks: "Follow this skill to assess the search indexer"

STEP 6 — granite3.3:8b reasons and tells the sandbox what to do
   → "Run this kubectl command..."
   → "Query Prometheus for this metric..."
   → "Exec into the postgres pod and run this query..."

STEP 7 — The sandbox executes commands ON THE REAL CLUSTER
   → kubectl get pods (using the service account)
   → curl http://prometheus:9090/api/v1/query (for metrics)
   → kubectl exec into search-postgres and run psql queries
   → Collects all the output and sends it back to the LLM

STEP 8 — granite3.3:8b analyzes the data and produces a diagnosis
   → Output: JSON with confidence, rootCause, summary, proposal, verification

STEP 9 — The sandbox writes the result to an AnalysisResult CR
   → If all required fields are present → AnalysisResult shows Succeeded
   → If schema validation fails → Proposal shows Failed

STEP 10 — You read the diagnosis
   RESULT=$(oc get proposal search-indexer-health \
     -o jsonpath='{.status.steps.analysis.results[0].name}')
   oc get analysisresult $RESULT \
     -o jsonpath='{.status.options[0].diagnosis.summary}'
```

### The ngrok role in this flow

The sandbox pod is inside the AWS cluster. Your Ollama is on your Mac at home.
They can't talk to each other directly.

```
Sandbox pod (AWS) → HTTPS → ngrok servers (internet) → tunnel → your Mac → Ollama
```

ngrok is just the phone line. The actual AI work happens on your Mac.
In production (with RHOAI MaaS or OpenAI), ngrok is not needed at all.

### What "the operator" actually does

The operator is a Kubernetes controller (Go program) running as a pod. It:
1. Watches for new `Proposal` CRs
2. Creates the sandbox pod with the right config (image, env vars, volumes)
3. Waits for the sandbox to become ready
4. Sends it the work request
5. Waits for the result
6. Creates the AnalysisResult CR
7. Cleans up (or leaves sandbox for debugging)

It does NOT do any AI reasoning itself. It's the "project manager" that coordinates
the sandbox (worker) and the LLM (brain).

---

## What we built (hackathon Jun 22 2026)

- Added `search-operator-impact` skill to stolostron/agentic-ols ([PR #1](https://github.com/stolostron/agentic-ols/pull/1))
- Surfaced `Applied=False / RulesSkipped` CollectorConfig conditions from ACM-35522
- Documented full setup flow from scratch (ACM install → agentic operator → Ollama → ngrok → running analysis)
- Successfully connected granite3.3:8b (local Mac M2) to an ACM 5.0 cluster in AWS — agent ran, queried the cluster, produced real diagnosis

## Next: cluster-backup-operator-impact

See the KNOWLEDGE_BASE.md section "Applying This to cluster-backup-operator" for the full list of scripts to write.
Reference: `ai-tools/projects/acm-backup-triage/KNOWLEDGE_BASE.md`

**For production-quality output:** Use Red Hat's internal RHOAI MaaS (ask team lead for access)
or a shared OpenAI project key. See KNOWLEDGE_BASE.md → "Production-Quality LLM Setup".

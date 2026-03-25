# ACM Cluster Setup

AI-powered automation for provisioning OpenShift clusters and installing ACM (Advanced Cluster Management) dev builds.

## The AI Agent Workflow

Instead of manually running commands and debugging failures, delegate to your AI coding assistant:

**Just tell your AI assistant what you need:**

> "Install ACM 2.17 on my cluster at https://api.mycluster.com:6443"

The AI agent (via `.cursorrules`) knows how to:
1. Run `install-acm.sh` with the right parameters
2. Monitor progress and report status
3. If something fails, automatically run `diagnose.sh` to collect cluster state
4. Analyze the diagnostic report and suggest fixes
5. Apply the fix and retry

**This is Agentic SDLC**: Instead of the developer reading docs, running commands, and debugging manually, the AI agent handles the entire workflow end-to-end.

### Example: AI-Assisted Installation

```
You:    "Set up ACM 2.17 on this cluster: api.mycluster.com:6443, token is sha256~xxx,
         quay user is myuser, password is mypass"

Agent:  [Runs install-acm.sh with parameters]
        [Monitors: Step 1/7 Login... OK]
        [Monitors: Step 2/7 Pull secret... OK]
        [Monitors: Step 3/7 ICSP... OK]
        ...
        "ACM 2.17 installed successfully. Console: https://multicloud-console.apps..."
```

### Example: AI-Assisted Troubleshooting

```
You:    "ACM installation is stuck, can you check what's wrong?"

Agent:  [Runs diagnose.sh]
        [Analyzes output]
        "Found 2 issues:
         1. CatalogSource 'acm-dev-catalog' is in state TRANSIENT_FAILURE
            - Root cause: Pull secret is missing quay.io:443 credentials
         2. 3 pods in CrashLoopBackOff due to image pull errors
         
         Fix: I'll patch the pull secret with your quay.io credentials..."
        [Applies fix]
        [Monitors recovery]
        "All issues resolved. MCH is now Running."
```

## Scripts

### `scripts/install-acm.sh`

Fully automated ACM dev build installation. Handles all 7 steps with progress monitoring and timeout handling.

```bash
# Install
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --token=sha256~xxxxx \
  --quay-user=myuser --quay-password=mypassword \
  --version=2.17

# With kubeadmin
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --kubeadmin-password=xxxxx-xxxxx-xxxxx-xxxxx \
  --quay-user=myuser --quay-password=mypassword

# Uninstall
./scripts/install-acm.sh --server=... --token=... --uninstall
```

### `scripts/diagnose.sh`

AI-powered diagnostics that collects cluster state and formats it for AI analysis.

```bash
# Full diagnostic
./scripts/diagnose.sh --server=... --token=...

# Quick health check
./scripts/diagnose.sh --server=... --token=... --health-only

# Save report to file (for sharing or AI analysis)
./scripts/diagnose.sh --server=... --token=... --output=/tmp/diagnosis.md
```

Checks performed:
- Cluster health (nodes, operators)
- Pull secret configuration
- Image mirroring (ICSP/IDMS)
- CatalogSource status and image pull errors
- ACM operator (subscription, CSV, install plan)
- MultiClusterHub status and conditions
- Pod health across ACM namespaces
- Recent warning events
- Console access

## AI Agent Integration

The `.cursorrules` file at the repo root teaches AI coding assistants (Cursor, Copilot, etc.) how to use these tools. The agent learns to:

- Map natural language requests to the correct script and parameters
- Chain operations (install → verify → diagnose if failed → fix → retry)
- Provide contextual troubleshooting based on diagnostic output

## Before vs After

| | Manual (Before) | AI Agent (After) |
|---|---|---|
| **Install ACM** | 6 manual steps, ~30 min of copy-paste | One sentence to AI, walk away |
| **Debug failures** | Read docs, check 10+ resources, guess | AI collects all state, pinpoints root cause |
| **Knowledge needed** | Pull secrets, ICSP, OLM, MCH internals | "Install ACM on my cluster" |
| **Time to resolve** | 15-60 min per issue | 2-5 min |

## Documentation

- [install-acm-dev-build.md](install-acm-dev-build.md) - Detailed manual steps and troubleshooting reference

## Prerequisites

- `oc` CLI installed
- `jq` installed
- Quay.io credentials with access to `acm-d` (get CLI password from quay.io > Account Settings > Generate Encrypted Password)

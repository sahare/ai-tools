---
name: acm-search
description: >-
  Develop, debug, and triage the ACM Search v2 stack: search-v2-operator,
  search-collector, search-indexer, search-v2-api, and search-mcp-server.
  Covers the 5-hub-pod architecture, CollectorConfig CRD reconciliation and
  RBAC propagation, the GraphQL query/RBAC pipeline, common bug patterns,
  debug commands, and E2E testing with custom images. Use when working in
  any search-v2-*/search-collector/search-indexer repo, diagnosing a search
  bug (missing/wrong resources, RBAC or filter issues, global search
  failures), adding a CRD status subresource, or setting up a custom-image
  E2E test for search.
---

# ACM Search v2

## Module Loading Guide — ALWAYS READ THIS FIRST

This skill uses **modular knowledge loading** to minimize token usage. Load ONLY what you need:

| If the task involves... | Load this module |
|------------------------|-----------------|
| Understanding overall architecture or cross-component flow | [modules/overview.md](modules/overview.md) |
| **search-v2-operator** (CRDs, reconciler, webhook, integration configs) | [modules/operator.md](modules/operator.md) |
| **search-collector** (informers, transforms, configurable collection, sender) | [modules/collector.md](modules/collector.md) |
| **search-indexer** (sync protocol, batching, rate limiting, cluster nodes) | [modules/indexer.md](modules/indexer.md) |
| **search-v2-api** (GraphQL, RBAC, SQL queries, related resources, subscriptions) | [modules/api.md](modules/api.md) |
| **search-e2e-test** (Jest API tests, Cypress UI tests, running locally) | [modules/e2e.md](modules/e2e.md) |
| **search-mcp-server** (find_resources tool, auth, deployment) | [modules/mcp.md](modules/mcp.md) |
| Debugging, bug patterns, debug commands, production lessons | [modules/incidents.md](modules/incidents.md) |
| Specific features: ACM-35522, ACM-37052, ACM-20052, future priorities | [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) (feature sections) |
| E2E testing with custom images | [E2E-TESTING-GUIDE.md](E2E-TESTING-GUIDE.md) |
| Plain-language onboarding / scrum glossary | [README.md](README.md) |

**For most tasks, you need at most 1-2 modules.** Don't load everything.

---

## Quick Reference (no module loading needed)

### The 5 hub pods

| Pod | Role |
|-----|------|
| **search-v2-operator** | Reconciles `Search` CR + `CollectorConfig` CRDs; deploys other 4 |
| **search-collector** | Hub + each managed cluster; watches resources → nodes+edges → sends to indexer |
| **search-indexer** | Receives collector payloads, writes to Postgres, rate-limits |
| **search-v2-api** | GraphQL API with per-user RBAC WHERE clauses |
| **search-mcp-server** | `find_resources` MCP tool for AI assistants (admin-only, direct SQL) |

### Data flow

```
Collector → (mTLS POST /sync) → Indexer → PostgreSQL ← API (GraphQL + RBAC)
                                                      ← MCP Server (direct SQL)
```

### CRITICAL RULES — production incidents from skipping these

1. **New CRD status subresource → RBAC in 5 places across 2 repos.** Miss the MCH-side grant → MCH stuck in `Installing`. See [modules/incidents.md](modules/incidents.md).
2. **CRD changes → manually mirror to `addon/manifests/chart/templates/collectorconfig_crd.yaml`.**
3. **`[]metav1.Condition` fields need `+listType=map` / `+listMapKey=type` markers.**
4. **`merged-collector-config` must NOT have the backup label.**

### Common bug patterns (quick lookup)

| Symptom | First place to look |
|---------|-------------------|
| Resource missing | Collector transform panic → reconciler skip → RBAC WHERE → indexer AddErrors |
| Too many results | `userHasAllAccess()` or `buildRbacWhereClause()` skipped |
| Related empty | `search.edges` table; `allEdges()`; `setDepth()` |
| Wildcard filter broken | `getPartialMatchFilter()` — `*` → `%`; `getPropertyType()` |
| Collector resyncing constantly | Sender `lastSentTime=-1`; indexer health; cert |
| 429 from indexer | Rate limiter threshold; concurrent collectors |

Full diagnosis steps → [modules/incidents.md](modules/incidents.md)

### Most-used debug commands

```bash
oc get pods -n open-cluster-management | grep search
oc get search search-v2-operator -o jsonpath='{.status.conditions}' | jq
oc logs -l component=search-collector -n open-cluster-management-agent-addon -- --v=5
# Direct postgres:
SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='X' AND data->>'kind'='Y';
# Pause reconciliation:
oc annotate search search-v2-operator search-pause=true
```

### Adding features — quick pointers

- New indexed property → `pkg/transforms/{kind}.go` or no-code via `CollectorConfig` fields
- New GraphQL filter → `schema.graphqls` + `getWhereClauseExpression()` + `matchOperatorToProperty()`
- New operator feature flag → annotation in `common.go` + new `controllers/feature_setup.go`
- New MCP tool → `ToolDefinition` + handler + query in `queries.go`

---

## Repos

| Repo | Local path | CLAUDE.md? |
|------|-----------|------------|
| search-v2-operator | `~/workspace/src/github.com/sahare/search-v2-operator` | Yes |
| search-collector | `~/workspace/src/github.com/sahare/search-collector` | Yes |
| search-indexer | `~/workspace/src/github.com/sahare/search-indexer` | Yes |
| search-v2-api | `~/workspace/src/github.com/sahare/search-v2-api` | Yes |
| search-e2e-test | `~/workspace/src/github.com/sahare/search-e2e-test` | Yes |
| search-mcp-server | `~/workspace/src/github.com/sahare/search-mcp-server` | Yes |

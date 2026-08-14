# ACM Search — Architecture Overview & Cross-Repo Workflows

## Data Flow (end-to-end)

```
ManagedCluster                              Hub Cluster
┌─────────────────┐                        ┌──────────────────────────────────────────┐
│ search-collector │──mTLS POST──────────→ │ search-indexer (:3010)                    │
│ (per cluster)   │  /aggregator/sync      │   ├─ SyncData (diff) or ResyncData (full) │
│                 │                        │   └─ batch write → PostgreSQL             │
└─────────────────┘                        │                                          │
                                           │ search-postgres                          │
                                           │   ├─ search.resources (uid, cluster, JSONB)│
                                           │   └─ search.edges (src, dst, type)        │
                                           │                                          │
                                           │ search-api (:4010)                        │
                                           │   ├─ GraphQL queries (RBAC-filtered)      │
                                           │   ├─ WebSocket subscriptions              │
                                           │   └─ Federated search (managed hubs)     │
                                           │                                          │
                                           │ search-mcp-server (:8080)                │
                                           │   └─ find_resources (direct SQL, RBAC)   │
                                           │                                          │
                                           │ search-v2-operator                       │
                                           │   ├─ Deploys all above pods              │
                                           │   ├─ Manages CollectorConfig CRDs        │
                                           │   └─ OCM addon → deploys collector       │
                                           └──────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Repo | Language | Does | Talks to |
|-----------|------|----------|------|----------|
| **Operator** | search-v2-operator | Go | Deploys/configures all search pods, manages CRDs, collector addon | Kubernetes API |
| **Collector** | search-collector | Go | Watches k8s resources, transforms → nodes+edges, sends diffs | Indexer (mTLS HTTP) |
| **Indexer** | search-indexer | Go | Receives sync payloads, batch-writes to Postgres, rate-limits | PostgreSQL, Kubernetes API (cluster nodes) |
| **API** | search-v2-api | Go | GraphQL endpoint, RBAC enforcement, related resources, subscriptions | PostgreSQL, Kubernetes API (TokenReview/SSAR) |
| **MCP Server** | search-mcp-server | Go | AI assistant access (find_resources tool), dual-source RBAC | PostgreSQL, Kubernetes API (auth) |
| **E2E Tests** | search-e2e-test | Node.js | API (Jest) + UI (Cypress) tests | search-api GraphQL |

## Database Schema

```sql
-- search.resources: one row per Kubernetes resource across all clusters
uid TEXT PRIMARY KEY, cluster TEXT, data JSONB
-- Indexes: GIN on data->'kind', data->'namespace', data->'name'; btree on cluster
-- Composite GIN on (_hubClusterResource, namespace, apigroup, kind_plural) for RBAC

-- search.edges: relationships between resources
sourceId TEXT, sourceKind TEXT, destId TEXT, destKind TEXT, edgeType TEXT, cluster TEXT
PRIMARY KEY(sourceId, destId, edgeType)
```

## Key CRDs

| CRD | Purpose | Singleton? |
|-----|---------|------------|
| `Search` (search-v2-operator) | Controls all search component deployment/config | Yes (must be named `search-v2-operator`) |
| `CollectorConfig` | Configure what resources to collect (include/exclude rules, fields) | No (user + integration + merged) |

## Inter-component Communication

| From → To | Protocol | Path | Auth |
|-----------|----------|------|------|
| Collector → Indexer | HTTPS (mTLS) | POST /aggregator/clusters/{name}/sync | Client cert (addon CSR) |
| API → PostgreSQL | TCP | pgx connection pool | DB user/pass from Secret |
| Indexer → PostgreSQL | TCP | pgx connection pool | DB user/pass from Secret |
| MCP → PostgreSQL | TCP | pgx/v5 connection pool | DB user/pass from Secret |
| Console → API | HTTPS | POST /searchapi/graphql | Bearer token (user's OCP token) |
| Operator → Kubernetes | HTTPS | controller-runtime client | ServiceAccount token |

---

## Cross-Repo Workflow Recipes

These recipes tell agents exactly which repos and files to touch for common multi-repo changes, eliminating the need to re-discover the flow each time.

### Recipe 1: Add a new searchable property to an existing resource kind

**Goal:** Make a new field (e.g. `podPriority`) appear in search results and be filterable.

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-collector | `pkg/transforms/{kind}.go` | Extract the field into `node.Properties["podPriority"] = ...` |
| 2 | search-collector | `pkg/transforms/{kind}_test.go` | Assert the property appears in test output |
| 3 | — | — | **No indexer change needed** — entire Properties map is stored as JSONB |
| 4 | — | — | **No API change needed** — property auto-discovered via `GetPropertyTypes` |
| 5 (optional) | search-indexer | `pkg/database/connection.go` InitializeTables | Add GIN index if query-hot |
| 6 (optional) | search-e2e-test | `tests/api/` | Add assertion that new property appears |

**Alternative (no code):** Use `CollectorConfig` with `fields[].jsonPath` extraction — no collector code change needed.

### Recipe 2: Add a new searchable property via CollectorConfig (no code)

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-v2-operator | `config/integration_collector_configs/{team}.yaml` | Add include rule with `fields[].jsonPath` |
| 2 | — | — | Operator seeder will apply on next restart; collector dynamic reload picks it up |

### Recipe 3: Add support for a completely new resource kind

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-collector | `pkg/transforms/{kind}.go` | Create typed builder with `BuildNode()` + `BuildEdges()` |
| 2 | search-collector | `pkg/transforms/transformer.go` | Register in switch: `case [2]string{"MyKind", "mygroup.io"}` |
| 3 | search-collector | `pkg/transforms/{kind}_test.go` | Unit tests |
| 4 | — | — | Informer auto-discovers new GVR — no registration needed |
| 5 | — | — | Indexer/API need no changes (generic JSONB storage + auto-discovery) |
| 6 (optional) | search-v2-operator | `config/integration_collector_configs/{team}.yaml` | Add integration config if team wants protection from user excludes |

### Recipe 4: Add a new edge type (relationship)

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-collector | `pkg/transforms/{kind}.go` | Add `BuildEdges()` returning new edge type |
| 2 | search-collector | `pkg/transforms/common.go` | Add edge type constant if new |
| 3 | — | — | Indexer: no change (stores all edges generically) |
| 4 | search-v2-api | `pkg/resolver/related.go` | Check if new kind needs exclusion from recursion (like Node/Channel) |
| 5 | search-e2e-test | `tests/api/queries.test.js` | Add related-resource assertion |

### Recipe 5: Add a new GraphQL filter operator

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-v2-api | `graph/schema.graphqls` | Update schema if needed |
| 2 | search-v2-api | — | `make gqlgen` to regenerate |
| 3 | search-v2-api | `pkg/resolver/searchHelper.go` | Add case in `getWhereClauseExpression()` and `matchOperatorToProperty()` |
| 4 | search-v2-api | `pkg/resolver/searchHelper_test.go` | Unit test |
| 5 | search-e2e-test | `tests/api/filter.test.js` | E2E assertion |

### Recipe 6: Add a new operator feature flag (annotation-based)

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-v2-operator | `controllers/common.go` | Add annotation constant |
| 2 | search-v2-operator | `controllers/{feature}_setup.go` | Create reconcile logic |
| 3 | search-v2-operator | `controllers/search_controller.go` | Call from `Reconcile()` at correct step |
| 4 | search-v2-operator | `controllers/{feature}_setup_test.go` | Unit test |
| 5 | search-v2-operator | `docs/ARCHITECTURE.md` or README | Document the annotation |
| 6 | search-e2e-test | — | E2E test if user-visible behavior changes |

### Recipe 7: Change a CRD type (CollectorConfig or Search)

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-v2-operator | `api/v1alpha1/{type}_types.go` | Edit the Go struct |
| 2 | search-v2-operator | — | `make generate` (DeepCopy) |
| 3 | search-v2-operator | — | `make manifests` (CRD YAML + RBAC) |
| 4 | search-v2-operator | `addon/manifests/chart/templates/collectorconfig_crd.yaml` | **MANUAL mirror** of CRD changes |
| 5 | search-v2-operator | `api/v1alpha1/{type}_webhook.go` | Update webhook validation if needed |
| 6 (if status) | search-v2-operator + multiclusterhub-operator | See RBAC recipe below | 5 RBAC places across 2 repos |

### Recipe 8: Add RBAC for new status subresource (CRITICAL — production incidents from skipping)

| # | Repo | File | What to add |
|---|------|------|-------------|
| 1 | search-v2-operator | `controllers/create_rolesbindings.go` `getRules()` | Hub ClusterRole rule |
| 2 | search-v2-operator | `controllers/search_controller.go` | `//+kubebuilder:rbac` marker → `make manifests` |
| 3 | search-v2-operator | `addon/manifests/chart/templates/cluster_role.yaml` | Managed cluster ClusterRole |
| 4 | search-v2-operator | `bundle/manifests/...clusterserviceversion.yaml` | OLM CSV `clusterPermissions` |
| 5 | multiclusterhub-operator | `pkg/templates/charts/toggle/search-v2-operator/...` | MCH Helm template |

**If you skip #4-5:** MCH gets stuck in Installing status (Kubernetes privilege escalation protection). Let the MCH GitHub Action auto-sync from the CSV (#4).

### Recipe 9: Add a new MCP tool

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-mcp-server | `internal/{tool}/` | Create core + types + formatter |
| 2 | search-mcp-server | `internal/server/tools.go` | Register in `GetCentralizedToolDefinitions()` |
| 3 | search-mcp-server | `internal/server/transport_http.go` | Wire handler in `registerTools`/`handleToolsCall` |
| 4 | search-mcp-server | `internal/server/transport_stdio.go` | Wire handler (same) |
| 5 | search-mcp-server | `internal/server/auth/authorized_tools.go` | Update `GetAuthorizedTools` if gated |
| 6 | search-mcp-server | `test/integration/` | Integration test |

### Recipe 10: Add a new integration CollectorConfig (for a new team)

| Step | Repo | File(s) | What to do |
|------|------|---------|------------|
| 1 | search-v2-operator | `config/integration_collector_configs/{team}.yaml` | Create YAML with include rules + integration label + backup label |
| 2 | search-v2-operator | — | Seeder auto-discovers new file via `go:embed` — no code change |
| 3 | search-v2-operator | `api/v1alpha1/collectorconfig_webhook.go` | Remove team's apiGroups from `protectedAPIGroups` if they were there |
| 4 | search-v2-operator | webhook + seeder tests | Update test expectations |

---

## Token-Saving Tips for Agents

1. **Read the specific module file first** — don't explore the whole codebase; check `modules/{component}.md`
2. **Use the recipe above** — for multi-repo changes, the recipe tells you exactly which files
3. **Property changes often need zero code** — CollectorConfig `fields[].jsonPath` handles most cases
4. **Indexer almost never needs changes** — it stores the entire Properties map as JSONB
5. **API auto-discovers properties** — `GetPropertyTypes` reads distinct keys from the DB
6. **Check KNOWLEDGE_BASE.md** for detailed bug patterns, design decisions, and lessons learned
7. **The operator is the only repo that touches all others** — CRD changes ripple everywhere
8. **`make manifests` + `make generate`** after any `api/v1alpha1/` change (both are needed, separately)

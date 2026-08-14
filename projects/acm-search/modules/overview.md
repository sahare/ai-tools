# ACM Search — Architecture Overview

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
                                           │ search-mcp-server                        │
                                           │   └─ find_resources (direct SQL, admin)  │
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
| **MCP Server** | search-mcp-server | Go/TS | AI assistant access (find_resources tool), admin-only | PostgreSQL, Kubernetes API (auth) |
| **E2E Tests** | search-e2e-test | Node.js | API (Jest) + UI (Cypress) tests | search-api GraphQL |

## Database Schema

```sql
-- search.resources: one row per Kubernetes resource across all clusters
uid TEXT PRIMARY KEY, cluster TEXT, data JSONB
-- Indexes: GIN on data->'kind', data->'namespace', data->'name'; btree on cluster

-- search.edges: relationships between resources
sourceId TEXT, sourceKind TEXT, destId TEXT, destKind TEXT, edgeType TEXT, cluster TEXT
PRIMARY KEY(sourceId, destId, edgeType)
```

## Key CRDs (managed by operator)

| CRD | Purpose | Singleton? |
|-----|---------|------------|
| `Search` (search-v2-operator) | Controls all search component deployment/config | Yes (must be named `search-v2-operator`) |
| `CollectorConfig` | Configure what resources to collect (include/exclude rules, fields) | No (user + integration + merged) |

## Namespace Convention

All hub components run in the ACM namespace (typically `open-cluster-management`, but QE uses `ocm`).
Collectors run in `open-cluster-management-agent-addon` on managed clusters.

## Inter-component Communication

| From → To | Protocol | Path | Auth |
|-----------|----------|------|------|
| Collector → Indexer | HTTPS (mTLS) | POST /aggregator/clusters/{name}/sync | Client cert (auto-provisioned by addon CSR) |
| API → PostgreSQL | TCP | pgx connection pool | DB user/pass from Secret |
| Indexer → PostgreSQL | TCP | pgx connection pool | DB user/pass from Secret |
| MCP → PostgreSQL | TCP | pgx connection pool | DB user/pass from Secret |
| Console → API | HTTPS | POST /searchapi/graphql | Bearer token (user's OCP token) |
| Operator → Kubernetes | HTTPS | controller-runtime client | ServiceAccount token |

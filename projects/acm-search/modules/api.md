# search-v2-api — Technical Reference

**Repo:** https://github.com/stolostron/search-v2-api
**Language:** Go (gqlgen) | **Entry:** `main.go`
**Runs on:** Hub cluster (scalable replicas)

## What it does

GraphQL API server that queries PostgreSQL with per-user RBAC filtering. Supports search, autocomplete, schema introspection, related resources, and WebSocket subscriptions.

## GraphQL Schema (`graph/schema.graphqls`)

| Operation | Signature | Description |
|-----------|-----------|-------------|
| query search | `search(input: [SearchInput]): [SearchResult]` | Main search — items[], count, related[] |
| query searchComplete | `searchComplete(property, query, limit): [String]` | Autocomplete values |
| query searchSchema | `searchSchema(query): Map` | All indexed field names + values |
| query messages | `messages: [Message]` | Server-side warnings |
| subscription watch | `watch(input: SearchInput): Event` | WebSocket push on changes |

## SearchInput Fields

| Field | Type | Notes |
|-------|------|-------|
| keywords | [String] | Full-text across all properties. Multiple = AND. |
| filters | [SearchFilter] | property + values. Multiple filters = AND, values = OR. |
| filters values operators | prefix | `=, !, !=, >, >=, <, <=`. Datetime: `hour/day/week/month/year`. Wildcard: `*` |
| limit | Int | Default 10000. -1 = no limit. |
| offset | Int | Pagination. |
| orderBy | String | `'property asc/desc'` |
| relatedKinds | [String] | Filter related resource kinds. |

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `graph/` | GraphQL schema, gqlgen generated code, resolvers | `schema.graphqls`, `resolver.go` |
| `pkg/resolver` | Query building, RBAC WHERE clauses, related resources | `search.go`, `searchHelper.go`, `rbacHelper.go`, `related.go` |
| `pkg/rbac` | User data building (SSAR/SSRR), caching, watch | `userData.go`, `cache.go`, `watchCache.go`, `sharedData.go` |
| `pkg/database` | PostgreSQL connection, LISTEN/NOTIFY | `connection.go`, `listener.go`, `listenerTrigger.sql` |
| `pkg/federated` | Global/federated search fan-out to managed hubs | `federated.go`, `fedConfig.go` |
| `pkg/server` | HTTP router, middleware | `server.go` |
| `pkg/config` | Configuration | `config.go` |

## SQL Query Builder (`pkg/resolver/search.go` + `searchHelper.go`)

Built with the `goqu` library. Filter → SQL mapping:

| Input | SQL Pattern |
|-------|-------------|
| `kind: pod` (lowercase) | `data->>'kind' ILIKE ANY ('{"pod"}')` |
| `name: nginx-*` (wildcard) | `data->>'name' LIKE 'nginx-%'` |
| `label: app=nginx` | `data->'label' @> '{"app":"nginx"}'` |
| `label: app=*` (wildcard value) | `EXISTS(SELECT 1 FROM jsonb_each_text(data->'label') WHERE key LIKE 'app' AND value LIKE '%')` |
| `created: hour` (datetime) | `data->>'created' > '<1h ago>'` |
| `status: Running` | `data->'status' ? 'Running'` |
| `replicas: >3` (numeric) | `(data->'replicas')::numeric > 3` |
| `cluster: local-cluster` | `cluster = 'local-cluster'` (column, not JSONB) |
| keywords | `FROM search.resources, jsonb_each_text(data) WHERE value ILIKE '%keyword%'` |

## RBAC Pipeline (7 steps)

1. **Extract token** — `Authorization: Bearer` header
2. **Validate token** — `TokenReview` → username + groups + UID. Cached 60s.
3. **Check cluster-admin** — SSAR `verb=* resource=*`. If yes → no WHERE clause.
4. **Check global hub user** — SSAR for `searches/allManagedData` get.
5. **Build namespace RBAC** — parallel `SelfSubjectRulesReview` per namespace → `(apigroup, kind)` tuples.
6. **Build cluster-scope RBAC** — parallel SSAR per cluster-scoped resource.
7. **Fine-grained RBAC** (if enabled) — `userpermissions.clusterview` CRD.

## RBAC WHERE Clause (`pkg/resolver/rbacHelper.go`)

```sql
WHERE (hub_branch OR managed_cluster_branch)
```

- **Hub branch:** `data?'_hubClusterResource' AND (cluster-scoped OR namespace-scoped check)`
- **Managed cluster branch:** `cluster = ANY(ARRAY[...])` for clusters user has ManagedClusterView access

### Namespace Consolidation Optimization

Namespaces with identical resource access are grouped:
```sql
data->'namespace' ?| ARRAY['ns-a','ns-b','ns-c'] AND (kind/apigroup check)
```
Dramatically reduces query size for users with many namespaces.

## RBAC Cache

- Keyed by user UID (from TokenReview)
- TokenReview cache: 60s TTL per token
- UserData cache: `UserCacheTTL` (default 10 min)
- Session affinity via ClusterIP (no shared cache needed)
- Background watcher invalidates on Role/ClusterRole/RoleBinding/Namespace/CRD changes

## Related Resources (`pkg/resolver/related.go`)

Recursive CTE traversing `search.edges`:
- Level 1 (default): direct neighbors
- Level 3: for Application queries (3-hop)
- Excluded from recursion: Node, Channel (too many results)
- RBAC applied to final JOIN

## WebSocket Subscriptions (`pkg/resolver/watchSubscription.go`)

- PostgreSQL `LISTEN/NOTIFY` trigger on `search.resources` changes
- Listener goroutine applies RBAC and pushes to matching WebSocket subscribers

## Federated Search (`pkg/federated/`)

Enabled when `FEATURE_FEDERATED_SEARCH=true`. Proxies queries to all managed hub search-APIs in parallel. Responses merged and deduplicated. Supports `managedHub` filter.

## Environment Variables

| Variable | Description |
|----------|-------------|
| DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME | PostgreSQL connection |
| FEATURE_FEDERATED_SEARCH | Enable global search |
| FEATURE_FINE_GRAINED_RBAC | Enable fine-grained RBAC |
| HUB_NAME | Hub cluster name |
| USER_CACHE_TTL_MS | RBAC cache TTL (default 600000 = 10 min) |
| QUERY_LIMIT | Default result limit (10000) |
| RELATION_LEVEL | Default recursion depth for related |

## Commands

```bash
make build    # Build binary
make test     # Run tests
make lint     # Lint
make run      # Run locally (needs DB connection)
```

## How to: add a new GraphQL filter operator

1. Update `graph/schema.graphqls` — regenerate with `make generate`
2. Add operator case to `getWhereClauseExpression()` in `searchHelper.go`
3. Update `matchOperatorToProperty()` to detect and route it
4. Add E2E test in `search-e2e-test/tests/api/filter.test.js`

## How to: debug RBAC issues

1. Check who the user is: `oc whoami` / examine the Bearer token
2. Enable verbose: `-v=5` on search-api pod
3. Look for `UserData` in logs — shows computed namespace/cluster access
4. Test SSAR manually: `oc auth can-i list pods --namespace=<ns> --as=<user>`
5. Check cache TTL — might be seeing stale data (wait 10 min or restart pod)

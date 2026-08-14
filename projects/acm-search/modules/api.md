# search-v2-api — Technical Reference

**Repo:** https://github.com/stolostron/search-v2-api
**Language:** Go (gqlgen) | **Entry:** `main.go`
**Runs on:** Hub cluster (scalable replicas)

## What it does

GraphQL API server that queries PostgreSQL with per-user RBAC filtering. Supports search, autocomplete, schema introspection, related resources, and WebSocket subscriptions.

## Architecture

```
main.go
 → config.Cfg.Validate()
 → database.GetConnPool(ctx) — Postgres pool
 → rbac.GetCache().StartBackgroundValidation(ctx) — watches NS + ManagedClusters
 → server.StartAndListen(ctx) — HTTPS :4010
```

### HTTP Routes
| Path | Auth | Purpose |
|------|------|---------|
| `GET /liveness` | no | Always OK |
| `GET /readiness` | no | Always OK (no DB check) |
| `GET /metrics` | no | Prometheus |
| `POST /federated` | TokenReview only | Cross-hub search (if feature on) |
| `{CONTEXT_PATH}/graphql` | full middleware | GraphQL + WebSocket |
| `/playground` | no | gqlgen playground if `PLAYGROUND_MODE` |

### Middleware order on `/searchapi`
1. TimeoutHandler (skip WebSocket)
2. PrometheusMiddleware (skip WebSocket)
3. CheckDBAvailability — 503 if pool unhealthy
4. AuthenticateUser — TokenReview
5. AuthorizeUser — populate shared + user RBAC caches

## GraphQL Schema

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
| limit | Int | Default from `QUERY_LIMIT` (1000). -1 = no limit. |
| offset | Int | Pagination. |
| orderBy | String | `'property asc/desc'` |
| relatedKinds | [String] | Filter related resource kinds. |

### Filter Value Operators
Prefix on values: `=`, `!`, `!=`, `<`, `<=`, `>`, `>=`
Wildcards: `*` → SQL `%` (LIKE)
Timestamps: `hour|day|week|month|year` → relative ISO timestamps
`kind`: case-insensitive ILIKE if value starts with lowercase

## SQL Query Builder (`pkg/resolver/`)

Built with `goqu` library. Table: `search.resources` (uid, cluster, data JSONB).

| Input | SQL Pattern |
|-------|-------------|
| `kind: pod` (lowercase) | `data->>'kind' ILIKE ANY ('{"pod"}')` |
| `name: nginx-*` (wildcard) | `data->>'name' LIKE 'nginx-%'` |
| `label: app=nginx` | `data->'label' @> '{"app":"nginx"}'` |
| `created: hour` (datetime) | `data->>'created' > '<1h ago>'` |
| `cluster: local-cluster` | `cluster = 'local-cluster'` (column, not JSONB) |
| keywords | `FROM search.resources, jsonb_each_text(data) WHERE value ILIKE '%keyword%'` |
| unknown property | `1=0` (zero rows silently — not error) |

## RBAC System (`pkg/rbac/`)

### AuthN Flow
1. Cookie `acm-access-token-cookie` OR `Authorization: Bearer …`
2. `TokenReviews().Create` (cached `AUTH_CACHE_TTL` 60s)
3. Invalid → 403; missing → 401; API error → 500

### AuthZ / UserData Build (keyed by TokenReview UID)

**Fast path — `userHasAllAccess`:**
1. SSAR: `list * *` → cluster-admin: empty WHERE clause (sees everything)
2. Else SSAR: `get searches/allManagedData` → global search SA (managed data only)

**Normal path:**
1. Optional: list `userpermissions.clusterview` (fine-grained)
2. For each hub namespace: SSRR (`oc auth can-i --list -n X`) → collect resources with verb `list`/`*`
3. Managed cluster access = `create managedclusterviews` in view API group
4. Parallel SSAR for hub cluster-scoped resources

### RBAC WHERE Clause (`rbacHelper.go`)
```sql
WHERE (hub_branch OR managed_cluster_branch)
```
- **Hub:** `_hubClusterResource` present AND (cluster-scoped OR namespace apigroup/kind matches)
- **Managed (basic):** `cluster = ANY(allowed)` or `cluster != (hub)` if wildcard
- **Fine-grained:** cluster+namespace+apigroup/kind bindings from UserPermission CRs

### Cache Invalidation (partial!)
- Watches NS/ManagedCluster: ADDED/DELETED events refresh shared + per-user SSRR
- Does **NOT** watch Role/RoleBinding/ClusterRole — permission changes wait for `USER_CACHE_TTL` expiry (5 min default)

## Related Resources (`pkg/resolver/related.go`)

Recursive CTE on `search.edges`:
- Level 1 (default): direct neighbors
- Level 3: for Application queries (3-hop)
- Excluded from recursion: Node, Channel (too many connections)
- RBAC applied to final JOIN
- Synthetic `cluster__<name>` nodes added for cluster association

## WebSocket Subscriptions

- PostgreSQL `LISTEN search_resources_notify` trigger
- Payload truncated >~7000 bytes → backfill via SELECT
- Per-event RBAC check via SSAR `watch` verb
- Max active: `SUBSCRIPTION_MAX_ACTIVE` (200); lifetime 12h; idle 1h

## Federated Search (`pkg/federated/`)

Enabled when `FEATURE_FEDERATED_SEARCH=true`. Fan-out to managed hubs:
- Local: same-cluster GraphQL endpoint with caller token
- Remotes: ManagedClusters with `hub.open-cluster-management.io` claim; token from Secret `search-global`
- Merge: schema/complete/items/related combined; `managedHub` stamped on items
- No global LIMIT/SORT across hubs

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| DB_HOST/PORT/USER/PASS/NAME | | PostgreSQL connection |
| QUERY_LIMIT | 1000 | Default result limit |
| AUTH_CACHE_TTL | 60s | TokenReview cache |
| SHARED_CACHE_TTL | 5 min | Namespaces, ManagedClusters |
| USER_CACHE_TTL | 5 min | Per-user SSRR/SSAR |
| USER_PERMISSION_CACHE_TTL | 30s | Fine-grained UserPermissions |
| FEATURE_FEDERATED_SEARCH | false | Global search |
| FEATURE_FINE_GRAINED_RBAC | false | Fine-grained RBAC |
| FEATURE_SUBSCRIPTION | true | WebSocket support |
| RELATION_LEVEL | 0 (auto) | 1 normal / 3 Application |
| HUB_NAME | | Hub cluster name |
| HTTP_PORT | 4010 | Listen port |
| CONTEXT_PATH | /searchapi | GraphQL path prefix |

## Commands

```bash
make setup   # TLS cert + print DB env from cluster + port-forward hint
make run     # PLAYGROUND_MODE=true go run -tags development --v=4
make gqlgen  # Regenerate GraphQL code
make test    # go test ./... -failfast
make lint    # golangci-lint + gosec
make send    # curl GraphQL (QUERY=schema|search|...)
```

## Non-obvious Gotchas

1. **Unknown filter property → `1=0`** — silently returns zero rows, not an error
2. **RBAC cache does NOT watch RoleBindings** — permission changes take up to `USER_CACHE_TTL` to propagate
3. **Keywords force `jsonb_each_text` join** — expensive on large result sets
4. **Related level 3 is heavy** — only auto-triggered for Application/relatedKinds
5. **`kubeadmin` has empty UID** from TokenReview — special-cased in cache key
6. **Readiness does NOT check DB** — pod reports ready even with broken postgres
7. **`managedHub` filter is NOT SQL** — it decides whether this hub participates at all
8. **Impersonation Extra headers** filtered to only `authentication.kubernetes.io/*` and `scopes.authorization.openshift.io/*`

## Agent Playbooks

### Add a new GraphQL resolver
1. Edit `graph/schema.graphqls`
2. `make gqlgen`
3. Implement in `graph/schema.resolvers.go` → logic in `pkg/resolver`
4. Always call `GetUserData` + `buildRbacWhereClause` on any resources query

### Add a new search filter property
1. Ensure indexer/collector writes it into `data` jsonb
2. Property types auto-discovered via `GetPropertyTypes` — no registration needed
3. For special operators: extend `matchOperatorToProperty` / `getWhereClauseExpression`
4. Virtual props (like `managedHub`): handle in `matchesManagedHubFilter` — do NOT add SQL

### Debug missing results
1. Query Postgres without RBAC: `SELECT * FROM search.resources WHERE data->>'name' = '…'`
2. Check `_hubClusterResource`, `namespace`, `kind_plural`, `apigroup`, `cluster` values
3. Verbose logs: `-v=5` for SQL; `-v=3` for RBAC mode
4. Unknown filter property → silent `1=0` (check spelling/case)
5. `managedHub` mismatch → empty on this hub

### Debug RBAC denials
1. Check token: `oc whoami` with same token
2. Empty UserData → query fails with "RBAC clause is required"
3. Fine-grained: empty UserPermissions → hub-only (managed data hidden)
4. Global search SA needs `searches/allManagedData` get permission
5. Watch uses separate SSAR path (`WatchCache`)

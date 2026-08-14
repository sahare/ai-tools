# search-mcp-server — Technical Reference

**Repo:** https://github.com/stolostron/search-mcp-server
**Language:** Go (mcp-go) | **Entry:** `cmd/server/main.go`
**Runs on:** Hub cluster (deployed via Helm)

## What it does

Exposes ACM Search data to AI assistants (Claude, OLS, etc.) via the Model Context Protocol. Connects directly to PostgreSQL (`search.resources`). Dual-source RBAC (UserPermission CRs + hub K8s API).

## Architecture

```
cmd/server/main.go
 → config.LoadConfigWithArgs (DATABASE_URL)
 → server.NewPostgresMCPServer
     → database.NewDatabaseConnectionWithConfig (pgx/v5 pool)
     → database.NewDatabaseQueries
     → findresources.NewFindResourcesCore + Formatter
     → TransportManager (stdio | http | auto)
         HTTP: AuthMiddleware → /mcp JSON-RPC → findCore.FindResources(userCtx)
         STDIO: mcp-go ServeStdio → findCore.FindResources(nil)  ← NO RBAC
```

**Primary table:** `search.resources` (`uid`, `cluster`, `data` JSONB).

## The One Tool: `find_resources`

| Parameter | Description |
|-----------|-------------|
| kind | Resource kind or comma-separated: "Pod" or "Pod,ConfigMap" |
| name | Exact match or glob: "nginx-*" |
| namespace | Comma-separated or wildcard: "kube-*,default" |
| cluster | Cluster name or comma-separated |
| labelSelector | K8s selector: "app=nginx,env!=test" |
| clusterSelector | Filter by cluster labels (**BROKEN — stub returns empty**) |
| status | Status filter: "Running,Failed" |
| textSearch | Full-text across all JSON fields |
| ageNewerThan / ageOlderThan | Time: "1h", "2d", "1w" |
| outputMode | list (default), count, summary, health |
| groupBy | Group by: status, namespace, cluster, kind, label:key |
| limit | 1–1000, default 50 |
| sortBy / sortOrder | name/created/namespace/cluster, asc/desc |

Note: `compliance` is implemented in core but **commented out** in `tools.go` (not exposed yet).

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `cmd/server` | Main entry point | `main.go` |
| `internal/server` | MCP protocol, tool registration, auth, transports | `tools.go`, `transport_http.go`, `transport_stdio.go`, `config.go` |
| `internal/server/auth` | AuthN/AuthZ middleware, RBAC resolver | `middleware.go`, `rbac_resolver.go`, `types.go` |
| `internal/findresources` | Core tool: validation, SQL build, auth filters | `core.go`, `types.go`, `formatters.go` |
| `internal/utils` | SQLBuilder (parameterized WHERE) | `sqlbuilder.go` |
| `pkg/config` | DB config from env | `config.go` |
| `pkg/database` | pgx/v5 pool, read-only query validation | `connection.go`, `queries.go` |
| `pkg/utils` | Cross-resource conditions, label/time/status helpers | |
| `helm/acm-mcp-server/` | Deploy chart | |

## Authorization (Dual-Source RBAC)

### Auth enablement
- `MCP_ENABLE_AUTH` env explicitly; else `true` if `KUBERNETES_SERVICE_HOST` set (in-cluster)
- STDIO transport skips auth entirely (full DB read)

### AuthN flow
1. Header: `Authorization` or `kubernetes-authorization` → Bearer token
2. `KubernetesValidator.ValidateBearerToken` → TokenReview API
3. Optional token cache (`MCP_AUTH_CACHE` default true, TTL 5m)

### Permission resolution (OR-merged from two sources)

| Source | API | Grants |
|--------|-----|--------|
| `userpermission-cr` | Dynamic client list `clusterview/userpermissions` with **user's token** | Managed clusters: cluster↔namespace↔kind bindings |
| `hub-kubernetes` | SSAR/SSRR-style hub discovery | Hub cluster only; cluster admin → wildcards |

### SQL shape of auth filters
- Cluster-scoped: `(cluster = $X AND data->>'kind' IN (...))`
- Namespaced: `(cluster = $X AND data->>'namespace' = $Y AND kind…)`
- Hub resources: namespace keys are bare namespaces; cluster forced to `HubClusterName`
- Empty permissions → `1 = 0`; **fail-secure** (API failures deny access)

### SA RBAC (Helm)
ClusterRole: only `tokenreviews` create. Actual data permissions come from the **caller's** token.

## Transport Selection

| `MCP_TRANSPORT_MODE` | Behavior |
|----------------------|----------|
| `stdio` | STDIO only (no auth) |
| `http` | HTTP only |
| `auto` (default) | HTTP if non-TTY or port set; else STDIO if TTY |

## Environment Variables

| Env | Default | Purpose |
|-----|---------|---------|
| `DATABASE_URL` | **required** | Postgres URL |
| `DB_MAX_CONNECTIONS` | 20 | Pool size |
| `MCP_TRANSPORT_MODE` | auto | stdio/http/auto |
| `MCP_HTTP_PORT` / `MCP_HTTP_HOST` | 8080 / 0.0.0.0 | |
| `MCP_ENABLE_AUTH` | auto (K8s) | |
| `MCP_AUTH_CACHE` / `MCP_AUTH_CACHE_TTL` | true / 5m | |
| `MCP_DISCOVERY_TTL` / `MCP_DISCOVERY_SOURCE` | 5m / database | Kind→plural mapping cache |
| `MCP_K8S_URL`, `MCP_SA_TOKEN`, `MCP_KUBECONFIG` | | Local override |
| `MAX_QUERY_ROWS` | 1000 | |
| `LOG_LEVEL` | info | debug dumps RBAC SQL |

## Deployment

```bash
# Helm auto-discovers ACM namespace + Postgres secret
helm install acm-mcp-server ./helm/acm-mcp-server/

# Connect to Claude
export TOKEN=$(oc whoami -t)
export ROUTE_URL=$(oc get route acm-search-mcp-server-route -o jsonpath='{.spec.host}')
claude mcp add --transport http --scope project acm-search \
  https://$ROUTE_URL/mcp --header "Authorization: Bearer $TOKEN"
```

## Commands

```bash
make build              # Build binary
make run                # Local run (needs DATABASE_URL)
make test               # Unit tests
make test-integration   # Ginkgo integration (needs live DB)
make lint               # golangci-lint + gosec
make container-build    # Docker image
make helm-install       # Helm deploy
```

## Non-obvious Gotchas

1. **`clusterSelector` is a stub** — `FindMatchingClusters` always returns empty → any non-empty selector = zero results
2. **`compliance` implemented but NOT in MCP schema** — commented out in `tools.go`
3. **Aggregation modes SELECT all rows then aggregate in Go** — not SQL GROUP BY; heavy on large fleets
4. **STDIO = no RBAC** — full DB read for whoever runs the process
5. **Auth denies on K8s API failure** — by design (fail-secure), even for admins
6. **Helm secret needs cluster `lookup`** — install requires sufficient permissions for secret discovery
7. **OLS integration uses `/mcp` endpoint** — not `/sse`; verify against deployed version

## Agent Playbooks

### Add a new MCP tool
1. Implement `internal/<tool>/` with core + types (+ formatter if needed)
2. Register in `GetCentralizedToolDefinitions()` (Options + JSONSchema)
3. Wire handlers in **both** `transport_http.go` and `transport_stdio.go` `registerTools`/`handleToolsCall`
4. Update `GetAuthorizedTools` in auth if gated
5. Init in `NewPostgresMCPServerWithConfig` if needs DB

### Debug empty results with auth
1. `LOG_LEVEL=debug` → look for `[RBAC-*]`, `[DISCOVERY-*]` prefixed logs
2. Check UserPermission CRs exist: `oc get userpermissions -A` (as the user)
3. Check hub RBAC: `oc auth can-i list pods --as=<user>`
4. Verify kind mapping via discovery (plural mismatch → hidden results)
5. Works in STDIO but not HTTP → auth issue, not data issue

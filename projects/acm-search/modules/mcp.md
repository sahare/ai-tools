# search-mcp-server — Technical Reference

**Repo:** https://github.com/stolostron/search-mcp-server
**Language:** Go (+ TypeScript legacy impl) | **Entry:** `cmd/server/main.go`
**Runs on:** Hub cluster (deployed via Helm)

## What it does

Exposes ACM Search data to AI assistants (Claude, etc.) via the Model Context Protocol. Connects directly to PostgreSQL (bypasses GraphQL layer). Admin-only access.

## The One Tool: `find_resources`

| Parameter | Description |
|-----------|-------------|
| kind | Resource kind or comma-separated: "Pod" or "Pod,ConfigMap" |
| name | Exact match or glob: "nginx-*" |
| namespace | Comma-separated or wildcard: "kube-*,default" |
| cluster | Cluster name or comma-separated |
| labelSelector | K8s selector: "app=nginx,env!=test" |
| clusterSelector | Filter by cluster labels: "env=prod" |
| status | Status filter: "Running,Failed" |
| textSearch | Full-text across all JSON fields |
| ageNewerThan / ageOlderThan | Time: "1h", "2d", "1w" |
| outputMode | list (default), count, summary, health |
| groupBy | Group by: status, namespace, cluster, kind, label:key |
| limit | 1–1000, default 50 |
| sortBy / sortOrder | name/created/namespace/cluster, asc/desc |

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `cmd/server` | Main entry point | `main.go` |
| `internal/findresources` | Core tool implementation, SQL query building | |
| `internal/server` | MCP protocol handling, tool registration | |
| `internal/utils` | Shared utilities | |
| `pkg/config` | Configuration from env vars | |
| `pkg/database` | PostgreSQL connection and queries | |
| `pkg/types` | Data types | |
| `docs/` | Authentication docs | `authentication-authorization.md` |
| `helm/` / `charts/` | Helm deployment | |

## Authorization

Stricter than regular Search — requires ACM admin. Access granted if user:
1. Is in `system:masters` or `system:cluster-admins`
2. Is in a group with `cluster-admin` ClusterRoleBinding
3. Can create ManagedClusters (`open-cluster-management:cluster-manager-admin`)

Flow: TokenReview → SSAR for `* *` → SSAR for ManagedCluster create → grant if either passes.

## Deployment

```bash
./scripts/create-secret.sh       # Auto-discovers ACM namespace, creates DB secret
make deploy-prebuilt             # Uses quay.io/stolostron/search-mcp-server:dev-preview

# Connect to Claude
export TOKEN=$(oc whoami -t)
export ROUTE_URL=$(oc get route acm-search-mcp-server-route -n acm-search -o jsonpath='{.spec.host}')
claude mcp add --transport http --scope project acm-search \
  https://$ROUTE_URL/mcp --header "Authorization: Bearer $TOKEN"
```

## How to: add a new MCP tool

1. Add `ToolDefinition` in `internal/server/tools.go` (name, description, input schema)
2. Add handler function using `mcp.CallToolRequest`
3. Add SQL query in `pkg/database/queries.go`
4. Add tests
5. Update `docs/` if the tool has special auth requirements

## How to: debug auth issues

1. Check token is valid: `oc whoami` with the same token
2. Check route is accessible: `curl -sk https://$ROUTE_URL/mcp`
3. Check if user has admin access: `oc auth can-i create managedclusters`
4. Check MCP server logs: `oc logs -l app=acm-search-mcp-server`

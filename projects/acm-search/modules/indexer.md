# search-indexer — Technical Reference

**Repo:** https://github.com/stolostron/search-indexer
**Language:** Go | **Entry:** `main.go`
**Runs on:** Hub cluster only (single replica)

## What it does

Receives sync payloads from all collectors (one per managed cluster + hub), batch-writes to PostgreSQL, and maintains Cluster nodes by watching hub ManagedCluster resources.

## Sync Protocol

Collectors POST to `/aggregator/clusters/{id}/sync`.
- Header `X-Overwrite-State: true` → resync (full state); `false` → diff (incremental)

### Diff (sync) — `pkg/database/sync.go`
```sql
-- ADD: upsert resource
INSERT INTO search.resources AS r VALUES($1,$2,$3)
ON CONFLICT (uid) DO UPDATE SET data=$3 WHERE r.uid=$1 AND r.data IS DISTINCT FROM $3

-- UPDATE: update resource data
UPDATE search.resources SET data=$2 WHERE uid=$1

-- DELETE: remove resources + cascade edges
DELETE FROM search.resources WHERE uid IN (...)
DELETE FROM search.edges WHERE sourceId IN (...) OR destId IN (...)

-- ADD EDGE: insert (no-op on conflict)
INSERT INTO search.edges VALUES($1,$2,$3,$4,$5,$6)
ON CONFLICT (sourceid, destid, edgetype) DO NOTHING
```

### Resync — `pkg/database/resync.go`
- Streams request body with `json.NewDecoder` (avoids loading 100k+ resources into memory)
- Upserts each resource
- Deletes stale: `DELETE FROM search.resources WHERE cluster=$1 AND uid NOT IN ($2)`
- Detects hub cluster rename and purges old data

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `pkg/server` | HTTP router, mTLS, rate limiters | `server.go`, `syncHandler.go`, `requestLimiter.go`, `largeRequestLimiter.go` |
| `pkg/database` | PostgreSQL connection, sync/resync, batch, schema init | `connection.go`, `sync.go`, `resync.go`, `batch.go`, `cache.go`, `upsertCluster.go` |
| `pkg/clustersync` | Leader-elected ManagedCluster/Info informers → Cluster nodes | `clusterSync.go` |
| `pkg/model` | Resource, Edge, SyncEvent, SyncResponse types | `model.go` |
| `pkg/config` | Configuration from env vars | `config.go` |
| `pkg/metrics` | Prometheus metrics | `metrics.go` |

## Batch System (`pkg/database/batch.go`)

- `batchWithRetry` wraps pgx.Batch with auto-flush and error isolation
- **Auto-flush:** queue reaches `batchSize` (default 500) → spawns goroutine to `sendBatch()`
- **Error isolation:** on batch error, binary-search recursion (split in half, retry) until single-item batch → logged to SyncError, skipped
- **Connection error:** `unexpected EOF` or `failed to connect` → sets `connError`, all future `Queue()` calls return error → collector gets 500 → triggers resync

## Rate Limiting

| Limiter | Scope | Effect |
|---------|-------|--------|
| `requestLimiter` | Per-cluster concurrent requests | Returns 429 if exceeded |
| `largeRequestLimiter` | Global concurrent resync requests | Returns 429 if exceeded |

Collector treats 429 as "indexer busy" → retries with backoff.

## ClusterSync (`pkg/clustersync/clusterSync.go`)

Creates Cluster nodes in the database (not from collectors). Leader-elected (Kubernetes Lease).

**Cluster node UID format:** `cluster__<clusterName>`

Three informers:
1. **ManagedCluster** — cpu, memory, kubernetesVersion, labels, conditions, created
2. **ManagedClusterInfo** — apiEndpoint, consoleURL, nodes count (merged via `ReadClustersCache()`)
3. **ManagedClusterAddon** (filtered to `search-collector`) — on delete: remove resources+edges, keep cluster node

Lifecycle:
- ManagedCluster delete → delete cluster node + all resources + all edges
- Addon delete → delete resources+edges, keep cluster node (cluster still exists)
- Stale cleanup on startup: compare DB vs clusters with `search-collector` addon label

## Commands

```bash
make build    # Build binary
make test     # Run tests (needs postgres or mock)
make lint     # Lint
make run      # Run locally
```

## How to: debug why resources aren't being indexed

1. Check indexer logs: `oc logs -l name=search-indexer -n open-cluster-management`
2. Look for `AddErrors` in SyncResponse (returned to collector)
3. Check for 429 responses (rate limiting)
4. Check batch errors (binary-search isolation will log the specific failing resource)
5. Query postgres directly to confirm data presence/absence

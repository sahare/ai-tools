# search-indexer — Technical Reference

**Repo:** https://github.com/stolostron/search-indexer
**Language:** Go 1.25 | **Entry:** `main.go`
**Runs on:** Hub cluster only (single replica, leader-elected for cluster watch)

## What it does

Receives sync payloads from all collectors (one per managed cluster + hub), batch-writes to PostgreSQL, and maintains Cluster pseudo-nodes by watching hub ManagedCluster/ManagedClusterInfo resources.

## Architecture

```
main()
 ├─ config.Cfg (env) + Validate()
 ├─ database.NewDAO → InitializeTables (schema/indexes)
 ├─ go clustersync.ElectLeaderAndStart (LeaseLock → informers → UpsertCluster/Delete)
 └─ go server.StartAndListenTLS :3010
         POST /aggregator/clusters/{id}/sync
         GET  /liveness | /readiness | /metrics
```

**Two independent data paths:**
1. **Collector sync** (HTTP) — resources/edges from hub + managed collectors.
2. **Cluster sync** (k8s informers, leader only) — Cluster pseudo-node `uid=cluster__<name>` from ManagedCluster/ManagedClusterInfo.

## Database Schema

```sql
search.resources (uid TEXT PK, cluster TEXT, data JSONB)
search.edges     (sourceId, sourceKind, destId, destKind, edgeType, cluster,
                  PK(sourceId, destId, edgeType))
```

Indexes: GIN on `data->kind|namespace|name`, btree `cluster`, composite GIN for RBAC keys (`_hubClusterResource`, `namespace`, `apigroup`, `kind_plural`).

**What gets stored:** only `uid`, `cluster` (from URL path), and `json.Marshal(Properties)`. The `Resource.Kind` and `ResourceString` struct fields are NOT separate columns—queryable fields must be inside `properties`.

## Sync Protocol

Collectors POST to `/aggregator/clusters/{id}/sync`.
- Header `X-Overwrite-State: true` → resync (full state); `false`/missing → diff (incremental)
- Cluster name comes from the **URL path**, not the payload body

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
- Upserts each resource; collects UIDs
- Deletes stale: `DELETE FROM search.resources WHERE cluster=$1 AND uid NOT IN ($2)`
- Deletes orphan edges (source/dest not in UID set)
- Detects hub cluster rename → async cleanup

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `pkg/server` | HTTP router, TLS, rate limiters | `server.go`, `syncHandler.go`, `requestLimiter.go`, `largeRequestLimiter.go` |
| `pkg/database` | PostgreSQL connection, sync/resync, batch, schema init | `connection.go`, `sync.go`, `resync.go`, `batch.go`, `cache.go`, `upsertCluster.go` |
| `pkg/clustersync` | Leader-elected ManagedCluster/Info informers → Cluster nodes | `clusterSync.go` |
| `pkg/model` | Resource, Edge, SyncEvent, SyncResponse types | `model.go` |
| `pkg/config` | Configuration from env vars | `config.go` |
| `pkg/metrics` | Prometheus metrics | `metrics.go` |

## Environment Variables

| Env | Default | Purpose |
|-----|---------|---------|
| `DB_HOST` | localhost | |
| `DB_PORT` | 5432 | |
| `DB_NAME` | **required** | |
| `DB_USER` | **required** | |
| `DB_PASS` | **required** (URL-escaped) | |
| `DB_BATCH_SIZE` | 2500 | pgx batch flush size |
| `DB_MAX_CONNS` | 10 | pgxpool |
| `HTTP_TIMEOUT` | 300000 ms | Read/Write/Header timeouts |
| `MAX_BACKOFF_MS` | 300000 | Delete/hub-cleanup retry cap |
| `POD_NAME` | local-dev | Leader election identity |
| `POD_NAMESPACE` | open-cluster-management | Lease namespace |
| `REDISCOVER_RATE_MS` | 300000 | Informer CRD rediscover + factory resync |
| `REQUEST_LIMIT` | 25 | Concurrent sync requests (non-hub) |
| `LARGE_REQUEST_LIMIT` | 5 | Concurrent >20MB bodies |
| `LARGE_REQUEST_SIZE` | 20 MiB | Large-request threshold |
| `AGGREGATOR_ADDRESS` | `:3010` | Listen addr |
| `SLOW_LOG` | 1000 ms | Slow op warning threshold |

## Batch System (`pkg/database/batch.go`)

- Queue until `DB_BATCH_SIZE`, then async `SendBatch`
- On batch error: binary-split until single failing item → recorded in `SyncResponse.*Errors`
- Connection errors (`unexpected EOF` / `failed to connect`): sets `connError`, stops queueing
- pgx batch = transaction → whole batch fails on one error

## Rate Limiting

| Limiter | Scope | Effect |
|---------|-------|--------|
| `requestLimiter` | One in-flight per cluster + global `REQUEST_LIMIT` (25) | 429 if exceeded |
| `largeRequestLimiter` | `ContentLength > LARGE_REQUEST_SIZE` capped to 5 | 429 if exceeded |

**Hub bypass:** requests from `Host == "search-indexer.open-cluster-management.svc:3010"` skip global limit.

## ClusterSync (`pkg/clustersync/`)

Creates Cluster pseudo-nodes in the database (not from collectors). Leader-elected (Kubernetes Lease `search-indexer.open-cluster-management.io`).

**Cluster node UID format:** `cluster__<clusterName>`

Three informers:
1. **ManagedCluster** — cpu, memory, kubernetesVersion, labels, conditions → upsert; delete → wipe everything
2. **ManagedClusterInfo** — apiEndpoint, consoleURL, nodes count → upsert only (merged via cache)
3. **ManagedClusterAddon** (filtered to `search-collector`) — delete → remove resources+edges, keep cluster node

Cache merge: both informers write to same UID; `addAdditionalProperties` merges missing keys so one doesn't wipe the other's fields.

On startup: `deleteStaleClusterResources` — DB clusters without `search-collector` addon label.

## Commands

```bash
make setup      # Generate TLS certs in sslcert/
make setup-dev  # Print DB env exports + port-forward hint
make run        # go run -tags development (DROPS search schema on start)
make test       # go test ./... -failfast
make lint       # golangci-lint + gosec
make test-send  # curl mock resync with sample data
```

## Non-obvious Gotchas

1. **Two "sync" concepts:** HTTP collector sync (`pkg/server`) vs k8s clustersync (`pkg/clustersync`) — different packages, different functions
2. **Only `Properties` map lands in DB** — `Kind`/`ResourceString`/`Metadata` on the struct are discarded on write
3. **Cluster name comes from URL** — mismatch with payload = wrong partition
4. **Resync streams JSON**; delta fully unmarshals — large resyncs are intentional memory optimization
5. **One request per cluster** at a time; 429 is normal under load — collectors retry
6. **`interCluster` edges** excluded from totals and resync edge reset
7. **DevelopmentMode (`make run`) drops all search data** on start
8. **Readiness does NOT check Postgres**
9. **Addon list hardcoded** (9 addons) for Cluster node `addon` property map

## Agent Playbooks

### Add a new field to the sync payload
1. Change **search-collector** transform to put the field in `properties` (and edges if relational)
2. Indexer: usually **no code change** — entire `Properties` map is marshaled to `data`
3. If API must filter efficiently: add GIN index in `InitializeTables`
4. Do NOT expect top-level `Resource` fields other than `uid` to persist

### Debug "resources aren't indexed"
1. Check indexer logs for cluster name; look for 429s
2. Response `AddErrors`/`UpdateErrors`/`DeleteErrors` — per-UID DB failures after batch bisect
3. Query postgres: `SELECT uid, data->>'kind' FROM search.resources WHERE cluster='<c>' LIMIT 20`
4. Totals mismatch → collector will resync automatically
5. Cluster node wrong → check leader election, ManagedCluster/Info informers, cache merge
6. Stale data: addon not `available` but rows remain until stale cleanup on leader start

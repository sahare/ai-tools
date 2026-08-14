# search-collector — Technical Reference

**Repo:** https://github.com/stolostron/search-collector
**Language:** Go 1.25 | **Entry:** `main.go`
**Runs on:** Hub cluster + every managed cluster (via OCM addon)

## Pipeline

Linear: **Informer → Transformer → Reconciler → Sender**

```
K8s API watch → informer.GenericInformer
                    ↓ Event{Type, Node}
               transforms.Transformer   (fan-out to numCPU goroutines)
                    ↓ NodeEvent
               reconciler.Reconciler    (in-memory state: all nodes + edges)
                    ↓ Diff{add/update/delete nodes+edges}
               send.Sender              (POST JSON to indexer /aggregator/clusters/<name>/sync)
```

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `pkg/config` | Env vars, feature flags, runtime mode | `config.go` |
| `pkg/informer` | Dynamic informers per GVR, CRD watch, discovery | `runInformers.go`, `informer.go`, `supportedResources.go`, `collectorConfigReload.go` |
| `pkg/transforms` | Type dispatch, typed builders, configurable collection | `transformer.go`, `common.go`, `configurableCollection.go`, `collectorConfigReload.go`, `genericResourceConfig.go` |
| `pkg/reconciler` | In-memory state (current/previous/diff maps), edge rebuild | `reconciler.go` |
| `pkg/send` | HTTP sender, diff/complete payloads, mTLS, backoff | `sender.go`, `httpsClient.go` |
| `pkg/lease` | ManagedClusterAddon lease keepalive | `lease.go` |
| `pkg/metrics` | Prometheus metrics | `metrics.go` |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| AGGREGATOR_URL | https://localhost:3010 | Indexer URL |
| CLUSTER_NAME | local-cluster | Name of cluster being collected |
| HEARTBEAT_MS | 300000 (5 min) | Keepalive interval |
| MAX_BACKOFF_MS | 600000 (10 min) | Max retry wait |
| REDISCOVER_RATE_MS | 60000 (1 min) | Min interval between CRD re-syncs |
| REPORT_RATE_MS | 5000 (5 sec) | Send interval |
| RUNTIME_MODE | production | 'development' for local dev |
| DEPLOYED_IN_HUB | false | true = hub collector (sets `_hubClusterResource`) |
| FEATURE_CONFIGURABLE_COLLECTION | false | Enable CollectorConfig rules |
| COLLECT_ANNOTATIONS | false | Collect all annotations globally |
| NS_FILTER_CACHE_TTL_MS | 300000 | Namespace filter cache |

## Informer Lifecycle (`pkg/informer/`)

### Startup
1. Start CRD informer; wait for cache sync
2. Wire ConfigReloadHandler + namespace filter (if configurable collection)
3. First `syncInformers` — discover GVRs, start one informer per type (serialized, 10s wait each)
4. Close `initialized` channel → sender can start
5. Select loop: CRD sync channel OR config resync signal

### CRD Watch → Dynamic Informers
- CRD Add/Update (Established) → queue sync; extract `additionalPrinterColumns` into cache
- CRD Delete → remove columns from cache; queue sync
- `syncInformers`: re-discover GVRs, start new informers, stop removed ones
- Rate-limited by `REDISCOVER_RATE_MS` (min gap between syncs)

### `SupportedResources()` Filters
1. Hard-deny: `events`, `projects`, `clusters`, `clusterstatuses`, `oauthaccesstokens`
2. Legacy ConfigMap allow/deny (uses **plural resource name**, deny wins)
3. CollectorConfig exclude: `IsResourceExcluded(apiGroup, Kind)` — uses **Kind**
4. Must have `watch` verb; subresources skipped

### GenericInformer (custom, not SharedInformerFactory)
- **List:** paginated (250), namespace filter, emits Add for all results
- **Watch:** ADDED/MODIFIED/DELETED; namespace filter; retry backoff `min(retries*2, 120)s`
- `TriggerResync`: interrupts watch → re-list

## Configurable Collection (`pkg/transforms/configurableCollection.go`)

Feature gate: `FEATURE_CONFIGURABLE_COLLECTION`. Reads `merged-collector-config` from cluster namespace.

### Rule Evaluation: Last Matching Rule Wins

```
excluded := false
for each rule in excludeRules (ordered):
    if rule matches (group, kind):   // "*" matches any
        excluded = (rule.action == ActionExclude)
return excluded
```

- `exclude *.* → include Deployment.apps` → Deployments collected, rest excluded
- Every non-exclude rule **always** appends `ActionInclude` before enrichment
- Bare include (no fields) is valid — re-includes after broader exclude

### Include Enrichment

| Rule flag | Effect |
|-----------|--------|
| `collectConditions: true` | Extract `status.conditions` → `condition` property map |
| `collectAnnotations: true` | Extract annotations (>64 char values trimmed) |
| `collectAdditionalPrinterColumnsPriority: N` | Include CRD printer columns at/above priority |
| `fields[].{name, jsonPath, type}` | JSONPath extraction into properties |

Field validation: exactly one kind + one apiGroup required; name collision with built-in → skip with warning.

### `fieldSuffix` Collision Avoidance
```go
name = field.Name + "." + fieldSuffix  // e.g. "status.grc"
```
Checks against existing config properties only. Does NOT check common properties (`name`, `kind`) or typed-builder fields.

### Dynamic Reload (no pod restart)

Trigger: watch on `merged-collector-config` GVR. Skips status-only updates (generation unchanged).

`ReloadAndDiff` steps:
1. Snapshot current config (RLock)
2. Full reload + atomic swap (Lock)
3. Diff old vs new configs
4. If `ExcludeRulesChanged` → full `syncInformers` (start/stop informers)
5. If `AffectedResources` → targeted re-list of changed resource types
6. If nothing changed → no-op

### JSONPath Extraction
- Auto-wraps in `{}`: accepts `.spec.x`, `{.spec.x}`, `{.spec.x`
- Supports filters: `[?(@.type=="Ready")]`
- Missing path → `DefaultValue` (or skip)
- Type coercion: string/number/boolean/bytes per `DataType`

### Known Gotchas
- **Wildcard `collectAnnotations` doesn't work at runtime** — `commonAnnotations` only looks up specific kind keys, not wildcards. Use concrete kinds or set `COLLECT_ANNOTATIONS=true`
- **Wildcard `collectConditions` DOES work at runtime** — different code path
- **Two allow/deny systems coexist** — ConfigMap (plural resource names) + CollectorConfig (Kind)

## Reconciler (`pkg/reconciler/reconciler.go`)

### Internal State

| Map | Key | Purpose |
|-----|-----|---------|
| `currentNodes` | UID | Live state of cluster |
| `previousNodes` | UID | Snapshot at last send |
| `diffNodes` | UID | Changes since last send |
| `edgeFuncs` | UID | Per-node `ComputeEdges` closures |
| `previousEdges` | srcUID→destUID | Edge state at last send |
| `purgedNodes` (LRU 500) | UID | Recent deletes — drops stale late adds |

UID format: `{clusterName}/{k8sUID}`

### Diff() vs Complete()
- **Diff:** if diffNodes non-empty → classify Create/Update/Delete nodes; recompute all edges; diff edges
- **Complete:** flatten all currentNodes + all edges (used with `ClearAll`)
- Both call `allEdges()` (full edge rebuild from edgeFuncs) unless diff is empty

### Update-Skip Logic
If Properties unchanged from previous → update is **skipped**. Exceptions:
- `Application` / `Subscription` — metadata drives edges
- `ValidatingAdmissionPolicyBinding` — paramRef may change
- Policy types — `relObjs` metadata changes
- Gatekeeper constraints — same `relObjs` check

### Application-First Ordering
`allEdges()` processes Application UIDs **before** others so `_hostingApplication` metadata is set on Subscriptions before their edge builders run.

## Sender (`pkg/send/sender.go`)

### Payload Types
- **Complete** (`ClearAll: true`): all nodes as AddResources, all edges — first send or recovery
- **Diff** (`ClearAll: false`): add/update/delete nodes + add/delete edges
- **Empty** (heartbeat): valid when nothing changed but interval elapsed

### Paths
| Mode | HTTP Path |
|------|-----------|
| Hub | `/aggregator/clusters/{clusterName}/sync` |
| Managed | `/{clusterName}/aggregator/sync` |

### State Machine
1. `lastSentTime == -1` → complete only
2. Else build diff; if empty and within heartbeat → skip
3. Send diff; on failure → try complete; if that fails → `lastSentTime = -1`

### Retry / Backoff
- 429 ("indexer busy") → same payload, retry after interval
- Other errors → reload TLS/config, return error (outer loop escalates)
- Backoff: `min(1000 * 2^retry + jitter, MaxBackoffMS)` ms

### Validation
Response `TotalResources` / `TotalEdges` must match expected counts (accounting for errors). Mismatch → treated as send failure → eventually forces complete resync.

## Commands

```bash
make build     # CGO_ENABLED=1 go build -o output/search-collector
make test      # go test ./... -failfast (DEPLOYED_IN_HUB=true)
make lint      # golangci-lint + gosec
make run       # GOGC=25 go run -tags development main.go --v=2
make coverage  # test + HTML coverage report
```

## Non-obvious Gotchas

1. **`REDISCOVER_RATE_MS` is 60s in code** — some docs say 2 min; trust `config.go`
2. **Delete path bypasses transformer** — goes straight to reconciler with UID-only node
3. **Every list re-emits Add** — reconciler update-skip prevents payload storms
4. **Full edge rebuild every non-empty Diff** — expensive on large clusters
5. **`resourceIndex` only populated by watch events, not list** — stopping an informer may not clean all reconciler state; orphans persist until restart
6. **NS filter is fail-open** — missing/error → collect all namespaces
7. **Typed builders must call `applyDefaultTransformConfig`** — else CollectorConfig fields never apply
8. **Feature flag off → no exclude rules, no CR load, no reload handler** — defaults only
9. **Bare include rules were silently skipped** before PR #925 — now `appendExcludeRule(ActionInclude)` runs before enrichment check
10. **Validation mismatch forces complete resync** — edge accounting must include Add/Delete errors

## Agent Playbooks

### Add a new property to a resource
1. Find `pkg/transforms/{kind}.go` → extract in `BuildNode()`: `node.Properties["myProp"] = ...`
2. Add test in `{kind}_test.go`
3. Or no-code: CollectorConfig `fields[].jsonPath`

### Add support for a new resource kind
1. Create `pkg/transforms/{kind}.go` with `BuildNode()` + `BuildEdges()`
2. Register in `transformer.go` switch: `case [2]string{"MyKind", "mygroup.io"}`
3. Call `applyDefaultTransformConfig(node, additionalColumns)` at end of BuildNode
4. No informer registration needed — auto-discovered from GVR

### Debug missing resources
1. Check if excluded: `IsResourceExcluded` for that apiGroup/Kind
2. Check informer started: look for GVR in logs at startup
3. Check namespace filter: `collectNamespaces` may be filtering
4. Check reconciler: update-skip dropping unchanged properties?
5. Check sender: 429s or resync loops?
6. Check indexer AddErrors in SyncResponse

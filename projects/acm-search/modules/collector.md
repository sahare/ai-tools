# search-collector — Technical Reference

**Repo:** https://github.com/stolostron/search-collector
**Language:** Go | **Entry:** `main.go`
**Runs on:** Hub cluster + every managed cluster (via OCM addon)

## Pipeline (startup order)

1. Initialize config (`pkg/config/` — env vars or `config.json`)
2. Start lease reconciler (non-hub only — keeps ManagedClusterAddon lease alive)
3. Start Prometheus metrics server
4. Load configurable collection config (CollectorConfig CRD rules)
5. Create Transformer (N goroutines = NumCPU)
6. Create Reconciler
7. Create Sender (attached to reconciler)
8. Run Informers — **blocks until initial cluster state is fully loaded**
9. Start Sender loop

## Package Map

| Package | Purpose | Key files |
|---------|---------|-----------|
| `pkg/config` | Env vars, feature flags, runtime mode | `config.go` |
| `pkg/informer` | Dynamic informers per GVR, CRD watch, discovery | `runInformers.go`, `informer.go`, `supportedResources.go` |
| `pkg/transforms` | Type dispatch, typed builders, configurable collection | `transformer.go`, `common.go`, `configurableCollection.go`, `collectorConfigReload.go`, `genericResourceConfig.go` |
| `pkg/reconciler` | In-memory state (current/previous/diff maps), edge rebuild | `reconciler.go` |
| `pkg/send` | HTTP sender, diff/complete payloads, mTLS, backoff | `sender.go`, `httpsClient.go` |
| `pkg/lease` | ManagedClusterAddon lease keepalive | `lease.go` |
| `pkg/metrics` | Prometheus metrics | `metrics.go` |

## Informer (`pkg/informer/runInformers.go`)

- Discovers all listable+watchable resources via `DiscoveryClient` → `SupportedResources()`
- Starts one dynamic informer per GVR
- Watches CRDs — dynamically adds/removes informers when CRDs change
- Rate-limits re-sync via `REDISCOVER_RATE_MS` (default 2 min)
- CRD `additionalPrinterColumns` cached per GVR and passed to transform
- Add/Update → transformer input channel; Delete → directly to reconciler

## Transformer (`pkg/transforms/transformer.go`)

- N goroutines (one per CPU), shared input channel
- Dispatches on `[kind, apiGroup]` → 30+ typed builders
- Panics caught by `handleRoutineExit()` — goroutine restarts, bad resource discarded
- Output: `NodeEvent` = `Node` (UID + Properties map) + `ComputeEdges func(NodeStore) []Edge`

### Typed builders — key kinds

| Resource | Special Properties | Special Edges |
|----------|-------------------|---------------|
| Pod | status, restarts, hostIP, podIP, image | runsOn→Node |
| Node | cpu, memory, architecture, osImage | — |
| Deployment/DaemonSet/StatefulSet/ReplicaSet | replicas (available/current/desired/ready) | ownedBy |
| Service | clusterIP, type, ports | selects→Pods |
| Policy (policy.open-cluster-management.io) | compliant, disabled, severity | — |
| Application (app.k8s.io) | — | uses→Subscription |
| GatekeeperConstraint | additionalPrinterColumns; enforcementAction | — |
| VirtualMachine (kubevirt.io) | status, ready, node, IP | — |

Unknown types → `GenericResourceBuilder`. Generic CRD resources can have properties defined in `genericResourceConfig.go` (JSONPath-based extraction).

### Common properties on every node

name, namespace, kind, apigroup, apiversion, kind_plural, created, label, annotation, _hubClusterResource

### Edge types

ownedBy, runsOn, selects, attachedTo, deployedBy, definedBy, uses, contains, migrationOf, mutatedBy

## Configurable Collection (`pkg/transforms/configurableCollection.go`)

Reads the `merged-collector-config` CollectorConfig from the cluster and applies:
- **Include rules:** add fields/conditions/annotations to matching resources
- **Exclude rules:** prevent collection of matching apiGroups/kinds (`IsResourceExcluded()`)
- **Last entry wins:** an include after an exclude for the same resource re-enables collection

### Dynamic reload (ACM-20047, `collectorConfigReload.go`)

The collector watches the `CollectorConfig` GVR itself. On change:
1. `ReloadAndDiff()` snapshots current config, reloads from cluster, diffs
2. `AffectedResources` → targeted re-list of changed resource types
3. `ExcludeRulesChanged` → full `syncInformers` pass (start/stop informers)
4. No change → no-op (cheap)

**No collector restart needed** for config changes.

## Reconciler (`pkg/reconciler/reconciler.go`)

| Map | Key | Purpose |
|-----|-----|---------|
| currentNodes | UID | Current live state |
| previousNodes | UID | Snapshot at last send |
| diffNodes | UID | Changes since last send |
| edgeFuncs | UID | Edge builders — recomputed every send |
| purgedNodes (LRU 500) | UID | Prevents out-of-order add-after-delete |

Key behaviors:
- Update skip: if Properties unchanged, skip (exceptions: Application, Subscription, Policy)
- Application-first ordering in `allEdges()` for `_hostingApplication` metadata
- Full edge rebuild on every `Diff()`/`Complete()`

## Sender (`pkg/send/sender.go`)

- **First send:** complete payload with `ClearAll=true`
- **Subsequent:** diff payload (`ClearAll=false`)
- **On diff error:** falls back to complete automatically
- **Retry:** exponential backoff with jitter; reloads TLS config on error
- **Heartbeat:** empty payload every `HEARTBEAT_MS` (default 5 min)
- **Validation:** compares `TotalResources`/`TotalEdges` in response; triggers resync on mismatch
- **Path:** `POST /aggregator/clusters/{clusterName}/sync`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| AGGREGATOR_URL | https://localhost:3010 | Indexer URL |
| CLUSTER_NAME | local-cluster | Cluster being collected |
| HEARTBEAT_MS | 300000 (5 min) | Keepalive interval |
| MAX_BACKOFF_MS | 600000 (10 min) | Max retry wait |
| REDISCOVER_RATE_MS | 120000 (2 min) | Min interval between informer re-syncs |
| REPORT_RATE_MS | 5000 (5 sec) | Send interval |
| RUNTIME_MODE | production | 'development' for local dev |
| FEATURE_CONFIGURABLE_COLLECTION | false | Enable CollectorConfig rules |

## Commands

```bash
make build          # Build binary
make test           # Run unit tests
make lint           # golangci-lint + gosec
make run            # Run locally (needs KUBECONFIG)
make docker-build   # Build container image
```

## How to: add a new property to a resource

1. Find/create `pkg/transforms/{kind}.go`
2. In `BuildNode()`, extract the property: `node.Properties["myProp"] = resource.Spec.MyField`
3. Add test in `pkg/transforms/{kind}_test.go`
4. Or no-code: use `CollectorConfig` field with JSONPath (processed by `applyDefaultTransformConfig`)

## How to: add support for a new resource kind

1. Add typed builder in `pkg/transforms/{kind}.go` implementing `BuildNode()` + optionally `BuildEdges()`
2. Register in `transformer.go` switch case: `case [2]string{"MyKind", "mygroup.io"}: ...`
3. Add `additionalColumns ...ExtractProperty` parameter to support configurable collection
4. Call `applyDefaultTransformConfig(node, additionalColumns)` at the end of BuildNode

# ACM Search v2 - Knowledge Base

Built from deep reading of all 6 stolostron/search-* repositories. Every source file that matters for daily development and bug-fixing has been analyzed.

**Repositories covered:**
- https://github.com/stolostron/search-v2-operator — deploys all search pods, lifecycle operator
- https://github.com/stolostron/search-collector — collects k8s resources, runs on every cluster
- https://github.com/stolostron/search-indexer — writes resources to PostgreSQL, receives from collectors
- https://github.com/stolostron/search-v2-api — GraphQL query API, RBAC enforcement
- https://github.com/stolostron/search-e2e-test — end-to-end test suite (Jest + Cypress)
- https://github.com/stolostron/search-mcp-server — MCP server for AI assistant access

---

## What ACM Search Does

ACM Search gives every user a **unified, RBAC-enforced search interface** across all clusters managed by Red Hat Advanced Cluster Management. It:

1. Continuously collects Kubernetes resources from every managed cluster via a lightweight agent (search-collector)
2. Indexes them into a central PostgreSQL database on the hub cluster (search-indexer)
3. Exposes a GraphQL API so the ACM console and tools can query across hundreds of clusters in a single request (search-v2-api)
4. Returns only results the user is authorized to see — the index is complete, but queries are RBAC-scoped

---

## Architecture: The 5 Hub Pods

All run in `open-cluster-management` namespace on the hub cluster.

| Pod | Image Env Var | Replicas | Role |
|-----|---------------|----------|------|
| search-v2-operator-controller-manager | N/A (own binary) | 1 (+kube-rbac-proxy sidecar) | Kubernetes Operator. Reconciles all other search resources via the Search CR. |
| search-postgres | POSTGRES_IMAGE | 1 (fixed) | PostgreSQL. Tables: `search.resources` (uid, cluster, data JSONB) and `search.edges`. |
| search-indexer | INDEXER_IMAGE | 1 | HTTP server on :3010. Receives sync payloads from all collectors via mTLS. Batch writes to PostgreSQL. |
| search-api | API_IMAGE | 1 (scalable) | GraphQL server on :4010, metrics on :4011. Authenticates caller, builds RBAC profile, queries PostgreSQL. |
| search-collector (hub) | COLLECTOR_IMAGE | 1 (fixed) | Same binary as managed-cluster collectors. Watches the hub itself. Sets `_hubClusterResource=true` on all resources. |

**Managed cluster component:** One `klusterlet-addon-search` pod per managed cluster in `open-cluster-management-agent-addon` namespace. Deployed by the operator via OCM add-on framework using a Helm chart embedded in the operator binary (`addon/manifests/chart/`).

---

## Database Schema

### search.resources
```sql
uid TEXT PRIMARY KEY, cluster TEXT, data JSONB
```
Indexes:
- GIN on `data->'kind'`, `data->'namespace'`, `data->'name'`, `data->'_hubClusterResource'`
- btree on `cluster`
- Composite GIN on `(_hubClusterResource, namespace, apigroup, kind_plural)`
- btree on `edges.sourceid`, `edges.destid`, `edges.cluster`

### search.edges
```sql
sourceId TEXT, sourceKind TEXT, destId TEXT, destKind TEXT, edgeType TEXT, cluster TEXT
PRIMARY KEY(sourceId, destId, edgeType)
```

---

## search-collector Deep Dive

### Internal Pipeline (main.go startup order)
1. Initialize config (env vars or `config.json`)
2. Start lease reconciler (non-hub collectors only — keeps ManagedClusterAddon lease alive)
3. Start Prometheus metrics server
4. Load configurable collection config (CollectorConfig CRD rules)
5. Create Transformer (N goroutines = NumCPU)
6. Create Reconciler
7. Create Sender (attached to reconciler)
8. Run Informers — **blocks until initial cluster state is fully loaded**
9. Start Sender loop

### Informer (pkg/informer/runInformers.go)
- Discovers all listable+watchable resources via DiscoveryClient → `SupportedResources()`
- Starts one dynamic informer per GVR
- Watches CRDs — dynamically adds/removes informers when CRDs change
- Rate-limits re-sync via `REDISCOVER_RATE_MS` (default 2 min) to avoid API server bursts
- CRD `additionalPrinterColumns` cached per GVR and passed through to transform
- Add/Update events → transformer input channel
- Delete events → directly to reconciler input (no transform needed)

### Transformer (pkg/transforms/transformer.go)
- N goroutines (one per CPU core), reads from shared input channel
- Dispatches on `[kind, apiGroup]` — 30+ typed builders
- Panics are caught by `handleRoutineExit()` — goroutine restarts, bad resource is discarded
- Every `NodeEvent` contains a `Node` (UID + Properties map) and a `ComputeEdges func(NodeStore) []Edge`

### Typed builders — key resource types
| Resource | Special Properties | Special Edges |
|----------|-------------------|---------------|
| Pod | status, restarts, hostIP, podIP, image | runsOn→Node |
| Node | cpu, memory, architecture, osImage, capacity, allocatable | — |
| Deployment/DaemonSet/StatefulSet/ReplicaSet | available/current/desired/ready replicas | ownedBy |
| Service | clusterIP, type, ports | selects→Pods |
| Job/CronJob | active, failed, succeeded | ownedBy |
| Policy (policy.open-cluster-management.io) | compliant, disabled, severity, standards | — |
| ConfigurationPolicy/CertificatePolicy/OperatorPolicy | compliant, severity | — |
| Application (app.k8s.io) | — | uses→Subscription |
| Subscription (apps.open-cluster-management.io) | — | deployedBy, definedBy edges |
| GatekeeperConstraint (constraints.gatekeeper.sh) | additionalPrinterColumns from CRD; enforcementAction | — |
| VirtualMachine / VirtualMachineInstance (kubevirt.io) | status, ready, node, IP, interfaces | — |
| ValidatingAdmissionPolicyBinding | paramRef, policyName | — |
| Kyverno Policy/ClusterPolicy | background, validationFailureAction | — |

Unknown types → `GenericResourceBuilder` (common properties only).
Gatekeeper constraints → `GkConstraintResourceBuilder` (additionalPrinterColumns from CRD).

### Common Properties on Every Node
| Property | Source |
|----------|--------|
| name | metadata.name |
| namespace | metadata.namespace (omitted for cluster-scoped) |
| kind | TypeMeta.Kind |
| apigroup / apiversion | TypeMeta.APIVersion split on '/' |
| kind_plural | GVR resource string (e.g. pods, deployments) |
| created | metadata.creationTimestamp (RFC3339 UTC) |
| label | metadata.labels map |
| annotation | metadata.annotations (values ≤ 64 chars; last-applied-config excluded) |
| _hubClusterResource | true if DeployedInHub=true (hub collector only) |
| _hostingSubscription | apps.open-cluster-management.io/hosting-subscription annotation |
| _hostingDeployable | apps.open-cluster-management.io/hosting-deployable annotation |

### Edge Types
| EdgeType | Meaning |
|----------|---------|
| ownedBy | Follows ownerReferences (Pod→ReplicaSet→Deployment) |
| runsOn | Pod→Node where scheduled |
| selects | Service→Pods matched by selector |
| attachedTo | PVC→PV |
| deployedBy | Resource→Subscription that deployed it |
| definedBy | Resource→Deployable that defines it |
| uses | Subscription→Channel/PlacementRule |
| contains | Application→Subscription |
| migrationOf | VirtualMachineInstanceMigration→VM |
| mutatedBy | Resource→Gatekeeper mutation (Assign/AssignImage) |

### Reconciler (pkg/reconciler/reconciler.go)
Key internal state maps:

| Map | Key | Value | Purpose |
|-----|-----|-------|---------|
| currentNodes | UID | Node | Current live state of cluster |
| previousNodes | UID | Node | Snapshot at last send — detects add vs update |
| diffNodes | UID | NodeEvent | Changes since last send — what Sender consumes |
| edgeFuncs | UID | func(NodeStore)[]Edge | Edge building functions — recomputed on every send |
| purgedNodes (LRU 500) | UID | NodeEvent | Last 500 deleted nodes — prevents out-of-order add-after-delete |
| previousEdges | srcUID→destUID | Edge | Edge state at last send — computes edge add/delete diffs |

**Key behaviors (where bugs hide):**
- **Out-of-order dedup:** If Delete arrives at time T and Add at T-1, the older Add is dropped (purgedNodes LRU)
- **Update skip optimization:** If Properties unchanged from previousNode, Update is skipped. EXCEPTIONS: Application/Subscription (metadata may change), ValidatingAdmissionPolicyBinding (paramRef change), Policy/GatekeeperConstraint (relObjs change)
- **Helm release dedup:** Multiple configmaps trigger same HelmRelease transform; reconciler keeps only highest revision
- **Application-first ordering:** `allEdges()` processes Application UIDs before all others so `_hostingApplication` metadata is set on Subscription nodes before other edges compute
- **Edge rebuild:** `allEdges()` is called on every `Diff()` and `Complete()` — full rebuild from ComputeEdges funcs

### Sender (pkg/send/sender.go)
- **First send always:** complete payload with `ClearAll=true` and full cluster state
- **Subsequent sends:** diff payload (`ClearAll=false`) with only changes
- **On diff error:** falls back to complete payload automatically
- **Retry:** exponential backoff with random jitter; reloads config (cert refresh) on error
- **Heartbeat:** sends empty payload every `HEARTBEAT_MS` (default 5 min) to keep connection alive
- **Validation:** compares `TotalResources` and `TotalEdges` in indexer response; triggers resync if mismatch
- **HTTP path (hub):** `POST /aggregator/clusters/{clusterName}/sync`
- **HTTP path (managed):** `POST /{clusterName}/aggregator/sync`

### Collector Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| AGGREGATOR_URL or AGGREGATOR_HOST + AGGREGATOR_PORT | https://localhost:3010 | Indexer URL |
| CLUSTER_NAME | local-cluster | Name of cluster being collected |
| HEARTBEAT_MS | 300000 (5 min) | Interval for empty keepalive payloads |
| MAX_BACKOFF_MS | 600000 (10 min) | Maximum retry wait time |
| REDISCOVER_RATE_MS | 120000 (2 min) | Min interval between informer re-syncs on CRD change |
| REPORT_RATE_MS | 5000 (5 sec) | Send interval |
| RUNTIME_MODE | production | Set to 'development' for local dev |

---

## search-indexer Deep Dive

### Sync Protocol
Collectors POST to `/aggregator/clusters/{id}/sync`. Header `X-Overwrite-State: true` = resync; false = diff.

**Diff (sync):** `SyncData()` in `pkg/database/sync.go`
```sql
-- ADD
INSERT into search.resources AS r values($1,$2,$3)
ON CONFLICT (uid) DO UPDATE SET data=$3 WHERE r.uid=$1 AND r.data IS DISTINCT FROM $3

-- UPDATE
UPDATE search.resources SET data=$2 WHERE uid=$1

-- DELETE resources + cascade delete edges
DELETE from search.resources WHERE uid IN (...)
DELETE from search.edges WHERE sourceId IN (...) OR destId IN (...)

-- ADD EDGE
INSERT into search.edges values($1,$2,$3,$4,$5,$6)
ON CONFLICT (sourceid, destid, edgetype) DO NOTHING
```

**Resync:** `ResyncData()` in `pkg/database/resync.go`
- Streams request body with `json.NewDecoder` (avoids loading 100k+ resources into memory)
- Upserts each incoming resource: `INSERT ... ON CONFLICT DO UPDATE SET data=$3 WHERE data!=$3`
- Collects all incoming UIDs
- `DELETE from search.resources WHERE cluster=$1 AND uid NOT IN ($2)` — removes stale resources
- Detects hub cluster rename via `hubClusterCleanUpWithRetry()` and deletes old hub cluster data

### Batch System (pkg/database/batch.go)
- `batchWithRetry` wraps pgx.Batch with auto-flush and error isolation
- **Auto-flush:** when queue reaches `batchSize` (default 500), spawns goroutine to `sendBatch()`
- **Error isolation:** on batch error, binary-search recursion (split in half, retry) until single-item batch fails → logged to SyncError and skipped
- **Connection error:** if `unexpected EOF` or `failed to connect` detected → sets `connError`, all future `Queue()` calls immediately return error → collector gets 500 → triggers resync
- `flush()` called at end to process remaining items

### Rate Limiting
- `requestLimiter.go` — limits concurrent sync requests per cluster
- `largeRequestLimiter.go` — limits total concurrent large (resync) requests globally
- Returns 429 → collector treats as "indexer busy" and retries with backoff

### ClusterSync (pkg/clustersync/clusterSync.go)
The Cluster node is created by the indexer (not by a collector) by watching hub resources.

**Cluster node UID format:** `cluster__<clusterName>`

Leader-elected (via Kubernetes Lease). Three informers:
1. **ManagedCluster** — primary: cpu, memory, kubernetesVersion, labels, addon enabled map, conditions (MHC/MCC status), created
2. **ManagedClusterInfo** — secondary: apiEndpoint, consoleURL, nodes count. Data merged via `ReadClustersCache()`
3. **ManagedClusterAddon** (filtered to `search-collector` only) — on delete: delete cluster resources+edges but keep cluster node

**On ManagedCluster delete:** delete cluster node + all resources + all edges
**On ManagedClusterAddon (search-collector) delete:** delete resources+edges, keep cluster node
**Stale cluster cleanup:** on startup, compares clusters in DB vs those with `feature.open-cluster-management.io/addon-search-collector=available` label; deletes stale
**Hub cluster rename:** on hub resync, detects if hub cluster name changed and purges old hub data

---

## search-v2-api Deep Dive

### GraphQL Schema (graph/schema.graphqls)
| Operation | Signature | Description |
|-----------|-----------|-------------|
| query search | `search(input: [SearchInput]): [SearchResult]` | Main search — items[], count, related[] |
| query searchComplete | `searchComplete(property: String!, query: SearchInput, limit: Int): [String]` | Autocomplete values for a property. Default limit 1000. |
| query searchSchema | `searchSchema(query: SearchInput): Map` | All indexed field names + possible values for filter UI |
| query messages | `messages: [Message]` | Server-side warnings/conditions |
| subscription watch | `watch(input: SearchInput): Event` | WebSocket push — fires on INSERT/UPDATE/DELETE matching filter. Driven by PostgreSQL LISTEN/NOTIFY. |

### SearchInput Fields
| Field | Type | Notes |
|-------|------|-------|
| keywords | [String] | Full-text match across all properties. Multiple = AND. Case-insensitive. |
| filters | [SearchFilter] | property + values. Multiple filters = AND. Multiple values per filter = OR. |
| filters[].values operators | String prefix | `=, !, !=, >, >=, <, <=` as prefix. Datetime values: `hour/day/week/month/year`. Wildcard: `*` in values. |
| limit | Int | Default 10,000. -1 removes limit. |
| offset | Int | Skip N results (pagination). Default 0. |
| orderBy | String | Format: `'property_name asc/desc'` |
| relatedKinds | [String] | Filter which related resource kinds to return. Empty = all. |

### SQL Query Builder (pkg/resolver/search.go + searchHelper.go)
Built with the `goqu` library. Every filter maps to a specific SQL pattern:

| Input | Data Type | SQL Generated |
|-------|-----------|---------------|
| `kind: pod` (lowercase) | string | `data->>'kind' ILIKE ANY ('{"pod"}')` — V1 backward compat |
| `name: nginx-*` (wildcard) | string | `data->>'name' LIKE 'nginx-%'` — `*` → `%` |
| `label: app=nginx` (object exact) | object | `data->'label' @> '{"app":"nginx"}'` |
| `label: app=*` (object wildcard) | object | `EXISTS(SELECT 1 FROM jsonb_each_text(data->'label') AS kv(key,value) WHERE key LIKE 'app' AND value LIKE '%')` |
| `created: hour` (datetime) | timestamp | `data->>'created' > '<RFC3339 timestamp 1h ago>'` |
| `status: Running` (single string) | string | `data->'status' ? 'Running'` — JSONB key-exists operator |
| `status: Running,Failed` (multiple) | string | `data->'status' ?| ARRAY['Running','Failed']` |
| `replicas: >3` (numeric) | number | `("data"->'replicas')::numeric > 3` |
| `cluster: local-cluster` | special | `cluster = 'local-cluster'` — direct column |
| `managedHub: hub-1` | special | Client-side only — `matchesManagedHubFilter()` stops query if hub doesn't match |
| keywords | text | `FROM search.resources, jsonb_each_text("data") WHERE "value" ILIKE '%nginx%'` |

### RBAC Pipeline (7 steps)
1. **Extract token** — reads `Authorization: Bearer` header
2. **Validate token** — `TokenReview` API → username + groups + UID. Cached 60s per token.
3. **Check cluster-admin** — `SelfSubjectAccessReview` as user for `verb=* resource=*`. If yes → `IsClusterAdmin=true`, return immediately (no WHERE clause)
4. **Check global hub user** — SSAR for `search.open-cluster-management.io/searches/allManagedData` get → grants access to all managed cluster resources
5. **Build namespace RBAC** — parallel `SelfSubjectRulesReview` for EVERY namespace. Collects `(apigroup, kind)` tuples user can `list`. Also collects managed cluster access (can-i create ManagedClusterView)
6. **Build cluster-scope RBAC** — parallel `SelfSubjectAccessReview` for every cluster-scoped resource
7. **Fine-grained RBAC** (if `FEATURE_FINE_GRAINED_RBAC=true`) — fetches `userpermissions.clusterview.open-cluster-management.io` as user

### RBAC WHERE Clause (pkg/resolver/rbacHelper.go)
```
WHERE (
  hub_branch OR managed_cluster_branch
)
```

**Hub branch:** `data?'_hubClusterResource' AND (cluster-scoped-check OR namespace-scoped-check)`
- Cluster-scoped: `NOT(data?'namespace') AND (apigroup+kind_plural check)`
- Namespace-scoped: `data->'namespace'?ns AND (apigroup+kind_plural check)` — with consolidation optimization (groups namespaces with same resource access into `?|` array)

**Managed cluster branch:** `cluster = ANY(ARRAY['cluster1','cluster2'])` or subquery for `*` access

### Namespace Consolidation Optimization
When a user has the same resource access across multiple namespaces, the query is:
```sql
data->'namespace' ?| ARRAY['ns-a','ns-b','ns-c'] AND (kind AND apigroup check)
```
Instead of one clause per namespace — dramatically reduces query size for users with many namespaces.

### RBAC Cache Architecture
- **Cache singleton** keyed by user UID
- **TokenReview cache:** 60s TTL per token
- **UserDataCache per UID:** separate TTLs for clusters/csr/nsr sub-caches (`UserCacheTTL`, default 10 min)
- **UserPermissions cache:** separate TTL (`UserPermissionCacheTTL`) for fine-grained RBAC
- **Session affinity:** `ClusterIP` so same user always hits same API pod (no shared cache needed)
- **Cache invalidation:** background watcher invalidates on changes to Role, ClusterRole, RoleBinding, ClusterRoleBinding, Groups, Namespaces, CRDs

### Related Resources Query (pkg/resolver/related.go)
Uses a PostgreSQL recursive CTE traversing `search.edges`:
- **Level 1 (default):** direct neighbors only
- **Level 3 (applications):** 3-hop traversal when query includes Application kind
- **Excluded from recursion:** Node and Channel kinds (would pull too many results)
- **Path array:** tracks traversal for deduplication and mapping results back to source UIDs
- **Cluster UID union:** UIDs prefixed with `cluster__` trigger a UNION with direct resource lookup since there are no edges from Cluster to its resources
- RBAC WHERE clause is applied to the final JOIN with `search.resources`

### PostgreSQL LISTEN/NOTIFY (pkg/database/listener.go)
- `listenerTrigger.sql` defines a trigger that fires `NOTIFY` on any `search.resources` row change
- Listener goroutine wakes up, fetches change event, applies RBAC, pushes to WebSocket subscribers
- `StopPostgresListener()` called on graceful shutdown

### Federated Search (pkg/federated/)
Activated when `FEATURE_FEDERATED_SEARCH=true` (set by operator when `global-search-preview=true` annotation on Search CR).
- Separate HTTP endpoint proxies queries to all managed hub search-APIs in parallel
- Hub credentials (token + URL) from `search-global-config` ConfigMaps in OCM namespace
- Responses merged and deduplicated
- Supports `managedHub` filter in query to target specific hubs
- Handles ACM 2.13 backward compat (removes unsupported `$query` param from searchSchema)

### API Environment Variables
| Variable | Description |
|----------|-------------|
| DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME | PostgreSQL connection |
| FEATURE_FEDERATED_SEARCH=true | Enable global/federated search |
| FEATURE_FINE_GRAINED_RBAC=true | Enable fine-grained RBAC (UserPermissions CRD) |
| HUB_NAME | Hub cluster name (from search-global-config ConfigMap) |
| USER_CACHE_TTL_MS | RBAC cache TTL (default 600000 = 10 min) |
| USER_PERMISSION_CACHE_TTL_MS | Fine-grained RBAC cache TTL |
| QUERY_LIMIT | Default query result limit (default 10000) |
| RELATION_LEVEL | Default recursion depth for related resources |

---

## search-v2-operator Deep Dive

### CRD: Search (singleton — must be named `search-v2-operator`)
Key spec fields:
| Field | Type | Notes |
|-------|------|-------|
| spec.dbStorage.storageClassName | string | Creates PVC for persistent PostgreSQL storage |
| spec.dbStorage.size | resource.Quantity | Default 10Gi |
| spec.dbConfig | string | ConfigMap name with custom Postgres params (WORK_MEM etc.) |
| spec.deployments.{database,indexer,collector,queryapi} | DeploymentConfig | Per-component: replicaCount, resources, imageOverride, arguments, envVar |
| spec.imagePullSecret | string | Image pull secret name |
| spec.imagePullPolicy | corev1.PullPolicy | Default IfNotPresent |
| spec.nodeSelector / spec.tolerations | map/[]Toleration | Applied to all search pods |

### Key Annotations on Search CR
| Annotation | Effect |
|------------|--------|
| `search-pause: true` | Pause all reconciliation |
| `global-search-preview=true` | Enable Global/Federated Search (tech preview, ACM 2.11+) |
| `fine-grained-rbac=true` | Enable fine-grained RBAC in search-api (`FEATURE_FINE_GRAINED_RBAC=true` env) |
| `virtual-machine-preview=true` | Enable VM start/stop/snapshot actions in console |
| `search.open-cluster-management.io/max-apps-count` | Override Prometheus PVC alert threshold |
| `search.open-cluster-management.io/max-managed-clusters-count` | Override alert threshold |
| `search.open-cluster-management.io/disable-pvc-critical-alert` | Disable PVC critical Prometheus alert |

### CRD: CollectorConfig (shortname: `sccc`)
| Field | Notes |
|-------|-------|
| spec.collectionRules[].action | `include` or `exclude` |
| spec.collectionRules[].resourceSelector.{apiGroups, kinds} | Which resource types this rule applies to |
| spec.collectionRules[].fields[].{name, jsonPath, type} | Extra fields to index (string/number/bytes/slice/mapString) |
| spec.collectionRules[].fieldSuffix | Suffix to avoid collisions (e.g. `grc`, `virt`) |

A `ValidatingWebhook` enforces CollectorConfig validity before admission.

### Reconciliation Loop (17 steps in order)
1. Start OCM add-on manager once (`sync.Once`) — governs collector deployment on managed clusters
2. Handle Pod status events — update `Search CR status.conditions` per component
3. Set finalizer / run cleanup on deletion (deletes ClusterRoles, ClusterRoleBindings)
4. Check `search-pause` annotation — exit if paused
5. Configure PVC if `storageClassName` set — requeue every 10s until ready
6. Create/update RBAC: ServiceAccount, ClusterRole, AddonClusterRole, GlobalSearchUserClusterRole, ClusterRoleBinding
7. Create Postgres Secret (random password if not exists), Service, Deployment, ConfigMap
8. Create Indexer Service, Deployment, ConfigMap
9. Create API Service, Deployment
10. Create Collector Service, Deployment
11. Create ServiceMonitors for api, indexer, collector (in OCM ns since ACM 2.9)
12. Reconcile Global Search (enable/disable based on `global-search-preview` annotation)
13. Inject `HUB_NAME` env into search-api from `search-global-config` ConfigMap
14. Reconcile Fine-Grained RBAC (set/clear `FEATURE_FINE_GRAINED_RBAC` env)
15. Reconcile Virtual Machine Actions (create ManagedServiceAccounts + ClusterPermissions per managed cluster)
16. Create/update Prometheus PVC alert PrometheusRule
17. One-time migration (once per process): remove legacy ServiceMonitors from `openshift-monitoring`; remove Search ownerRef from ClusterManagementAddon (ACM 2.8→2.9 migration)

### Default Resource Limits
| Component | CPU Request | Memory Request | Memory Limit | Replicas | Scalable? |
|-----------|-------------|----------------|--------------|----------|-----------|
| search-api | 10m | 512Mi | — | 1 | Yes |
| search-indexer | 10m | 32Mi | — | 1 | Yes |
| search-collector | 25m | 128Mi | — | 1 | No |
| search-postgres | 25m | 1Gi | 4Gi | 1 | No |

Postgres tuning defaults: `shared_buffers=1GB, effective_cache_size=2GB, work_mem=64MB`. Override via `spec.dbConfig` ConfigMap or `spec.deployments.database.envVar`.

### Global Search Setup
When `global-search-preview=true` annotation is present on Search CR:
1. Set `globalSearchFeatureFlag=enabled` in `console-mce-config` (MCE ns) and `console-config` (OCM ns)
2. Set `FEATURE_FEDERATED_SEARCH=true` env on search-api deployment (via Search CR spec update)
3. For each managed hub cluster: create `ManagedServiceAccount search-global` in cluster namespace
4. For each managed hub cluster: create `ManifestWork search-global-config` delivering a `ClusterRoleBinding` and `search-global-config` ConfigMap to the managed hub

Prerequisites: MulticlusterGlobalHub operator installed; MCE add-ons `managedserviceaccount` and `cluster-proxy-addon` both enabled.

### OCM Add-on Framework
The operator uses `open-cluster-management.io/addon-framework` to deploy search-collector on managed clusters.
- Add-on name: `search-collector`
- Deployment: Helm chart embedded at compile time (`go:embed addon/manifests/chart`)
- Image: `COLLECTOR_IMAGE` env var; overridable via `spec.deployments.collector.imageOverride`
- CSR approval: add-on framework auto-approves CertificateSigningRequests for mTLS between collector and indexer
- Tuning via ManagedClusterAddon annotations: `search_memory_limit`, `search_memory_request`, `search_args`, `search_rediscover_rate`, `search_heartbeat`, `search_report_rate`

---

## search-e2e-test

**Stack:** Node.js. Two test suites:

### API Tests (Jest) — tests/api/
Tests directly query the GraphQL API:
| File | What It Tests |
|------|--------------|
| search.test.js | Basic queries: kind, name, namespace, label filters |
| rbac.test.js | RBAC enforcement — users only see authorized resources |
| access.test.js | Access control across users/groups |
| filter.test.js | Filter operators: =, !, !=, >, wildcards |
| pagination.test.js | limit + offset |
| queries.test.js | Related resources (edge traversal) |
| data-validation.test.js | Properties match actual k8s resources |
| managed.test.js | Resources from managed clusters appear |
| globalsearch.test.js | Federated/global search |
| subscription*.test.js | WebSocket subscription watch events |
| common.test.js | searchSchema and searchComplete |

### UI Tests (Cypress) — tests/cypress/
Browser tests against ACM console. Spec files: search, overview, saved-searches, suggested-searches, resourceDetailsPage.

### Running Tests
```bash
npm run test:api         # Jest API tests only
npm run test             # Cypress UI tests
npm run test:headed      # Cypress with browser visible
SKIP_API_TEST=true npm run test   # UI only
SKIP_UI_TEST=true npm run test    # API only
```

Required env vars: `OPTIONS_HUB_BASEDOMAIN`, `OPTIONS_HUB_USER`, `OPTIONS_HUB_PASSWORD`

RBAC test fixtures: `tests/config/rbac_yaml/` — apply with `build/rbac-setup.sh`, clean with `build/rbac-clean.sh`.

---

## search-mcp-server

Experimental MCP server exposing ACM search data to AI assistants. Two implementations: TypeScript (`src/`) and Go (`golang/`). Both connect **directly to PostgreSQL** (no GraphQL layer).

### The One Tool: `find_resources`
| Parameter | Description |
|-----------|-------------|
| kind | Resource kind or comma-separated: "Pod" or "Pod,ConfigMap" |
| name | Exact match or shell glob (*, ?) |
| namespace | Comma-separated or wildcard: "open-cluster-management*", "kube-*,default" |
| cluster | Cluster name or comma-separated |
| labelSelector | Kubernetes label selector: "app=nginx,env!=test" |
| clusterSelector | Filter by cluster labels: "env=prod,cloud=AWS" |
| status | Status filter: "Running,Failed" |
| textSearch | Full-text search across all JSON fields |
| ageNewerThan / ageOlderThan | Time filters: "1h", "2d", "1w" |
| outputMode | list (default), count, summary, health |
| groupBy | Group by: status, namespace, cluster, kind, label:key |
| limit | 1–1000, default 50 |
| sortBy / sortOrder | name/created/namespace/cluster, asc/desc |

### Authorization
Requires ACM admin (stricter than regular search). Access granted if user:
1. Is in `system:masters` or `system:cluster-admins`
2. Is in a group with `cluster-admin` ClusterRoleBinding
3. Can create ManagedClusters (`open-cluster-management:cluster-manager-admin` role)

Auth flow: TokenReview → SelfSubjectAccessReview for `* *` → SelfSubjectAccessReview for ManagedCluster create → grant if either passes.

### Deployment
```bash
./scripts/create-secret.sh   # auto-discovers ACM namespace, creates DB secret
make deploy-prebuilt          # uses quay.io/stolostron/search-mcp-server:dev-preview

# Connect to Claude
export TOKEN=$(oc whoami -t)
export ROUTE_URL=$(oc get route acm-search-mcp-server-route -n acm-search -o jsonpath='{.spec.host}')
claude mcp add --transport http --scope project acm-search \
  https://$ROUTE_URL/mcp --header "Authorization: Bearer $TOKEN"
```

---

## Common Bug Patterns

### Bug: Resource missing from search results
1. Check collector logs for transform panic: `oc logs -n open-cluster-management-agent-addon -l component=search-collector`
2. Check reconciler skip conditions in `reconciler.go:reconcileNode()` — is an update being silently dropped?
3. Check RBAC WHERE clause — is the resource filtered by `buildRbacWhereClause()`?
4. Check indexer AddErrors in SyncResponse — `oc logs -n open-cluster-management -l name=search-indexer`
5. Query postgres directly: `SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='<name>' AND data->>'kind'='<kind>';`

### Bug: Search returns wrong resources (too many)
- Check `userHasAllAccess()` in `userData.go` — is SSAR for `* *` returning true unexpectedly?
- Check `buildRbacWhereClause()` in `rbacHelper.go` — is the WHERE clause being skipped?
- Log UserData content with `-v=5`

### Bug: Related resources empty or wrong
- Query `search.edges` table directly: `SELECT * FROM search.edges WHERE sourceid='<uid>' OR destid='<uid>';`
- Check `reconciler.go:allEdges()` — are edge funcs being stored for this resource?
- Check `related.go:setDepth()` — is level 1 or 3?
- Verify ownedBy edges are created by the transformer for this resource kind

### Bug: Filter with wildcard not working
- Check `searchHelper.go:getPartialMatchFilter()` — `*` should be replaced with `%`
- Check property type detection — `getPropertyType()` must identify it correctly (string/object/array)
- Enable verbose logging to see generated SQL: `-v=5` on search-api

### Bug: Collector sending resync every cycle
- Sender resets `lastSentTime=-1` when diff fails → next cycle always sends complete payload
- Check indexer health and SSL cert validity
- Check AGGREGATOR_URL env var

### Bug: RBAC cache stale after permission change
- Check `UserCacheTTL` config (default 10 min)
- Check if RBAC watch events are being received in `watchCache.go`

### Bug: Indexer returning 429
- `requestLimiter` or `largeRequestLimiter` threshold exceeded
- Check how many collectors are connecting simultaneously
- Check for runaway resync loops in collector logs

### Bug: Global search not returning results from managed hub
- Check `search-global-config` ConfigMaps in OCM namespace — one per managed hub
- Check `ManagedServiceAccount search-global` exists in managed hub namespace
- Check MCE add-ons are enabled: `managedserviceaccount` and `cluster-proxy-addon`
- Check `GlobalSearchReady` status condition: `oc get search search-v2-operator -o jsonpath='{.status.conditions}'`

### Bug: Cluster node shows wrong properties
- `ManagedCluster` and `ManagedClusterInfo` both update the same cluster node via `addAdditionalProperties()`
- `ReadClustersCache()` merges: existing properties take priority, new ones are added
- Check which informer event is arriving last

---

## Adding Features

### Add a new indexed property to a resource
1. Edit `pkg/transforms/{kind}.go` in search-collector — add field extraction in `BuildNode()`
2. If it's a new edge type, add `BuildEdges()` logic
3. For generic CRD resources, add entry in `genericResourceConfig.go` with JSONPath
4. **No code change:** use `CollectorConfig` CRD — `spec.collectionRules[].fields` with JSONPath

### Add a new GraphQL filter operator
1. Update `graph/schema.graphqls` — regenerate with gqlgen
2. Add operator case to `getWhereClauseExpression()` in `searchHelper.go`
3. Update `matchOperatorToProperty()` to detect and route the new operator
4. Add e2e test in `search-e2e-test/tests/api/filter.test.js`

### Add a new operator feature flag
1. Add annotation key constant in `controllers/common.go`
2. Create `controllers/my_feature_setup.go` with reconcile logic
3. Call from `controllers/search_controller.go Reconcile()`
4. Update Search CR status conditions with new condition type
5. Document annotation in `README.md`

### Add a new MCP tool (Go)
1. Add `ToolDefinition` in `golang/internal/server/tools.go`
2. Add handler function using `mcp.CallToolRequest`
3. Add SQL query in `golang/pkg/database/queries.go`

---

## Debug Commands Reference

```bash
# Pod status
oc get pods -n open-cluster-management | grep search
oc get pods -n open-cluster-management-agent-addon | grep search

# Search CR status and annotations
oc get search search-v2-operator -n open-cluster-management -o yaml
oc get search search-v2-operator -o jsonpath='{.metadata.annotations}'
oc get search search-v2-operator -o jsonpath='{.status.conditions}' | jq

# Verbose logs
oc logs -n open-cluster-management-agent-addon -l component=search-collector -- --v=5
oc logs -n open-cluster-management -l name=search-indexer -- --v=5
oc logs -n open-cluster-management -l name=search-api -- --v=5

# Debug postgres (from search-v2-operator repo)
bash tools/postgres-debug.sh
bash tools/postgres-query-inventory.sh

# Direct postgres queries (via oc exec or port-forward)
SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='<name>' AND data->>'kind'='<kind>';
SELECT * FROM search.edges WHERE sourceid='<uid>' OR destid='<uid>';
SELECT count(*), cluster FROM search.resources GROUP BY cluster;

# GraphQL queries
# Count all resources: {"query":"{ search(input:[{filters:[{property:\"kind\",values:[\"*\"]}],limit:1}]){count} }"}
# Get all indexed fields: {"query":"{ searchSchema }"}

# Global search condition check
oc get search search-v2-operator -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="GlobalSearchReady")'

# Apply postgres config changes (requires restart)
oc delete pod -l name=search-postgres -n open-cluster-management

# Pause reconciliation
oc annotate search search-v2-operator -n open-cluster-management search-pause=true

# Enable global search
oc annotate search search-v2-operator -n open-cluster-management 'global-search-preview=true'

# Enable fine-grained RBAC
oc annotate search search-v2-operator -n open-cluster-management 'fine-grained-rbac=true'

# Test custom image in cluster
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: searchoperatorimagecm
  namespace: open-cluster-management
data:
  manifest.json: |-
    [{"image-remote":"quay.io/stolostron","image-key":"search_v2_operator","image-name":"search-v2-operator","image-digest":"sha256:..."}]
EOF
kubectl annotate mch multiclusterhub --overwrite mch-imageOverridesCM=searchoperatorimagecm
```

---

## Technology Stack

| Technology | Version | Used In |
|------------|---------|---------|
| Go | 1.25 | operator, collector, indexer, api, mcp-server |
| controller-runtime | v0.21 | operator |
| kubebuilder | — | CRD generation, RBAC markers |
| OLM / operator-sdk | — | operator packaging, cluster install |
| OCM addon-framework | v0.12 | operator (collector deployment) |
| OCM API | v0.16 | ManagedCluster, ClusterManagementAddon types |
| Helm v3 (embedded) | v3.18 | operator (collector chart) |
| PostgreSQL | — | central data store |
| pgx/v4 + pgxpool | — | indexer, api, mcp-server (Go DB driver) |
| gqlgen | — | api (GraphQL code generation) |
| goqu v9 | — | api, indexer (SQL query builder) |
| Gorilla mux | — | indexer, api (HTTP routing) |
| cfssl v1.6 | — | operator (certificate generation for mTLS) |
| prometheus-operator | v0.64 | ServiceMonitor + PrometheusRule CRDs |
| TypeScript / Node.js | — | mcp-server (TS implementation), e2e-test |
| mark3labs/mcp-go | — | mcp-server (Go MCP implementation) |
| Cypress + Jest | — | e2e-test |
| Locust | — | load testing (indexer + api) |
| Quay.io / stolostron | — | container image registry |

---

## Repository File Map (Key Files)

### search-v2-operator
- `main.go` — entry point, scheme registration
- `api/v1alpha1/search_types.go` — Search CRD spec+status
- `api/v1alpha1/collectorconfig_types.go` — CollectorConfig CRD types
- `api/v1alpha1/collectorconfig_webhook.go` — validating webhook
- `controllers/search_controller.go` — 17-step reconcile loop + watches
- `controllers/common.go` — shared utilities, resource helpers, annotations
- `controllers/defaults.go` — default CPU/memory/replica values
- `controllers/create_*.go` — one file per Kubernetes resource type created
- `controllers/global_search_setup.go` — global search enable/disable
- `controllers/fine_grained_rbac.go` — fine-grained RBAC feature flag
- `controllers/virtual_machines_setup.go` — VM actions feature flag
- `controllers/cleanup.go` — finalizer cleanup + ACM 2.8→2.9 migration
- `addon/addon.go` — OCM add-on manager, Helm agent, CSR approval
- `addon/manifests/chart/` — Helm chart for managed-cluster collector
- `docs/RBAC.md` — RBAC design doc
- `tools/` — postgres-debug.sh, postgres-query-inventory.sh, resource-extractor.sh

### search-collector
- `main.go` — pipeline wiring
- `pkg/informer/runInformers.go` — dynamic informers, CRD watch, GVR discovery
- `pkg/informer/informer.go` — custom informer with namespace filter
- `pkg/informer/supportedResources.go` — SupportedResources() discovery
- `pkg/transforms/transformer.go` — type dispatch, panic recovery
- `pkg/transforms/common.go` — commonProperties, CommonEdges, NodeStore, edge helpers
- `pkg/transforms/configurableCollection.go` — CollectorConfig rules
- `pkg/transforms/{kind}.go` — typed builders (Pod, Deployment, Policy, VM, etc.)
- `pkg/reconciler/reconciler.go` — in-memory state, Diff(), Complete()
- `pkg/send/sender.go` — send loop, complete/diff payload, backoff
- `pkg/send/httpsClient.go` — mTLS HTTP client
- `pkg/lease/lease.go` — ManagedClusterAddon lease reconciler

### search-indexer
- `main.go` — DB init → clustersync → HTTP server
- `pkg/server/server.go` — HTTP router, mTLS
- `pkg/server/syncHandler.go` — dispatch resync vs sync
- `pkg/server/requestLimiter.go` — per-cluster concurrency limit
- `pkg/server/largeRequestLimiter.go` — global resync concurrency limit
- `pkg/database/connection.go` — pgxpool init, InitializeTables (schema, tables, indexes)
- `pkg/database/sync.go` — SyncData diff batch operations
- `pkg/database/resync.go` — ResyncData streaming decode, DELETE NOT IN, hub rename cleanup
- `pkg/database/batch.go` — batchWithRetry auto-flush, binary-search error isolation
- `pkg/database/cache.go` — in-memory cluster cache for ManagedClusterInfo merge
- `pkg/database/upsertCluster.go` — UpsertCluster, DeleteClusterAndResources
- `pkg/clustersync/clusterSync.go` — leader-elected ManagedCluster informers, Cluster node transforms
- `pkg/model/model.go` — Resource, Edge, SyncEvent, SyncResponse types

### search-v2-api
- `graph/schema.graphqls` — full GraphQL schema
- `pkg/resolver/search.go` — SQL query builder: buildSearchQuery, WhereClauseFilter
- `pkg/resolver/searchHelper.go` — operator extraction, filter→SQL, formatDataMap
- `pkg/resolver/rbacHelper.go` — buildRbacWhereClause, matchHubClusterRbac, matchManagedCluster
- `pkg/resolver/rbacFineGrainedHelper.go` — fine-grained RBAC WHERE clause
- `pkg/resolver/related.go` — recursive CTE, setDepth, filterRelatedUIDs
- `pkg/resolver/searchComplete.go` — autocomplete query
- `pkg/resolver/searchSchema.go` — all indexed fields query
- `pkg/resolver/watchSubscription.go` — WebSocket subscription
- `pkg/rbac/userData.go` — UserData build: SSAR/SSRR parallel calls
- `pkg/rbac/cache.go` — cache singleton: tokenReviews + users maps
- `pkg/rbac/watchCache.go` — per-user watch RBAC cache
- `pkg/rbac/sharedData.go` — shared data across users (namespaces, managed clusters, CS resources)
- `pkg/database/listener.go` — PostgreSQL LISTEN/NOTIFY
- `pkg/database/listenerTrigger.sql` — SQL trigger definition
- `pkg/federated/federated.go` — global search fan-out
- `pkg/federated/fedConfig.go` — federation config from ConfigMaps
- `pkg/server/server.go` — HTTP router

---

## Development Checklist & Lessons Learned

### CRD Type Changes (search-v2-operator)

Every time you modify `api/v1alpha1/*.go` and run `make generate; make manifests; make bundle`,
**three CRD files** must be in sync. Two are auto-generated, one is hand-maintained:

| File | How it's updated | Common mistake |
|------|-----------------|----------------|
| `config/crd/bases/search.open-cluster-management.io_collectorconfigs.yaml` | Auto — `make manifests` | ✅ Always updated |
| `bundle/manifests/search.open-cluster-management.io_collectorconfigs.yaml` | Auto — `make bundle` | ✅ Always updated |
| `addon/manifests/chart/templates/collectorconfig_crd.yaml` | **Manual** — hand-maintained Helm chart | ❌ Often forgotten |

**Rule:** After running `make manifests`, always run:
```bash
git diff config/crd/bases/search.open-cluster-management.io_collectorconfigs.yaml
```
Then manually mirror ANY new fields, descriptions, or x-kubernetes markers into
`addon/manifests/chart/templates/collectorconfig_crd.yaml`. The two files must match exactly.

**Why it matters:** The addon chart CRD is deployed to **managed clusters** via the Helm add-on.
If it drifts from the hub CRD, managed clusters get different API semantics (e.g. missing
`x-kubernetes-list-map-keys` means atomic list replacement instead of merge-by-type, which
can cause duplicate condition entries).

### Makefile tooling (search-v2-operator)

The Makefile pins `controller-gen@v0.11.3` but the CRD files in the repo were generated with
`v0.18.0` (visible in the `controller-gen.kubebuilder.io/version` CRD annotation). Running
`make manifests` with the pinned v0.11.3 will crash on Go 1.24+.

**Workaround:** Install v0.18.0 separately and copy it into `bin/` before running make:
```bash
go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.18.0
cp $(go env GOPATH)/bin/controller-gen bin/controller-gen
make generate
make manifests
```
The `go-get-tool` macro only downloads if `bin/controller-gen` doesn't exist, so the pre-installed
binary takes precedence. Do **not** change the Makefile — the rest of the team uses it as-is.

Similarly, `make bundle` requires operator-sdk but `go.kubebuilder.io/v3` (in the PROJECT file)
was dropped in operator-sdk v1.31+. Use `--plugins go.kubebuilder.io/v4` to bypass:
```bash
./bin/kustomize build config/manifests | \
  operator-sdk generate bundle -q --overwrite --version 0.0.1 \
  --plugins go.kubebuilder.io/v4
# Then revert noise: bundle.Dockerfile, annotations.yaml, clusterserviceversion.yaml
git checkout bundle.Dockerfile bundle/metadata/annotations.yaml \
  bundle/manifests/search-v2-operator.clusterserviceversion.yaml
```

### RBAC for new status subresources (search-v2-operator) ⚠️ PRODUCTION LESSON

When adding a new `status` subresource to a CRD, you need `patch`/`update` permissions
in **FIVE places** across **TWO repos**. Missing any one of them causes a real production
incident (MCH stuck in Installing status).

#### Repo 1: stolostron/search-v2-operator

1. **`controllers/create_rolesbindings.go`** `getRules()` — hub `search` ClusterRole (runtime Go code)
2. **`controllers/search_controller.go`** `//+kubebuilder:rbac` marker — generates `config/rbac/role.yaml`
3. **`addon/manifests/chart/templates/cluster_role.yaml`** — managed cluster collector ClusterRole (Helm)
4. **`bundle/manifests/search-v2-operator.clusterserviceversion.yaml`** `clusterPermissions` — OLM CSV; MCH automation builds off this file and will strip permissions not listed here

#### Repo 2: stolostron/multiclusterhub-operator ⚠️ MOST COMMONLY FORGOTTEN

5. **`pkg/templates/charts/toggle/search-v2-operator/templates/search-v2-operator-clusterrole.yaml`** — MCH Helm template that controls what permissions the search-v2-operator's OWN service account has
6. **`pkg/templates/rbac_gen.go`** — kubebuilder marker in MCH that generates the above

#### Why the MCH repo matters (Kubernetes privilege escalation protection)

Kubernetes RBAC enforces: **you cannot grant permissions you don't already have.**

In a real ACM install, MCH creates and manages the search-v2-operator service account's
ClusterRole. If MCH's ClusterRole for search-v2-operator doesn't include
`collectorconfigs/status`, then the search-v2-operator can't add that permission to the
`search` ClusterRole it manages — even though that's exactly what our Go code tries to do.

The error you'll see:
```
ClusterRole setup failed: clusterroles.rbac.authorization.k8s.io "search" is forbidden:
user "system:serviceaccount:open-cluster-management:search-v2-operator" is attempting to
grant RBAC permissions not currently held:
{APIGroups:["search.open-cluster-management.io"], Resources:["collectorconfigs/status"],
Verbs:["patch" "update"]}
```
This causes the search-v2-operator reconcile loop to fail → MCH stuck in `Installing` status.

#### What to add in multiclusterhub-operator

In `search-v2-operator-clusterrole.yaml` AND `rbac_gen.go`, add the `collectorconfigs/status`
rule. Note: you only need `collectorconfigs/status` with `patch`/`update` — the base
`collectorconfigs` get/list/watch is already covered by the wildcard rule at the top of the file.

**Real incident:** ACM build `5.0.0-73` was blocked in Installing status because PR #726
(search-v2-operator) added the RBAC to places 1-3 but missed places 4-5. Fixed in
multiclusterhub-operator PR #4192.

### Warning truncation in status conditions (search-collector)

The `updateCollectorConfigStatus` function truncates warnings at `maxStatusWarnings = 3`.
If you increase the limit or change the truncation format, update:
1. `configurableCollection.go` — the `maxStatusWarnings` constant and the truncation logic
2. `genericResourceConfig_test.go` — `TestStatusCondition_WarningTruncation` subtests

The truncation test uses **6 genuinely distinct rule types** (not the same rule with different
targets) so that presence/absence of each warning in the message can be independently asserted.
If you add a new warning path, add a new entry to `distinctWarningRules` in the test.

### Kubebuilder list markers on Conditions fields

Always add `+listType=map` and `+listMapKey=type` to any `[]metav1.Condition` field:
```go
// +listType=map
// +listMapKey=type
Conditions []metav1.Condition `json:"conditions,omitempty"`
```
Without these, the API server uses atomic list semantics (full replacement on update),
which can cause duplicate condition types. These markers are enforced in:
- `config/crd/bases/` (via `make manifests`)
- `bundle/manifests/` (via `make bundle`)
- `addon/manifests/chart/templates/collectorconfig_crd.yaml` (**manual** — easy to forget)

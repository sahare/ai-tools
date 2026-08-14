# search-v2-operator — Technical Reference

**Repo:** https://github.com/stolostron/search-v2-operator
**Language:** Go (kubebuilder/controller-runtime) | **Entry:** `main.go`
**Runs on:** Hub cluster only

## Commands

```bash
make build       # Build binary to bin/manager
make run         # Run locally (needs WATCH_NAMESPACE + image env vars — use `make setup`)
make test        # Unit tests (downloads envtest assets on first run — slow)
make lint        # golangci-lint + gosec
make manifests   # Regenerate CRD/RBAC manifests (after editing api/v1alpha1/)
make generate    # Regenerate DeepCopy methods (after editing api/v1alpha1/)
make install     # Install CRDs into cluster
make deploy      # Deploy controller to cluster
make docker-build # Build image (runs tests first)
```

After any change to `api/v1alpha1/` types, run BOTH `make manifests` AND `make generate`.

## Local Run Setup

`make setup` prints ready-to-run `export` statements:

```bash
export WATCH_NAMESPACE=open-cluster-management
export POSTGRES_IMAGE=<from cluster>
export COLLECTOR_IMAGE=<from cluster>
export API_IMAGE=<from cluster>
export INDEXER_IMAGE=<from cluster>
```

Uses `$(shell kubectl ...)` substitution against current kubeconfig.

## Package Map

| Directory | Purpose |
|-----------|---------|
| `api/v1alpha1/` | CRD types (Search, CollectorConfig), webhook, deepcopy |
| `controllers/` | Reconciler, all `create_*.go` resource builders, seeder |
| `addon/` | OCM add-on manager, embedded Helm chart for collector |
| `config/integration_collector_configs/` | Embedded integration config YAMLs (`go:embed`) |
| `config/integrationconfigs.go` | `go:embed` directive |
| `docs/` | ARCHITECTURE.md, RBAC.md |
| `tools/` | postgres-debug.sh, resource-extractor.sh |

## CRDs

### Search (singleton — name must be `search-v2-operator`)

| Spec field | Purpose |
|------------|---------|
| `dbStorage.storageClassName` | Creates PVC for Postgres |
| `dbStorage.size` | Default 10Gi |
| `deployments.{database,indexer,collector,queryapi}` | Per-component: replicas, resources, imageOverride, envVar |
| `imagePullSecret` / `imagePullPolicy` | Image pull config |
| `nodeSelector` / `tolerations` | Applied to all search pods |

### Key Annotations on Search CR

| Annotation | Effect |
|------------|--------|
| `search-pause: true` | Halt all reconciliation |
| `global-search-preview=true` | Enable Federated Search |
| `fine-grained-rbac=true` | Enable fine-grained RBAC |
| `virtual-machine-preview=true` | Enable VM actions |

### CollectorConfig (shortname: `sccc`)

| Spec field | Purpose |
|------------|---------|
| `collectionRules[].action` | `include` or `exclude` |
| `collectionRules[].resourceSelector.{apiGroups, kinds}` | Target resources |
| `collectionRules[].fields[].{name, jsonPath, type}` | Extra fields to index |
| `collectionRules[].fieldSuffix` | Collision avoidance suffix |
| `collectionRules[].collectConditions` | Index .status.conditions |
| `collectionRules[].collectAnnotations` | Index all annotations |

Three configs on hub: `user-collector-config` (user-editable), integration-labeled (per team), `merged-collector-config` (operator-computed).

## Reconciliation Loop (exact order)

| # | Step | Failure behavior |
|---|------|------------------|
| 0 | Get Search CR | NotFound → nil; else return err |
| 1 | `once.Do` → addon start | Fire-and-forget goroutine |
| 2 | Pod status event → status-only update | Return (skips rest) |
| 3 | Set finalizer / cleanup on delete | Blocks rest |
| 4 | Check `search-pause` | Return nil immediately |
| 5 | PVC (if storageClass set) | Requeue 10s until ready |
| 6-10 | RBAC (SA, ClusterRoles, CRB) | Blocks on failure |
| 11 | `ensureWebhookCAInjection` | **Non-blocking** (log only) |
| 12 | `createOrUpdateMergedCollectorConfig` | Blocks |
| 13-16 | PG secret, API RO secret, MCP RO secret, PG service | Blocks |
| 17 | PG deployment | Blocks |
| 18-20 | Indexer/API/Collector services | Collector service non-blocking (bug/quirk) |
| 21-23 | ServiceMonitors | Blocks |
| 24-26 | Collector/Indexer/API deployments | Blocks |
| 27-29 | ConfigMaps (indexer, PG, CA cert) | Blocks |
| 30-34 | Features (global search, HUB_NAME, fine-grained RBAC, VM, Prometheus rule) | Blocks |
| 35 | One-time migrations (`cleanOnce.Do`) | Log only |

## Integration CollectorConfig Seeder (ACM-37052)

**NOT part of Reconcile** — runs as a separate `manager.Runnable` at startup.

### Startup Flow
1. `mgr.Add(&IntegrationCollectorConfigSeeder{...})` in `main.go`
2. `Start(ctx)` → `wait.PollUntilContextCancel` with 10s interval
3. Each attempt: `resolveSearch` → check pause → `applyIntegrationCollectorConfigs`
4. On success → return (poll ends); on error → log, keep retrying
5. Leader-elected (`NeedLeaderElection() = true`)

### Webhook CA Bundle Race
- Fresh install: webhook exists with `failurePolicy=fail` before CA is injected
- Seeder retries every 10s until apply succeeds
- Reconcile independently patches VWC with `inject-cabundle: true` (non-blocking)

### Owner Reference and GC
- `controllerutil.SetControllerReference(searchCR, cc, scheme)`
- Search CR deleted → Kubernetes GC cascades to integration configs
- GC SA (`generic-garbage-collector`) allowed to DELETE operator-owned configs

### `manual-override` Escape Hatch
Annotation: `search.open-cluster-management.io/manual-override`
- Present → seeder skips overwrite entirely (edits survive restarts)
- Remove annotation → next restart resets to shipped defaults
- Alternative: create differently-named CR with integration label (never touched by seeder)

### Apply Semantics
1. Unmarshal embedded YAML; force integration label
2. **Create** if NotFound (+ labels + ownerRef)
3. **Update** if exists and not manual-override:
   - Skip if Spec equal + all labels present + ownerRef present
   - Else overwrite Spec, merge labels, ensure ownerRef

### Shipped Configs (7 files)
`cnv-integration`, `olm-integration`, `grc-integration`, `kyverno-integration`, `gatekeeper-integration`, `argo-integration`, `app-lifecycle-integration`

## CollectorConfig Merge Logic

`createOrUpdateMergedCollectorConfig` (runs every reconcile):

1. List integration-labeled configs; sort by name (deterministic)
2. Append all team rules into merged spec
3. Get `user-collector-config`
4. For each user rule:
   - If exclude overlaps any team include → **drop**; record message for status
   - Else append
5. Create/update `merged-collector-config` (only if Spec changed)
6. Update user config status: `Applied=True` or `Applied=False / RulesSkipped`

### Rule Precedence
- Integration configs: sorted by name, all rules concatenated
- User excludes overlapping team includes: **dropped** (integration wins)
- User includes: always appended
- No inter-team collision handling (future work)
- `merged-collector-config` never gets backup label

## Webhook Validation

Path: `/validate-search-open-cluster-management-io-v1alpha1-collectorconfig`
`failurePolicy: fail`

### Protected API Groups (static — 6 groups)
`""` (core), `config.openshift.io`, `template.openshift.io`, `admissionregistration.k8s.io`, `operator.open-cluster-management.io`, `search.open-cluster-management.io`

### Protected Kinds (RBAC engine dependencies)
`ManagedCluster` (`cluster.open-cluster-management.io`), `Namespace` (core)

### Dynamic Validation
- Lists integration-labeled CRs in same namespace
- Rejects user excludes that overlap any team include
- List failure → allow (fail-open at admission; merge layer is backup)

### Ownership Protection
- CR with controller ownerRef → operator-managed
- Only SAs in resource's namespace + GC SA can modify
- Checks both old and new objects on UPDATE

### Spec Validation
- Exclude cannot set: fields, collectConditions, collectAnnotations, fieldSuffix
- Include + `kinds:["*"]` + fields → invalid
- Include with fields: exactly one kind + one apiGroup required
- `kinds:["*"]` on protected apiGroup → rejected (wildcard bypass fix)

## OCM Add-on Framework

- Add-on name: `search-collector`
- Helm chart embedded: `//go:embed addon/manifests/chart`
- Started once per process (first reconcile, `sync.Once`)
- Image: `COLLECTOR_IMAGE` env; overridable via `spec.deployments.collector.imageOverride`
- CSR auto-approval for mTLS

### Addon Annotations (on ManagedClusterAddOn)
| Annotation | Effect |
|------------|--------|
| `search_memory_limit` | Container memory limit |
| `search_memory_request` | Memory request |
| `search_args` | Container args |
| `search_rediscover_rate` | `REDISCOVER_RATE_MS` |
| `search_heartbeat` | `HEARTBEAT_MS` |
| `search_report_rate` | `REPORT_RATE_MS` |

## Status Conditions

### Search CR
| Type | When set |
|------|----------|
| `Ready--search-api` | Pod Ready condition |
| `Ready--search-collector` | Pod Ready condition |
| `Ready--search-indexer` | Pod Ready condition |
| `Ready--search-postgres` | Pod Ready condition |
| `GlobalSearchReady` | Global search enable/disable |
| `FineGrainedRBACReady` | Fine-grained RBAC annotation |
| `VirtualMachineActionsReady` | VM annotation |

### CollectorConfig (`user-collector-config`)
| Type | Status | Reason | When |
|------|--------|--------|------|
| `Applied` | True | `Applied` | All rules merged successfully |
| `Applied` | False | `RulesSkipped` | Excludes dropped vs integration |

## Critical Rules (production incidents from skipping)

1. **CRD changes → manually mirror to `addon/manifests/chart/templates/collectorconfig_crd.yaml`**
2. **New status subresource → RBAC in 5 places across 2 repos** (see incidents.md)
3. **`[]metav1.Condition` fields → always add `+listType=map` / `+listMapKey=type`**
4. **`merged-collector-config` must NOT have the backup label**
5. **Seeder is startup-only** — not every reconcile; use manual-override for durable customizations

## Agent Playbooks

### Add a feature flag (annotation-based)
1. Add annotation constant in `controllers/common.go`
2. Create `controllers/{feature}_setup.go` with reconcile logic
3. Call from `Reconcile()` at correct step
4. Update status conditions
5. Document in README.md

### Change CRD types
1. Edit `api/v1alpha1/{type}_types.go`
2. `make generate` (DeepCopy)
3. `make manifests` (CRD + RBAC YAML)
4. **Manual mirror** to `addon/manifests/chart/templates/collectorconfig_crd.yaml`
5. Update webhook if needed

### Add a new integration CollectorConfig
1. Create `config/integration_collector_configs/{team}.yaml` with include rules + integration label + backup label
2. No code change needed — `go:embed` picks up new files automatically
3. Remove team's apiGroups from `protectedAPIGroups` in webhook if they were there
4. Update tests

### Debug seeder not applying configs
1. Check if Search CR exists: `oc get search search-v2-operator`
2. Check if `search-pause: true`: seeder defers while paused
3. Check webhook CA: seeder retries on admission failure every 10s
4. Check operator logs: `oc logs -l control-plane=controller-manager -n open-cluster-management`
5. Check if `manual-override` annotation is on the target config

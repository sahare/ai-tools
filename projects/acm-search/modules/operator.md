# search-v2-operator — Technical Reference

**Repo:** https://github.com/stolostron/search-v2-operator
**Language:** Go (kubebuilder/controller-runtime) | **Entry:** `main.go`
**Runs on:** Hub cluster only

## Commands

```bash
make build       # Build binary to bin/manager
make run         # Run locally (needs WATCH_NAMESPACE, image env vars — use `make setup`)
make test        # Unit tests (downloads envtest assets on first run — slow)
make lint        # golangci-lint + gosec
make manifests   # Regenerate CRD/RBAC manifests (after editing api/v1alpha1/)
make generate    # Regenerate DeepCopy methods (after editing api/v1alpha1/)
make install     # Install CRDs into cluster
make deploy      # Deploy controller to cluster
make docker-build # Build image (runs tests first)
```

After any change to `api/v1alpha1/` types, run BOTH `make manifests` AND `make generate`.

## Package Map

| Directory | Purpose |
|-----------|---------|
| `api/v1alpha1/` | CRD types (Search, CollectorConfig), webhook, deepcopy |
| `controllers/` | Reconciler, all create_*.go resource builders, seeder |
| `addon/` | OCM add-on manager, embedded Helm chart for collector |
| `config/` | Embedded integration CollectorConfig YAMLs (`go:embed`) |
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

### Key annotations on Search CR

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

Three configs on the hub: `user-collector-config` (user-editable), integration-labeled configs (per team), `merged-collector-config` (operator-computed, read by collector).

## Reconciliation Loop (steps in order)

1. Start OCM add-on manager (once)
2. Handle Pod status events → update Search CR status
3. Set finalizer / run cleanup on deletion
4. **Check `search-pause`** — exit if paused
5. PVC (if storageClassName set)
6. RBAC: ServiceAccount, ClusterRoles, ClusterRoleBindings
7. **CollectorConfig merge** (user + integration → merged)
8. PostgreSQL: Secret, Service, Deployment, ConfigMap
9. Component Services (Indexer, API, Collector)
10. ServiceMonitors
11. Component Deployments
12. ConfigMaps
13. Feature configs (Global Search, Fine-Grained RBAC, VM)
14. Prometheus alert rules
15. One-time migrations

## Integration CollectorConfig Seeder

- Runs **once per operator process at startup** (not on every reconcile)
- `IntegrationCollectorConfigSeeder` (a `manager.Runnable`)
- Creates/overwrites 7 embedded configs (CNV, OLM, GRC, Kyverno, Gatekeeper, Argo, App-Lifecycle)
- Retries until success (handles webhook CA bundle startup race)
- Honors `search-pause` annotation
- Sets ownerReference to Search CR (GC on deletion)
- Respects `search.open-cluster-management.io/manual-override` annotation (skips overwrite)
- Logs and continues if one config fails (doesn't block others)

## Webhook (CollectorConfig validation)

- Validates exclude rules against `protectedAPIGroups` (static list of 6 critical groups)
- Dynamically validates excludes against integration configs (can't exclude what an integration includes)
- Rejects `collectConditions`/`collectAnnotations` on exclude rules
- Blocks non-operator users from deleting/modifying operator-owned configs

## OCM Add-on Framework

- Add-on name: `search-collector`
- Deployment: Helm chart embedded at compile time (`addon/manifests/chart/`)
- CSR auto-approval for mTLS between collector and indexer
- Tuning via ManagedClusterAddon annotations

## Critical Rules

1. **CRD changes → mirror to `addon/manifests/chart/templates/collectorconfig_crd.yaml`** (hand-maintained, not auto-generated)
2. **New status subresource → RBAC in 5 places across 2 repos** (see SKILL.md rule #1)
3. **`[]metav1.Condition` fields need `+listType=map` / `+listMapKey=type` markers**
4. **`merged-collector-config` must NOT have the backup label**

## How to: add a new operator feature flag

1. Add annotation key constant in `controllers/common.go`
2. Create `controllers/my_feature_setup.go` with reconcile logic
3. Call from `controllers/search_controller.go Reconcile()`
4. Update Search CR status conditions
5. Document annotation in README.md

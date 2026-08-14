# ACM Search — Bug Patterns, Debug Commands & Lessons Learned

## Common Bug Patterns

### Resource missing from search results
1. Collector transform panic: `oc logs -n open-cluster-management-agent-addon -l component=search-collector`
2. Reconciler skip conditions in `reconciler.go:reconcileNode()` — update silently dropped?
3. RBAC WHERE clause filtering it: `buildRbacWhereClause()` in search-api
4. Indexer AddErrors in SyncResponse: `oc logs -n open-cluster-management -l name=search-indexer`
5. Query postgres directly: `SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='<name>' AND data->>'kind'='<kind>';`

### Search returns wrong resources (too many)
- `userHasAllAccess()` in `userData.go` — SSAR for `* *` true unexpectedly?
- `buildRbacWhereClause()` being skipped?
- Log UserData with `-v=5`

### Related resources empty or wrong
- Query edges: `SELECT * FROM search.edges WHERE sourceid='<uid>' OR destid='<uid>';`
- Check `allEdges()` — are edge funcs stored for this kind?
- Check `related.go:setDepth()` — level 1 or 3?
- Verify ownedBy edges are created by the transformer

### Filter with wildcard not working
- `getPartialMatchFilter()` — `*` → `%`
- `getPropertyType()` must identify type correctly
- Verbose SQL logging: `-v=5` on search-api

### Collector sending resync every cycle
- Sender resets `lastSentTime=-1` on diff failure
- Check indexer health and SSL cert
- Check `AGGREGATOR_URL` env var

### RBAC cache stale after permission change
- `UserCacheTTL` (default 10 min)
- Check `watchCache.go` events

### Indexer returning 429
- `requestLimiter`/`largeRequestLimiter` threshold
- Too many concurrent collectors or resync loop

### Global search not returning managed-hub results
- `search-global-config` ConfigMaps in OCM namespace (one per managed hub)
- `ManagedServiceAccount search-global` in managed hub namespace
- MCE add-ons: `managedserviceaccount` + `cluster-proxy-addon`
- `GlobalSearchReady` condition: `oc get search search-v2-operator -o jsonpath='{.status.conditions}'`

### Cluster node shows wrong properties
- `ManagedCluster` + `ManagedClusterInfo` both update via `addAdditionalProperties()`
- `ReadClustersCache()` merge: existing properties take priority
- Check which informer event arrives last

## Debug Commands

```bash
# Pod status
oc get pods -n open-cluster-management | grep search
oc get pods -n open-cluster-management-agent-addon | grep search

# Search CR status
oc get search search-v2-operator -n open-cluster-management -o yaml
oc get search search-v2-operator -o jsonpath='{.status.conditions}' | jq

# Verbose logs
oc logs -n open-cluster-management-agent-addon -l component=search-collector -- --v=5
oc logs -n open-cluster-management -l name=search-indexer -- --v=5
oc logs -n open-cluster-management -l name=search-api -- --v=5

# Postgres debug scripts (from operator repo tools/)
bash tools/postgres-debug.sh
bash tools/postgres-query-inventory.sh

# Direct postgres queries
SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='<name>' AND data->>'kind'='<kind>';
SELECT * FROM search.edges WHERE sourceid='<uid>' OR destid='<uid>';
SELECT count(*), cluster FROM search.resources GROUP BY cluster;

# Count all resources
curl -sk https://localhost:4010/searchapi/graphql -H "Authorization: Bearer $(oc whoami -t)" \
  -d '{"query":"{ search(input:[{filters:[{property:\"kind\",values:[\"*\"]}],limit:1}]){count} }"}'

# Pause reconciliation
oc annotate search search-v2-operator -n open-cluster-management search-pause=true

# Enable features
oc annotate search search-v2-operator -n open-cluster-management 'global-search-preview=true'
oc annotate search search-v2-operator -n open-cluster-management 'fine-grained-rbac=true'

# Custom image override
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

## Development Lessons Learned

### CRD Type Changes (operator)

After `make manifests`, three CRD files must be in sync:

| File | Updated by | Common mistake |
|------|-----------|----------------|
| `config/crd/bases/*.yaml` | `make manifests` (auto) | ✅ Always correct |
| `bundle/manifests/*.yaml` | `make bundle` (auto) | ✅ Always correct |
| `addon/manifests/chart/templates/collectorconfig_crd.yaml` | **Manual** | ❌ Often forgotten |

Always diff the auto-generated CRD and mirror changes to the chart template.

### RBAC for new status subresources ⚠️ PRODUCTION LESSON

Adding a new CRD status subresource needs RBAC in **5 places across 2 repos**:
1. `controllers/create_rolesbindings.go` — ClusterRole rules
2. `//+kubebuilder:rbac` marker on the controller
3. `addon/manifests/chart/` Helm ClusterRole (managed clusters)
4. `ClusterServiceVersion` clusterPermissions (CSV)
5. `multiclusterhub-operator` — MCH Helm template + `rbac_gen.go`

Miss step 5 → MCH stuck in `Installing` (ServiceAccount can't grant what it doesn't have).
Fix in search-v2-operator CSV; let the MCH repo's automated sync PR propagate it.

### Makefile tooling quirk (operator)

The Makefile pins `controller-gen@v0.11.3` but CRD files were generated with `v0.18.0`.
Running `make manifests` with the pinned version may produce diffs. Use whatever version
matches the CRD annotation `controller-gen.kubebuilder.io/version` in the existing files.

### Warning truncation in status conditions (collector)

`configurableCollection.go` caps status warnings at `maxStatusWarnings` (3). Longer messages
get `"... and N more"` suffix. Tests using warning counts must account for this.

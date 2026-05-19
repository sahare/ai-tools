# ACM Search — E2E Testing Guide with Custom Images

How to build, deploy, and test custom search component changes on a real ACM cluster.
Learned during ACM-33146 development (May 2026).

---

## The Standard Workflow (Spencer's Method)

> "You can use the image that the CI job builds and puts in quay.io/stolostron/search-collector,
> or if you're not there yet can build and push the image to your own repo, that's what I typically do.
> You'll need your own dev cluster."
> — Spencer McAvey

### Step 1 — Build and push your custom image

**Critical: always build for linux/amd64.** ACM clusters run on x86_64 nodes.
If you build on an Apple Silicon Mac without this flag, the binary will be arm64
and the pod will crash immediately with `Exec format error`.

```bash
# In the repo you changed (e.g. search-collector)
docker build --platform linux/amd64 -f Dockerfile.local \
  -t quay.io/<your-quay-username>/search-collector:my-branch .

docker push quay.io/<your-quay-username>/search-collector:my-branch
```

> **Dockerfile.local** — use this instead of the standard `Dockerfile` which requires
> access to `registry.ci.openshift.org/stolostron/builder` (internal Red Hat CI registry).
> It uses `golang:1.25` from Docker Hub instead.
>
> ```dockerfile
> FROM golang:1.25 AS builder
> WORKDIR /go/src/github.com/stolostron/search-collector
> COPY . .
> RUN CGO_ENABLED=1 GOGC=25 go build -trimpath -o main main.go
>
> FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
> COPY --from=builder /go/src/github.com/stolostron/search-collector/main /bin/main
> ENV USER_UID=1001 GOGC=25
> USER ${USER_UID}
> ENTRYPOINT ["/bin/main"]
> ```

### Step 2 — Override the image via the Search CR (Spencer's method)

```bash
oc patch search search-v2-operator -n open-cluster-management --type=merge -p '{
  "spec": {
    "deployments": {
      "collector": {
        "imageOverride": "quay.io/<your-quay-username>/search-collector:my-branch",
        "envVar": [{"name": "FEATURE_CONFIGURABLE_COLLECTION", "value": "true"}]
      }
    }
  }
}'
```

> For other components: use `indexer`, `database`, or `queryapi` instead of `collector`.

---

## The Problem: Operator Keeps Reverting Your Changes

The search-v2-operator reconciles the Search CR continuously. Any manual `oc set image`
or `oc patch deployment` gets reverted within seconds. There are two ways to stop this:

### Option A — Use imageOverride on the Search CR (preferred)

Setting `spec.deployments.collector.imageOverride` IS the operator's official override
mechanism. The operator reads it and uses it when computing the deployment.

**Known bug:** The operator constructs fresh Deployment objects without copying
`resourceVersion`, so `r.Update()` fails silently (ResourceVersion required for updates).
This means the imageOverride often doesn't propagate. Workaround: pause the operator (Option B).

### Option B — Pause the search operator (most reliable for testing)

```bash
# Pause the search operator (stops all reconciliation)
oc annotate search search-v2-operator -n open-cluster-management search-pause=true --overwrite

# Pause MCH too (stops MCH from re-enabling the search operator)
oc annotate mch multiclusterhub -n open-cluster-management \
  'installer.open-cluster-management.io/pause'=true --overwrite

# Now safely patch the deployment directly
oc patch deployment search-collector -n open-cluster-management --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"quay.io/<user>/search-collector:my-branch"},
  {"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"quay-pull-secret"}]},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FEATURE_X","value":"true"}}
]'
oc rollout restart deployment/search-collector -n open-cluster-management

# Unpause when done
oc annotate search search-v2-operator -n open-cluster-management search-pause- --overwrite
oc annotate mch multiclusterhub -n open-cluster-management \
  'installer.open-cluster-management.io/pause'- \
  mch-pause- --overwrite
```

> **Note:** `mch-pause` annotation is deprecated. Use `installer.open-cluster-management.io/pause` instead.
> The old annotation still works but logs a deprecation warning.

---

## Pulling Private quay.io Images on the Cluster

ACM cluster nodes can't pull from private quay.io repos without credentials.

### Option A — Make the quay.io repo public

Simplest. Go to quay.io → your repo → Settings → Repository Visibility → Make Public.

### Option B — Create a pull secret and link to service account

```bash
# Create the pull secret
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=<your-quay-username> \
  --docker-password='<your-quay-password>' \
  -n open-cluster-management

# Link to the service account the collector pod runs as
oc patch serviceaccount search-serviceaccount -n open-cluster-management \
  --type=json \
  -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-pull-secret"}}]'
```

> **Warning:** The search-v2-operator reconciles the ServiceAccount and reverts
> `imagePullSecrets` on each reconcile cycle. If you see pods failing to pull after
> a while, re-check the SA. Workaround: also add `imagePullSecrets` directly to
> the deployment pod template spec (Option B below), or pause the operator first.

### Option C — Add imagePullSecrets directly to the deployment

More persistent than the SA approach since operator's Update silently fails:

```bash
oc patch deployment search-collector -n open-cluster-management --type=json -p '[
  {"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"quay-pull-secret"}]}
]'
```

### Verify the right credentials

```bash
# Check the quay password works locally first
docker login -u='<username>' -p='<password>' quay.io

# Check the cluster's global pull secret registries
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c \
  "import sys,json; print(list(json.load(sys.stdin)['auths'].keys()))"
```

---

## Installing ACM Dev Build (5.0 / Latest)

Use the `install-acm.sh` script from this repo:

```bash
./projects/acm-cluster-setup/scripts/install-acm.sh \
  --server=https://api.your-cluster.com:6443 \
  --kubeadmin-password='xxxxx-xxxxx-xxxxx-xxxxx' \
  --quay-user=<your-quay-username> \
  --quay-password='<acm-d CLI password from quay.io>' \
  --version=5.0
```

> The `--quay-password` here is for `quay.io:443/acm-d` (internal Red Hat dev builds),
> NOT your personal quay.io password. Get it from:
> quay.io → Account Settings → Generate Encrypted Password → Docker Login

### If CatalogSource times out

The script has a 180s timeout which is sometimes too short. If it fails:

```bash
# Check if catalog pods actually started
oc get pods -n openshift-marketplace | grep -E "acm|mce"

# Wait for them to reach READY
oc get catalogsource acm-dev-catalog -n openshift-marketplace \
  -o jsonpath='{.status.connectionState.lastObservedState}'

# Re-run the script with --skip-pull-secret
./install-acm.sh --server=... --skip-pull-secret --version=5.0 ...
```

---

## Enabling Feature Flags

### FEATURE_CONFIGURABLE_COLLECTION (required for CollectorConfig testing)

```bash
oc patch search search-v2-operator -n open-cluster-management --type=merge -p '{
  "spec": {"deployments": {"collector": {
    "envVar": [{"name": "FEATURE_CONFIGURABLE_COLLECTION", "value": "true"}]
  }}}
}'
```

### Other search feature flags (via Search CR annotations)

```bash
# Global Search (tech preview)
oc annotate search search-v2-operator -n open-cluster-management 'global-search-preview=true'

# Fine-grained RBAC
oc annotate search search-v2-operator -n open-cluster-management 'fine-grained-rbac=true'

# Virtual machine actions
oc annotate search search-v2-operator -n open-cluster-management 'virtual-machine-preview=true'

# Pause all reconciliation
oc annotate search search-v2-operator -n open-cluster-management 'search-pause=true'
```

---

## The CollectorConfig Webhook Issue

In a fresh ACM 5.0 install using the dev build operator, the CollectorConfig
`ValidatingWebhook` points to `webhook-service` but the actual service is named
`search-v2-operator-webhook-service`. Creating/updating CollectorConfig resources fails.

```bash
# Find the webhook
oc get validatingwebhookconfiguration validating-webhook-configuration \
  -o jsonpath='{.webhooks[*].name}'

# Fix: remove the webhook rule temporarily for testing
oc patch validatingwebhookconfiguration validating-webhook-configuration \
  --type=json -p '[{"op":"remove","path":"/webhooks/0"}]'
```

> The operator re-adds the webhook rule on each reconcile. Remove it again if it
> reappears. In production the operator is the correct version and this is not needed.

---

## Complete End-to-End Test Workflow

```bash
# 1. Pause operator (prevents reverting your changes)
oc annotate mch multiclusterhub -n open-cluster-management \
  'installer.open-cluster-management.io/pause'=true --overwrite
oc annotate search search-v2-operator -n open-cluster-management search-pause=true --overwrite

# 2. Apply updated CRD (from search-v2-operator repo)
oc apply -f config/crd/bases/search.open-cluster-management.io_collectorconfigs.yaml

# 3. Apply RBAC fix (add rule if not already present)
oc patch clusterrole search --type=json -p '[
  {"op":"add","path":"/rules/-","value":{
    "apiGroups":["search.open-cluster-management.io"],
    "resources":["collectorconfigs/status"],
    "verbs":["patch","update"]
  }}
]'

# 4. Create pull secret for your image
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=<user> --docker-password='<pass>' \
  -n open-cluster-management 2>/dev/null || \
oc delete secret quay-pull-secret -n open-cluster-management && \
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=<user> --docker-password='<pass>' \
  -n open-cluster-management

# 5. Remove CollectorConfig webhook (blocks apply in fresh installs)
oc patch validatingwebhookconfiguration validating-webhook-configuration \
  --type=json -p '[{"op":"remove","path":"/webhooks/0"}]' 2>/dev/null || true

# 6. Deploy custom image
oc patch deployment search-collector -n open-cluster-management --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"quay.io/<user>/search-collector:my-branch\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/imagePullSecrets\",
   \"value\":[{\"name\":\"quay-pull-secret\"}]},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",
   \"value\":{\"name\":\"FEATURE_CONFIGURABLE_COLLECTION\",\"value\":\"true\"}}
]"
oc rollout restart deployment/search-collector -n open-cluster-management
oc rollout status deployment/search-collector -n open-cluster-management --timeout=60s

# 7. Verify the right image is running
oc logs -n open-cluster-management -l name=search-collector --tail=5

# 8. Apply a test CollectorConfig
oc apply -f - <<'EOF'
apiVersion: search.open-cluster-management.io/v1alpha1
kind: CollectorConfig
metadata:
  name: collector-config
  namespace: open-cluster-management
spec:
  collectionRules:
  - action: exclude     # invalid — triggers Applied=False
    resourceSelector:
      apiGroups: ["coordination.k8s.io"]
      kinds: ["Lease"]
EOF
oc rollout restart deployment/search-collector -n open-cluster-management
oc rollout status deployment/search-collector -n open-cluster-management --timeout=60s

# 9. Verify condition
sleep 5
oc describe collectorconfig collector-config -n open-cluster-management | grep -A10 "Status:"

# 10. Clean up — unpause everything
oc annotate search search-v2-operator -n open-cluster-management search-pause- --overwrite
oc annotate mch multiclusterhub -n open-cluster-management \
  'installer.open-cluster-management.io/pause'- \
  mch-pause- --overwrite
```

---

## lastTransitionTime Test Matrix

After deploying the custom image, run this matrix to validate the
`lastTransitionTime` behavior (Kubernetes convention: only update on True↔False transition):

| Test | Config change | Previous status | Expected status | Expected timestamp |
|------|--------------|-----------------|-----------------|-------------------|
| A | None (restart) | True | True | UNCHANGED |
| B | Add broken rule | True | False | UPDATED |
| C | None (restart) | False | False | UNCHANGED |
| D | Fix the rule | False | True | UPDATED |
| E | Delete CR | N/A | N/A | No write at all |
| F | Empty rules [] | Any | True | UPDATED if was False |
| G | Mixed valid+invalid | Any | False | Updated if was True |
| H | Restart same mixed | False | False | UNCHANGED |
| I | Different broken rule | False | False | UNCHANGED (even if message changes) |

---

## Key Diagnostics

```bash
# Is the right image running?
oc get deployment search-collector -n open-cluster-management \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Is the feature flag set?
oc get deployment search-collector -n open-cluster-management \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  python3 -c "import sys,json; [print(e['name'],'=',e.get('value','')) for e in json.load(sys.stdin)]"

# Is the operator paused?
oc get search search-v2-operator -n open-cluster-management \
  -o jsonpath='{.metadata.annotations.search-pause}'

# Is MCH paused?
oc get mch multiclusterhub -n open-cluster-management \
  -o jsonpath='{.metadata.annotations}'

# Check collector startup logs for config loading
oc logs -n open-cluster-management -l name=search-collector --tail=20 | \
  grep -E "collector-config|Applied|Skipping|merged|status"

# Check the CollectorConfig status
oc describe collectorconfig collector-config -n open-cluster-management

# Does the service account have pull secrets?
oc get sa search-serviceaccount -n open-cluster-management -o jsonpath='{.imagePullSecrets}'

# RBAC: can the collector update status?
oc auth can-i update collectorconfigs/status \
  --as=system:serviceaccount:open-cluster-management:search-serviceaccount
```

---

## Common Pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| `Exec format error` in pod logs | Image built for arm64 (Mac), cluster is amd64 | Rebuild with `--platform linux/amd64` |
| Pod stuck in `Pending` with no pull event | Cluster nodes can't reach external registry | Make repo public OR the cluster's kubelet has issues |
| `unauthorized: access to the requested resource` | Wrong quay password OR repo is private | Use correct password; make repo public or fix pull secret |
| Deployment image reverts after seconds | search-v2-operator reconciling | Pause with `search-pause=true` and pause MCH |
| `oc rollout restart` doesn't create new pod | Operator reverted restart annotation | Pause operator first |
| `Failed calling webhook ... service not found` | Webhook points to wrong service name | Remove webhook rule: `oc patch ... --type=json -p '[{"op":"remove","path":"/webhooks/0"}]'` |
| Webhook removed but reappears | Operator reconciles it back | Remove it after each operator reconcile OR stay paused |
| `cannot update collectorconfigs/status (forbidden)` | RBAC missing for status subresource | Patch ClusterRole `search` to add the rule |
| `oc logs` fails with TLS error | Cluster has kubelet TLS issues | Find a different cluster; some prow clusters are broken |
| `lastTransitionTime` changes on every restart | Bug — old implementation always writes `now()` | Fixed in ACM-33146: now reads existing status first |
| Status update silently not written | `r.Update()` fails due to missing ResourceVersion | Known operator bug; status write from collector uses dynamic client directly (not affected) |

---

## Architecture Notes

- The **search-collector** reads `CollectorConfig` from Kubernetes at startup only.
  After applying a new `CollectorConfig`, you must **restart the collector pod** to pick it up.
  (ACM-20047 tracks adding watch-based dynamic reload.)

- The **search-v2-operator** has a pre-existing bug where `createOrUpdateDeployment`
  constructs Deployment objects without copying `resourceVersion`, causing all
  `r.Update()` calls to fail silently. This is why `imageOverride` in the Search CR
  often doesn't propagate. The workaround is to pause the operator and patch directly.

- The **search-collector** queries the `collectorconfigs/status` subresource directly
  via `dynamic.Client.Update(..., "status")`. This bypasses the operator's ResourceVersion
  bug entirely since the collector reads the object first (via `Get`) and passes the
  same object back with the updated status, preserving the `resourceVersion`.

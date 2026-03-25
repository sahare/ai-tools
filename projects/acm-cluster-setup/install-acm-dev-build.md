# Installing ACM Dev Builds from quay.io/acm-d

This document describes how to install ACM (Advanced Cluster Management) development builds from the internal `quay.io:443/acm-d` registry on an OpenShift cluster.

## Quick Start (Automated)

Use the [`install-acm.sh`](scripts/install-acm.sh) script to automate the entire process:

```bash
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --token=sha256~xxxxx \
  --quay-user=<your-quay-username> \
  --quay-password=<your-quay-cli-password> \
  --version=2.17
```

Or with kubeadmin credentials:

```bash
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --kubeadmin-password=xxxxx-xxxxx-xxxxx-xxxxx \
  --quay-user=<your-quay-username> \
  --quay-password=<your-quay-cli-password> \
  --version=2.17
```

To uninstall:

```bash
./scripts/install-acm.sh --server=... --token=... --uninstall
```

Additional options:
- `--skip-pull-secret` - Skip pull secret patching if already configured
- `--version=X.XX` - ACM version to install (default: 2.17)
- `--help` - Show all options

The script handles all the steps described below automatically, including waiting for each component to be ready and verifying the installation.

## Prerequisites

- Access to an OpenShift cluster with cluster-admin privileges
- `oc` CLI installed and configured
- `jq` installed (for pull secret manipulation)
- Quay.io credentials with access to the `acm-d` organization
- Your Quay.io CLI password (get it from quay.io Account Settings > Generate Encrypted Password)

## Manual Installation Steps

The installation process involves:
1. Updating the cluster pull secret with quay.io credentials
2. Verifying ImageContentSourcePolicy exists (for image mirroring)
3. Creating CatalogSources for ACM and MCE
4. Installing the ACM operator
5. Creating the MultiClusterHub

Note: Either naming convention works for CatalogSources and Subscriptions (e.g., `acm-dev-catalog` vs `acm-custom-registry`). This document uses one consistent set of names.

## Step 1: Update Cluster Pull Secret

The cluster needs credentials to pull images from `quay.io:443/acm-d`.

### 1.1 Get the current pull secret

```bash
oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/authfile
```

### 1.2 Add quay.io:443 credentials

Option A: Using podman (if available)
```bash
podman login --authfile /tmp/authfile --username "<your-quay-username>" --password "<your-quay-cli-password>" quay.io:443
```

Option B: Manually add credentials
```bash
# Create base64 encoded auth token
AUTH_TOKEN=$(echo -n "<your-quay-username>:<your-quay-cli-password>" | base64)

# Add to authfile
cat /tmp/authfile | jq --arg token "$AUTH_TOKEN" '.auths["quay.io:443"] = {"auth": $token}' > /tmp/authfile_updated
mv /tmp/authfile_updated /tmp/authfile
```

### 1.3 Update the cluster pull secret

```bash
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/authfile
```

### 1.4 Verify the update

```bash
oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq '.auths | keys'
```

You should see `quay.io:443` in the list.

## Step 2: Verify ImageContentSourcePolicy

Clusterpool clusters typically have this already configured. Verify with:

```bash
oc get imagecontentsourcepolicy
```

If `rhacm-repo` or similar exists, you're good. If not, you may need to create one:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/rhacm2
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/multicluster-engine
```

## Step 3: Create CatalogSources

Create the ACM and MCE catalog sources pointing to the dev builds.

### For ACM 2.17:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: acm-dev-catalog
  namespace: openshift-marketplace
spec:
  displayName: 'acm-dev-catalog:latest-2.17'
  image: 'quay.io:443/acm-d/acm-dev-catalog:latest-2.17'
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mce-dev-catalog
  namespace: openshift-marketplace
spec:
  displayName: 'mce-dev-catalog:latest-2.17'
  image: 'quay.io:443/acm-d/mce-dev-catalog:latest-2.17'
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
```

### For other versions:

Replace `latest-2.17` with the appropriate tag:
- ACM 2.16: `latest-2.16`
- ACM 2.15: `latest-2.15`

### Verify CatalogSources are ready:

```bash
oc get catalogsource -n openshift-marketplace
oc get pods -n openshift-marketplace | grep -E "acm|mce"
```

Wait until the catalog pods are Running and the catalogsource shows `READY` state:

```bash
oc get catalogsource acm-dev-catalog -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}'
```

## Step 4: Install ACM Operator

### 4.1 Create the namespace

```bash
oc create namespace open-cluster-management
```

### 4.2 Create OperatorGroup

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
  - open-cluster-management
EOF
```

### 4.3 Create Subscription

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.17
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: acm-dev-catalog
  sourceNamespace: openshift-marketplace
EOF
```

For other versions, change the channel:
- ACM 2.16: `release-2.16`
- ACM 2.15: `release-2.15`

### 4.4 Verify installation

```bash
# Check subscription status
oc get subscription.operators.coreos.com -n open-cluster-management advanced-cluster-management

# Check CSV status (wait for Succeeded)
oc get csv -n open-cluster-management
```

## Step 5: Create MultiClusterHub

Once the operator CSV shows `Succeeded`, create the MultiClusterHub:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
```

### Monitor installation progress:

```bash
# Watch MCH status
oc get mch -n open-cluster-management -w

# Check pods
oc get pods -n open-cluster-management

# Check MCH details
oc describe mch multiclusterhub -n open-cluster-management
```

The MCH status will change from `Installing` to `Running` when complete (typically 5-10 minutes).

## Step 6: Access ACM Console

Once MCH is Running, get the console URL:

```bash
oc get route multicloud-console -n open-cluster-management -o jsonpath='{.spec.host}'
```

Or access via the OpenShift console under the ACM menu.

## Troubleshooting

### CatalogSource not ready

```bash
# Check catalog pod logs
oc logs -n openshift-marketplace -l olm.catalogSource=acm-dev-catalog

# Check events
oc get events -n openshift-marketplace --sort-by='.lastTimestamp'
```

### Image pull errors

```bash
# Verify pull secret has quay.io:443
oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq '.auths["quay.io:443"]'

# Check if nodes can pull images
oc get events -A | grep -i "pull\|image"
```

### Subscription stuck

```bash
# Check installplan
oc get installplan -n open-cluster-management

# Approve if manual approval required
oc patch installplan <installplan-name> -n open-cluster-management --type merge --patch '{"spec": {"approved": true}}'
```

### MCH stuck in Installing

```bash
# Check MCH conditions
oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.conditions}' | jq

# Check operator logs
oc logs -n open-cluster-management -l name=multiclusterhub-operator

# Check component status
oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.components}' | jq
```

## Cleanup

To uninstall ACM:

```bash
# Delete MCH
oc delete mch multiclusterhub -n open-cluster-management

# Wait for MCH deletion to complete
oc get mch -n open-cluster-management

# Delete subscription
oc delete subscription advanced-cluster-management -n open-cluster-management

# Delete CSV
oc delete csv -n open-cluster-management --all

# Delete namespace (optional)
oc delete namespace open-cluster-management

# Delete catalogsources (optional)
oc delete catalogsource acm-dev-catalog mce-dev-catalog -n openshift-marketplace
```

## Notes

- The dev builds are tagged with `latest-X.XX` (e.g., `latest-2.17`) and are updated regularly
- Starting from ACM 2.17, both ACM and MCE use the same version tag (2.17)
- The `updateStrategy.registryPoll.interval: 10m` ensures the catalog is refreshed every 10 minutes to pick up new builds
- For production, use the official Red Hat Operators catalog instead of dev builds
- ACM automatically installs MCE as a dependency, so you don't need to install MCE separately
- Clusterpool clusters from the collective hub typically have ICSP already configured
- Updating the pull secret may trigger a rolling restart of cluster nodes
- The `install-acm.sh` script is idempotent and can be re-run safely if a step fails partway through
- See also [stolostron/deploy](https://github.com/stolostron/deploy) for the upstream community deployment tool with snapshot support

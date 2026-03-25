#!/bin/bash
#
# install-acm.sh - Fully automated ACM Dev Build Installation
#
# Automates the entire process documented in install-acm-dev-build.md:
#   1. Login to cluster
#   2. Patch pull secret with quay.io credentials
#   3. Verify/create ImageContentSourcePolicy
#   4. Create CatalogSources (ACM + MCE)
#   5. Install ACM operator (namespace, OperatorGroup, Subscription)
#   6. Create MultiClusterHub
#   7. Wait and verify everything is Running
#
# Usage:
#   ./install-acm.sh --server=<api-url> --token=<token> \
#                    --quay-user=<user> --quay-password=<password> \
#                    [--version=<version>] [--uninstall]
#
# Examples:
#   # Install ACM 2.17:
#   ./install-acm.sh --server=https://api.mycluster.example.com:6443 \
#     --token=sha256~xxxxx --quay-user=myuser --quay-password=mypassword
#
#   # Install a specific older version:
#   ./install-acm.sh --server=... --token=... --version=2.16 \
#     --quay-user=myuser --quay-password=mypassword
#
#   # Uninstall ACM from cluster:
#   ./install-acm.sh --server=... --token=... --uninstall
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ACM_VERSION="2.17"
TIMEOUT_CATALOG=180
TIMEOUT_OPERATOR=600
TIMEOUT_MCH=900
UNINSTALL=false
TOTAL_STEPS=7

usage() {
    echo "Usage: $0 --server=<api-url> --token=<token> --quay-user=<user> --quay-password=<pass> [options]"
    echo ""
    echo "Required (for install):"
    echo "  --server          OpenShift API server URL"
    echo "  --token           Login token (or --kubeadmin-password)"
    echo "  --kubeadmin-password  Kubeadmin password (alternative to --token)"
    echo "  --quay-user       quay.io username for acm-d access"
    echo "  --quay-password   quay.io CLI password for acm-d access"
    echo ""
    echo "Options:"
    echo "  --version         ACM version to install (default: 2.17)"
    echo "  --uninstall       Uninstall ACM from the cluster"
    echo "  --skip-pull-secret  Skip pull secret patching (already configured)"
    echo "  --help            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --server=https://api.mycluster.com:6443 --token=sha256~xxx \\"
    echo "     --quay-user=myuser --quay-password=mypass --version=2.17"
    echo ""
    echo "  $0 --server=https://api.mycluster.com:6443 --token=sha256~xxx --uninstall"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --server=*)           SERVER="${1#*=}"; shift ;;
        --token=*)            TOKEN="${1#*=}"; shift ;;
        --kubeadmin-password=*) KUBEADMIN_PASSWORD="${1#*=}"; shift ;;
        --version=*)          ACM_VERSION="${1#*=}"; shift ;;
        --quay-user=*)        QUAY_USER="${1#*=}"; shift ;;
        --quay-password=*)    QUAY_PASSWORD="${1#*=}"; shift ;;
        --uninstall)          UNINSTALL=true; shift ;;
        --skip-pull-secret)   SKIP_PULL_SECRET=true; shift ;;
        --help)               usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    {
    local step=$1; local msg=$2
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Step ${step}/${TOTAL_STEPS}: ${msg}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

spinner() {
    local pid=$1 msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${BLUE}[INFO]${NC} %s %s" "$msg" "${spin:i++%${#spin}:1}"
        sleep 0.2
    done
    printf "\r"
}

wait_for() {
    local timeout=$1 interval=$2 description=$3
    shift 3
    local cmd=("$@")
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if eval "${cmd[*]}" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        printf "\r${BLUE}[INFO]${NC} Waiting for %s... (%ds/%ds)" "$description" "$elapsed" "$timeout"
    done
    echo ""
    log_error "Timeout waiting for ${description} after ${timeout}s"
    return 1
}

# ── Step 1: Login ──────────────────────────────────────────────────
login_to_cluster() {
    log_step 1 "Logging into OpenShift cluster"

    if [[ -z "${SERVER:-}" ]]; then
        log_error "--server is required"
        exit 1
    fi

    if [[ -n "${TOKEN:-}" ]]; then
        oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true
    elif [[ -n "${KUBEADMIN_PASSWORD:-}" ]]; then
        oc login -u kubeadmin -p "$KUBEADMIN_PASSWORD" --server="$SERVER" --insecure-skip-tls-verify=true
    else
        log_error "--token or --kubeadmin-password is required"
        exit 1
    fi

    local cluster_version
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    log_success "Logged in to ${SERVER} (OCP ${cluster_version})"
}

# ── Step 2: Pull Secret ───────────────────────────────────────────
patch_pull_secret() {
    log_step 2 "Patching pull secret with quay.io credentials"

    if [[ "${SKIP_PULL_SECRET:-}" == "true" ]]; then
        log_info "Skipping pull secret patching (--skip-pull-secret)"
        return 0
    fi

    if [[ -z "${QUAY_USER:-}" || -z "${QUAY_PASSWORD:-}" ]]; then
        log_error "--quay-user and --quay-password are required"
        exit 1
    fi

    # Check if already configured
    if oc get secret/pull-secret -n openshift-config -o json | \
       jq -r '.data.".dockerconfigjson"' | base64 -d | \
       jq -e '.auths["quay.io:443"]' >/dev/null 2>&1; then
        log_info "quay.io:443 already in pull secret, updating..."
    fi

    local authfile="/tmp/authfile-$$"
    trap "rm -f ${authfile} ${authfile}.new" EXIT

    oc get secret/pull-secret -n openshift-config -o json | \
        jq -r '.data.".dockerconfigjson"' | base64 -d > "$authfile"

    local quay_auth
    quay_auth=$(echo -n "${QUAY_USER}:${QUAY_PASSWORD}" | base64)

    jq --arg auth "$quay_auth" \
        '.auths["quay.io:443"] = {"auth": $auth}' \
        "$authfile" > "${authfile}.new"
    mv "${authfile}.new" "$authfile"

    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$authfile"
    rm -f "$authfile"

    # Verify
    if oc get secret/pull-secret -n openshift-config -o json | \
       jq -r '.data.".dockerconfigjson"' | base64 -d | \
       jq -e '.auths["quay.io:443"]' >/dev/null 2>&1; then
        log_success "Pull secret updated with quay.io:443 credentials"
    else
        log_error "Failed to verify pull secret update"
        exit 1
    fi
}

# ── Step 3: ICSP ──────────────────────────────────────────────────
verify_image_mirror() {
    log_step 3 "Verifying image mirroring configuration"

    if oc get imagecontentsourcepolicy 2>/dev/null | grep -q "rhacm"; then
        log_success "ImageContentSourcePolicy 'rhacm' found"
        return 0
    fi

    if oc get imagecontentsourcepolicy 2>/dev/null | grep -q .; then
        log_success "ImageContentSourcePolicy found (cluster pool cluster)"
        return 0
    fi

    if oc get imagedigestmirrorset 2>/dev/null | grep -q .; then
        log_success "ImageDigestMirrorSet found"
        return 0
    fi

    log_warn "No image mirroring policy found, creating ICSP..."
    cat <<'EOF' | oc apply -f -
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
EOF
    log_warn "ICSP created - nodes will restart. Waiting 60s for rollout to begin..."
    sleep 60
    log_success "ICSP created"
}

# ── Step 4: CatalogSources ────────────────────────────────────────
create_catalog_sources() {
    log_step 4 "Creating CatalogSources for ACM ${ACM_VERSION}"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: acm-dev-catalog
  namespace: openshift-marketplace
spec:
  displayName: 'acm-dev-catalog:latest-${ACM_VERSION}'
  image: 'quay.io:443/acm-d/acm-dev-catalog:latest-${ACM_VERSION}'
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
  displayName: 'mce-dev-catalog:latest-${ACM_VERSION}'
  image: 'quay.io:443/acm-d/mce-dev-catalog:latest-${ACM_VERSION}'
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

    log_info "Waiting for CatalogSources to become ready..."
    if wait_for "$TIMEOUT_CATALOG" 10 "ACM CatalogSource" \
        "oc get catalogsource acm-dev-catalog -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -q READY"; then
        log_success "ACM CatalogSource is READY"
    else
        log_error "CatalogSource not ready. Check: oc logs -n openshift-marketplace -l olm.catalogSource=acm-dev-catalog"
        exit 1
    fi

    if wait_for "$TIMEOUT_CATALOG" 10 "MCE CatalogSource" \
        "oc get catalogsource mce-dev-catalog -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -q READY"; then
        log_success "MCE CatalogSource is READY"
    else
        log_warn "MCE CatalogSource not ready yet (ACM may install MCE automatically)"
    fi
}

# ── Step 5: ACM Operator ──────────────────────────────────────────
install_acm_operator() {
    log_step 5 "Installing ACM Operator"

    # Namespace
    oc get namespace open-cluster-management >/dev/null 2>&1 || \
        oc create namespace open-cluster-management
    log_info "Namespace open-cluster-management ready"

    # OperatorGroup
    if ! oc get operatorgroup -n open-cluster-management 2>/dev/null | grep -q .; then
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
        log_info "OperatorGroup created"
    else
        log_info "OperatorGroup already exists"
    fi

    # Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-${ACM_VERSION}
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: acm-dev-catalog
  sourceNamespace: openshift-marketplace
EOF
    log_info "Subscription created, waiting for operator CSV to succeed..."

    if wait_for "$TIMEOUT_OPERATOR" 15 "ACM operator CSV" \
        "oc get csv -n open-cluster-management 2>/dev/null | grep -q 'advanced-cluster-management.*Succeeded'"; then
        local csv_name
        csv_name=$(oc get csv -n open-cluster-management -o name 2>/dev/null | grep advanced-cluster-management | head -1)
        log_success "ACM Operator installed: ${csv_name}"
    else
        log_error "ACM Operator CSV did not reach Succeeded"
        oc get csv -n open-cluster-management 2>/dev/null
        oc get subscription -n open-cluster-management advanced-cluster-management -o yaml 2>/dev/null | tail -20
        exit 1
    fi
}

# ── Step 6: MultiClusterHub ───────────────────────────────────────
create_multiclusterhub() {
    log_step 6 "Creating MultiClusterHub"

    if oc get multiclusterhub multiclusterhub -n open-cluster-management >/dev/null 2>&1; then
        local current_status
        current_status=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null)
        log_info "MultiClusterHub already exists (status: ${current_status})"
        if [[ "$current_status" == "Running" ]]; then
            log_success "MCH is already Running"
            return 0
        fi
    else
        cat <<'EOF' | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
        log_info "MultiClusterHub created"
    fi

    log_info "Waiting for MCH to reach Running state (this takes 5-10 minutes)..."
    local elapsed=0
    while [[ $elapsed -lt $TIMEOUT_MCH ]]; do
        local status
        status=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

        if [[ "$status" == "Running" ]]; then
            echo ""
            log_success "MultiClusterHub is Running!"
            return 0
        fi

        sleep 15
        elapsed=$((elapsed + 15))
        printf "\r${BLUE}[INFO]${NC} MCH status: %-15s (%ds/%ds)" "$status" "$elapsed" "$TIMEOUT_MCH"
    done

    echo ""
    log_error "MCH did not reach Running state within ${TIMEOUT_MCH}s"
    oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.conditions}' 2>/dev/null | jq '.' 2>/dev/null || true
    exit 1
}

# ── Step 7: Verify ────────────────────────────────────────────────
verify_installation() {
    log_step 7 "Verifying Installation"

    local version status console_url pod_count

    version=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.currentVersion}' 2>/dev/null || echo "N/A")
    status=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    console_url=$(oc get route multicloud-console -n open-cluster-management -o jsonpath='{.spec.host}' 2>/dev/null || echo "not available yet")
    pod_count=$(oc get pods -n open-cluster-management --no-headers 2>/dev/null | grep -c Running || echo "0")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ACM Installation Complete!               ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ACM Version:  ${BOLD}${version}${NC}"
    echo -e "${GREEN}║${NC} MCH Status:   ${BOLD}${status}${NC}"
    echo -e "${GREEN}║${NC} Running Pods: ${BOLD}${pod_count}${NC}"
    echo -e "${GREEN}║${NC} Console:      ${BOLD}https://${console_url}${NC}"
    echo -e "${GREEN}║${NC} Cluster:      ${BOLD}${SERVER}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Uninstall ─────────────────────────────────────────────────────
uninstall_acm() {
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  Uninstalling ACM${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    log_info "Deleting MultiClusterHub..."
    oc delete mch multiclusterhub -n open-cluster-management --timeout=600s 2>/dev/null || true

    log_info "Waiting for MCH deletion..."
    wait_for 300 10 "MCH deletion" \
        "! oc get mch multiclusterhub -n open-cluster-management 2>/dev/null" || true

    log_info "Deleting Subscription..."
    oc delete subscription advanced-cluster-management -n open-cluster-management 2>/dev/null || true

    log_info "Deleting CSVs..."
    oc delete csv -n open-cluster-management --all 2>/dev/null || true

    log_info "Deleting CatalogSources..."
    oc delete catalogsource acm-dev-catalog mce-dev-catalog -n openshift-marketplace 2>/dev/null || true

    log_info "Deleting namespace..."
    oc delete namespace open-cluster-management --timeout=300s 2>/dev/null || true

    log_success "ACM uninstalled"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
    local start_time
    start_time=$(date +%s)

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   ACM Dev Build Installer                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    login_to_cluster

    if [[ "$UNINSTALL" == "true" ]]; then
        uninstall_acm
        return 0
    fi

    echo -e "  ${BOLD}ACM Version:${NC} ${ACM_VERSION}"
    echo -e "  ${BOLD}Registry:${NC}    quay.io:443/acm-d"
    echo ""

    patch_pull_secret
    verify_image_mirror
    create_catalog_sources
    install_acm_operator
    create_multiclusterhub
    verify_installation

    local end_time elapsed_min elapsed_sec
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))
    elapsed_sec=$(( (end_time - start_time) % 60 ))
    echo -e "${GREEN}Total time: ${elapsed_min}m ${elapsed_sec}s${NC}"
}

main

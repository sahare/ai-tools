#!/bin/bash
#
# diagnose.sh - AI-powered ACM installation diagnostics
#
# Collects cluster state, logs, and events relevant to ACM installation,
# then formats them for AI analysis. When used with an AI coding assistant
# (e.g., Cursor), the assistant can analyze the output and suggest fixes.
#
# Usage:
#   ./diagnose.sh --server=<api-url> --token=<token>
#   ./diagnose.sh --server=<api-url> --token=<token> --health-only
#   ./diagnose.sh --server=<api-url> --token=<token> --output=/tmp/diagnosis.md
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

HEALTH_ONLY=false
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --server=*)              SERVER="${1#*=}"; shift ;;
        --token=*)               TOKEN="${1#*=}"; shift ;;
        --kubeadmin-password=*)  KUBEADMIN_PASSWORD="${1#*=}"; shift ;;
        --health-only)           HEALTH_ONLY=true; shift ;;
        --output=*)              OUTPUT_FILE="${1#*=}"; shift ;;
        --help)
            echo "Usage: $0 --server=<api-url> --token=<token> [--health-only] [--output=<file>]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Output handling - write to file and/or stdout
report() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$1" >> "$OUTPUT_FILE"
    fi
    echo -e "$1"
}

section() {
    report ""
    report "═══════════════════════════════════════════════════════════"
    report "  $1"
    report "═══════════════════════════════════════════════════════════"
}

subsection() {
    report ""
    report "--- $1 ---"
}

# Capture command output, handling errors gracefully
capture() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1) || true
    if [[ -n "$output" ]]; then
        report "$output"
    else
        report "(no output)"
    fi
}

# ── Login ─────────────────────────────────────────────────────────
if [[ -n "${SERVER:-}" ]]; then
    if [[ -n "${TOKEN:-}" ]]; then
        oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1
    elif [[ -n "${KUBEADMIN_PASSWORD:-}" ]]; then
        oc login -u kubeadmin -p "$KUBEADMIN_PASSWORD" --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1
    fi
fi

# Verify connection
if ! oc whoami >/dev/null 2>&1; then
    echo -e "${RED}Not logged into any cluster. Provide --server and --token${NC}"
    exit 1
fi

# Initialize output file
if [[ -n "$OUTPUT_FILE" ]]; then
    echo "" > "$OUTPUT_FILE"
fi

CLUSTER_URL=$(oc whoami --show-server 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

report ""
report "╔══════════════════════════════════════════════════════════╗"
report "║  ACM Cluster Diagnostic Report                          ║"
report "║  Generated: ${TIMESTAMP}                ║"
report "╚══════════════════════════════════════════════════════════╝"
report ""
report "Cluster: ${CLUSTER_URL}"
report "User: $(oc whoami 2>/dev/null || echo 'unknown')"

# ── Section 1: Cluster Health ─────────────────────────────────────
section "1. CLUSTER HEALTH"

subsection "OpenShift Version"
capture "OCP version" oc get clusterversion version -o jsonpath='{.status.desired.version}'
report ""

subsection "Node Status"
capture "Nodes" oc get nodes --no-headers
report ""
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l | tr -d ' ')
if [[ "$NOT_READY" -gt 0 ]]; then
    report "⚠️  WARNING: ${NOT_READY} node(s) are NOT Ready"
fi

subsection "Cluster Operators (degraded/unavailable)"
DEGRADED_OPS=$(oc get co --no-headers 2>/dev/null | awk '$3=="False" || $4=="True" || $5=="True" {print $0}')
if [[ -n "$DEGRADED_OPS" ]]; then
    report "$DEGRADED_OPS"
    report "⚠️  WARNING: Some cluster operators are degraded"
else
    report "All cluster operators are healthy"
fi

if [[ "$HEALTH_ONLY" == "true" ]]; then
    section "HEALTH CHECK COMPLETE"
    report ""
    report "Cluster appears healthy. Use without --health-only for full ACM diagnostics."
    exit 0
fi

# ── Section 2: Pull Secret ────────────────────────────────────────
section "2. PULL SECRET STATUS"

QUAY_AUTH=$(oc get secret/pull-secret -n openshift-config -o json 2>/dev/null | \
    jq -r '.data.".dockerconfigjson"' | base64 -d 2>/dev/null | \
    jq -e '.auths["quay.io:443"]' 2>/dev/null)
if [[ -n "$QUAY_AUTH" && "$QUAY_AUTH" != "null" ]]; then
    report "✅ quay.io:443 credentials found in pull secret"
else
    report "❌ quay.io:443 credentials NOT found in pull secret"
    report "   FIX: Run install-acm.sh with --quay-user and --quay-password"
fi

# ── Section 3: Image Mirroring ────────────────────────────────────
section "3. IMAGE MIRRORING (ICSP/IDMS)"

ICSP=$(oc get imagecontentsourcepolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
IDMS=$(oc get imagedigestmirrorset --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$ICSP" -gt 0 ]]; then
    report "✅ ImageContentSourcePolicy found (${ICSP} policies)"
    capture "ICSP list" oc get imagecontentsourcepolicy --no-headers
elif [[ "$IDMS" -gt 0 ]]; then
    report "✅ ImageDigestMirrorSet found (${IDMS} sets)"
else
    report "❌ No image mirroring configured"
    report "   FIX: Create an ICSP for rhacm2 -> quay.io:443/acm-d mirroring"
fi

# ── Section 4: CatalogSources ────────────────────────────────────
section "4. CATALOGSOURCES"

subsection "All CatalogSources in openshift-marketplace"
capture "CatalogSources" oc get catalogsource -n openshift-marketplace --no-headers

for CS in acm-dev-catalog acm-custom-registry; do
    CS_STATE=$(oc get catalogsource "$CS" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)
    if [[ -n "$CS_STATE" ]]; then
        if [[ "$CS_STATE" == "READY" ]]; then
            report "✅ ${CS}: ${CS_STATE}"
        else
            report "❌ ${CS}: ${CS_STATE}"
        fi
        CS_IMAGE=$(oc get catalogsource "$CS" -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null)
        report "   Image: ${CS_IMAGE}"
    fi
done

subsection "CatalogSource Pods"
capture "Catalog pods" oc get pods -n openshift-marketplace --no-headers

# Check for image pull errors in marketplace
PULL_ERRORS=$(oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>/dev/null | grep -i "pull\|image\|back-off" | tail -5)
if [[ -n "$PULL_ERRORS" ]]; then
    subsection "⚠️  Image Pull Events in openshift-marketplace"
    report "$PULL_ERRORS"
fi

# ── Section 5: ACM Operator ──────────────────────────────────────
section "5. ACM OPERATOR"

subsection "Namespace"
if oc get namespace open-cluster-management >/dev/null 2>&1; then
    report "✅ open-cluster-management namespace exists"
else
    report "❌ open-cluster-management namespace does not exist"
    report "   FIX: The ACM operator has not been installed yet"
fi

subsection "Subscription"
capture "Subscription" oc get subscription -n open-cluster-management --no-headers

subsection "ClusterServiceVersion"
capture "CSV" oc get csv -n open-cluster-management --no-headers

CSV_PHASE=$(oc get csv -n open-cluster-management -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [[ "$CSV_PHASE" == "Succeeded" ]]; then
    report "✅ Operator CSV: Succeeded"
elif [[ -n "$CSV_PHASE" ]]; then
    report "❌ Operator CSV: ${CSV_PHASE}"

    subsection "CSV Conditions"
    capture "CSV conditions" oc get csv -n open-cluster-management -o jsonpath='{.items[0].status.conditions}' 2>/dev/null
fi

subsection "InstallPlan"
capture "InstallPlan" oc get installplan -n open-cluster-management --no-headers

# ── Section 6: MultiClusterHub ────────────────────────────────────
section "6. MULTICLUSTERHUB"

MCH_PHASE=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null)
MCH_VERSION=$(oc get mch multiclusterhub -n open-cluster-management -o jsonpath='{.status.currentVersion}' 2>/dev/null)

if [[ -n "$MCH_PHASE" ]]; then
    if [[ "$MCH_PHASE" == "Running" ]]; then
        report "✅ MCH Status: ${MCH_PHASE}"
    else
        report "⚠️  MCH Status: ${MCH_PHASE}"
    fi
    report "   Version: ${MCH_VERSION:-unknown}"

    if [[ "$MCH_PHASE" != "Running" ]]; then
        subsection "MCH Conditions"
        oc get mch multiclusterhub -n open-cluster-management -o json 2>/dev/null | \
            jq -r '.status.conditions[]? | "  \(.type): \(.status) - \(.message // "N/A")"' 2>/dev/null || \
            report "  (unable to read conditions)"
    fi
else
    report "❌ MultiClusterHub not found"
fi

subsection "MCH Operator Pod"
capture "MCH operator" oc get pods -n open-cluster-management -l name=multiclusterhub-operator --no-headers

# ── Section 7: Pod Status ─────────────────────────────────────────
section "7. POD STATUS (open-cluster-management)"

TOTAL_PODS=$(oc get pods -n open-cluster-management --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING_PODS=$(oc get pods -n open-cluster-management --no-headers 2>/dev/null | grep -c "Running" || echo "0")
NOT_RUNNING=$(oc get pods -n open-cluster-management --no-headers 2>/dev/null | grep -v "Running\|Completed" || true)

report "Total: ${TOTAL_PODS}, Running: ${RUNNING_PODS}"

if [[ -n "$NOT_RUNNING" ]]; then
    subsection "⚠️  Pods NOT Running/Completed"
    report "$NOT_RUNNING"
fi

# ── Section 8: Recent Events ─────────────────────────────────────
section "8. RECENT ERROR EVENTS"

subsection "open-cluster-management (last 10 warnings)"
oc get events -n open-cluster-management --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -10 || report "(no warning events)"

subsection "openshift-marketplace (last 5 warnings)"
oc get events -n openshift-marketplace --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -5 || report "(no warning events)"

# ── Section 9: Console URL ────────────────────────────────────────
section "9. ACCESS"

CONSOLE_URL=$(oc get route multicloud-console -n open-cluster-management -o jsonpath='{.spec.host}' 2>/dev/null)
if [[ -n "$CONSOLE_URL" ]]; then
    report "✅ ACM Console: https://${CONSOLE_URL}"
else
    report "❌ ACM Console route not available"
fi

OCP_CONSOLE=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)
if [[ -n "$OCP_CONSOLE" ]]; then
    report "   OCP Console: https://${OCP_CONSOLE}"
fi

# ── Summary ───────────────────────────────────────────────────────
section "SUMMARY"

ISSUES=0
[[ -z "$QUAY_AUTH" || "$QUAY_AUTH" == "null" ]] && ISSUES=$((ISSUES + 1)) && report "❌ Pull secret missing quay.io:443"
[[ "$ICSP" -eq 0 && "$IDMS" -eq 0 ]] && ISSUES=$((ISSUES + 1)) && report "❌ No image mirroring configured"
[[ -z "$CSV_PHASE" ]] && ISSUES=$((ISSUES + 1)) && report "❌ ACM operator not installed"
[[ -n "$CSV_PHASE" && "$CSV_PHASE" != "Succeeded" ]] && ISSUES=$((ISSUES + 1)) && report "❌ Operator CSV not Succeeded (${CSV_PHASE})"
[[ -z "$MCH_PHASE" ]] && ISSUES=$((ISSUES + 1)) && report "❌ MultiClusterHub not created"
[[ -n "$MCH_PHASE" && "$MCH_PHASE" != "Running" ]] && ISSUES=$((ISSUES + 1)) && report "⚠️  MCH not Running (${MCH_PHASE})"
[[ "$NOT_READY" -gt 0 ]] && ISSUES=$((ISSUES + 1)) && report "⚠️  ${NOT_READY} node(s) not ready"

if [[ $ISSUES -eq 0 ]]; then
    report ""
    report "✅ No issues detected. ACM appears healthy."
else
    report ""
    report "Found ${ISSUES} issue(s). Review the sections above for details."
    report ""
    report "💡 TIP: Share this diagnostic report with your AI coding assistant"
    report "   for automated root cause analysis and fix suggestions."
fi

report ""

if [[ -n "$OUTPUT_FILE" ]]; then
    echo -e "${GREEN}Diagnostic report saved to: ${OUTPUT_FILE}${NC}"
fi

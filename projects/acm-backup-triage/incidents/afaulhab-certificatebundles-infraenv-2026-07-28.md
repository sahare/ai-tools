# Incident: Two gaps found during afaulhab's incremental hub migration (ACM-38831, ACM-38832)

**Date investigated:** 2026-07-28
**Customer/reporter:** afaulhab (Slack, migrating clusters one-at-a-time from an old hub to a new hub)
**Investigator:** sahare, code-level investigation in `cluster-backup-operator` + upstream `assisted-service` research (no live cluster access for this one — desk investigation only)
**Status:** Root cause confirmed for both at the code/design level. ACM-38831 resolved as **expected behavior** per QE feedback (2026-07-28) — see update at bottom. ACM-38832 requires a fix in `assisted-service` (Infrastructure Operator / MGMT team).

## Customer's original report (verbatim, condensed)

> A cluster where later in the lifecycle new workers were added had `spec.ClusterRef` and `spec.OSImageVersion` set and failed importing with admission webhook `infraenvvalidators.admission.agentinstall.openshift.io` denied the request
>
> A cluster that manages its API and Ingress secrets in Hive `spec.certificateBundles`, the secrets linked there will not be getting the backup label and will hence not be restored to the new ACM.

Customer opened [ACM-38831](https://redhat.atlassian.net/browse/ACM-38831) and [ACM-38832](https://redhat.atlassian.net/browse/ACM-38832) for these two.

---

## ACM-38831 — `certificateBundles` secrets never get a backup label

**Confirmed: this is a `cluster-backup-operator` gap.** The customer's own diagnosis is correct.

### How credentials backup selection works

`acm-credentials-schedule` (the Velero schedule backing up secrets/configmaps) only includes a secret/configmap if it has ONE of three labels:

```256:279:controllers/backup.go
	// hive label selector
	reqHive := &v1.LabelSelectorRequirement{}
	reqHive.Key = backupCredsHiveLabel   // hive.openshift.io/secret-type
	reqHive.Operator = "Exists"
	...
	// generic backup selector
	reqUser := &v1.LabelSelectorRequirement{}
	reqUser.Key = backupCredsUserLabel   // cluster.open-cluster-management.io/type
	reqUser.Operator = "Exists"
	...
	// cluster backup selector
	reqCls := &v1.LabelSelectorRequirement{}
	reqCls.Key = backupCredsClusterLabel // cluster.open-cluster-management.io/backup
	reqCls.Operator = "Exists"
```

1. `hive.openshift.io/secret-type` — set **natively by Hive itself** on secrets it creates and manages (admin kubeconfig, admin password, etc.)
2. `cluster.open-cluster-management.io/type` — user label
3. `cluster.open-cluster-management.io/backup` — our own label, added in `pre_backup.go` for special cases

### Where certificateBundles secrets fall through

Confirmed against the upstream Hive API types (`github.com/openshift/hive/apis`, `hive/v1/clusterdeployment_types.go`):

```784:800:(hive/apis) hive/v1/clusterdeployment_types.go
// CertificateBundleSpec specifies a certificate bundle associated with a cluster deployment
type CertificateBundleSpec struct {
	Name string `json:"name"`
	...
	// the secret should exist in the same namespace as the ClusterDeployment
	CertificateSecretRef corev1.LocalObjectReference `json:"certificateSecretRef"`
}
```

`ClusterDeployment.Spec.CertificateBundles[].CertificateSecretRef.Name` is a **reference to a user-created secret** (the customer brings their own TLS cert/key for API/ingress). Hive does not create or manage this secret — it only reads it — so Hive never applies `hive.openshift.io/secret-type` to it.

I checked every code path in `pre_backup.go` that grants the `cluster.open-cluster-management.io/backup` label to Hive-adjacent secrets:

| Function | What it labels | Matching method |
|---|---|---|
| `updateHiveResources()` | Secrets for ClusterPool-backed ClusterDeployments only (`clusterDeployment.Spec.ClusterPoolRef != nil`) | **Name-prefix match** against `clusterDeployment.Name` |
| `updateAISecrets()` | Assisted-install secrets | Pre-existing label `agent-install.openshift.io/watch` |
| `updateMetalSecrets()` | Metal3 secrets | Pre-existing label `environment.metal3.io` |

**None of these touch `Spec.CertificateBundles`.** There is zero code in this repo that references `CertificateBundle` (confirmed via full-repo grep). So a `certificateBundles` secret:
- Is not Hive-managed → no `hive.openshift.io/secret-type`
- Is not caught by any of the three functions above → no `cluster.open-cluster-management.io/backup`
- Is not necessarily named with the ClusterDeployment name as a prefix (these are often customer-chosen names, e.g. `api-cert-secret`) → wouldn't be caught even by `updateHiveResources`'s prefix logic if it were extended naively

Net effect: the secret is silently excluded from every backup, and on restore the referenced secret simply doesn't exist on the new hub. Hive will report a condition like `ControlPlaneCertificateNotFoundCondition` / `IngressCertificateNotFoundCondition` (both exist as named conditions in the Hive API — confirmed in the same types file) once it notices the secret is missing.

### Proposed fix (drafted, then reverted — see QE update below)

Added a new function analogous to `updateAISecrets`/`updateMetalSecrets`, `updateCertificateBundleSecrets()`, called from the same place `updateHiveResources()` is called (`pre_backup.go`):

1. List all `ClusterDeployment`s
2. For each, iterate `Spec.CertificateBundles[]`
3. For each bundle, `c.Get()` the secret named `CertificateSecretRef.Name` in the ClusterDeployment's namespace
4. If found, call `updateSecret(ctx, c, secret, backupCredsClusterLabel, "certificatebundle", true)` — same helper already used by the other two functions, which is careful not to stomp on labels if one of the three qualifying labels is already present

This was a small, self-contained change (no new API dependency needed, already importing `hivev1`), compiled and unit-tested successfully. **Not merged** — see resolution below.

### UPDATE 2026-07-28 — QE feedback, resolved as expected behavior

Before merging the fix above, raised the design question with QE via Jira comment on ACM-38831: should we auto-detect and label these secrets (like assisted-install/metal3), or treat them as user-provided data requiring a manual label (like GitOps-created Hive admin-kubeconfig secrets)?

**QE's response (verbatim):**

> "the Hive CertificateBundles allow users to define custom certificate chains in a ClusterDeployment resource to inject trusted CAs into provisioned target clusters, hence those referenced secrets would be categorized as user-provided data and be handled manually. The same approach would be applied to other user custom data as well (such as manifestsConfigMapRef/manifestsSecretRef)."

**Decision: do NOT auto-detect.** Treat `certificateBundles`-referenced secrets the same as any other user-provided data — require the manual `cluster.open-cluster-management.io/backup` label, same as the documented GitOps-created-Hive-secret case. The same reasoning extends to `ClusterDeployment.Spec.ManifestsConfigMapRef`/`ManifestsSecretRef` (and by extension `SSHPrivateKeySecretRef`) — none of these should be auto-labeled by the operator; they're all first-class "bring your own resource" fields where the user is expected to know the resource needs the backup label, same as any other custom resource per the "How to include custom resources" guidance.

**Reasoning this holds up:**
- Consistent with the one existing precedent we already have for this exact category (GitOps Hive secrets — manual label required).
- Avoids coupling `cluster-backup-operator` to Hive's CRD internals for an open-ended, growing list of "reference to user secret" fields — `certificateBundles` today, `manifestsConfigMapRef`/`manifestsSecretRef`/`sshPrivateKeySecretRef` tomorrow. Auto-detecting one and not the others would just be inconsistent in the other direction.
- The drafted fix (`updateCertificateBundleSecrets()`) was reverted, not committed.

**Action items:**
- ACM-38831 should be resolved as "working as intended" / documentation gap, not a code defect.
- Recommend adding an explicit doc callout (README / business continuity guide) naming `certificateBundles`, `manifestsConfigMapRef`, and `manifestsSecretRef` secrets/configmaps as requiring the manual backup label — today's docs only call out the GitOps-kubeconfig case, not these.
- Customer-facing guidance: manually label the secrets referenced by these three fields with `cluster.open-cluster-management.io/backup: ""`.

---

## ACM-38832 — InfraEnv with both `ClusterRef` and `OSImageVersion` fails the assisted-service webhook on restore

**Confirmed: NOT a `cluster-backup-operator` bug.** Root cause is in `assisted-service`'s (Infrastructure Operator / MGMT team) admission webhook design; nothing in this repo can fix it directly.

### The webhook rule (upstream, verified via GitHub)

`infraenvvalidators.admission.agentinstall.openshift.io` is a validating webhook in `openshift/assisted-service`. Its **Create**-path rule is unconditional:

> "Either Spec.ClusterRef or Spec.OSImageVersion should be specified (not both)."

Source: [assisted-service PR #5569](https://github.com/openshift/assisted-service/pull/5569) (added `Create` to the webhook's watched operations) and [commit 36d3543](https://github.com/openshift/assisted-service/commit/36d3543acd3b54b30e2b8323f4201bded3f0ba65) (introduced the `OSImageVersion` field + this exact check).

```go
// webhooks/agentinstall/v1
if newObject.Spec.ClusterRef != nil && newObject.Spec.OSImageVersion != "" {
	message := "Either Spec.ClusterRef or Spec.OSImageVersion should be specified (not both)."
	...
	return &admissionv1.AdmissionResponse{ Allowed: false, ... }
}
```

### Why the customer's InfraEnv legitimately has both fields set

Per assisted-service's own documented workflow ([commit 3aed9fd](https://github.com/openshift/assisted-service/commit/3aed9fd5f7fc4152728ba76b8bc9ff45dcee57ff)):

> To add a host after an OpenShift upgrade, you need to update the existing InfraEnv CR (which was created with a `clusterRef`) by adding the `osImageVersion` field.

So having **both** fields set is a valid, supported end-state — but only reachable via **Update** on an InfraEnv that already exists and already has `ClusterRef` set (adding a worker after an OS upgrade). Even that Update path has extra guardrails: [PR #8818](https://github.com/openshift/assisted-service/pull/8818) added a check that the update is only allowed if the webhook can confirm (via a live client lookup) that the referenced `ClusterDeployment` is currently `Installed`.

### Why restore hits the Create-path rule

A Velero restore onto a new hub is, from the target API server's point of view, effectively a **Create** — the object does not exist there yet. The webhook's Create-path has no carve-out for "this combination is fine because it was reached legitimately via Update history on another cluster" — it unconditionally rejects Create with both fields set, full stop. There's no restore-ordering fix available here (e.g., restoring ClusterDeployment first, waiting for it to report Installed, etc.) because the rejection triggers on the Create operation type itself, independent of any other object's state.

### Cross-check against this repo

- `infraenv.agent-install.openshift.io` is only covered by the generic group inclusion `includedActivationAPIGroupsByName = []string{"agent-install.openshift.io"}` (`backup.go` line ~69) — there is no special-case handling, ordering, or field-stripping for InfraEnv anywhere in this repo.
- There IS a precedent pattern in this repo for exactly this class of problem: Hive's own creation webhook is bypassed for restored `ClusterDeployment`s via a label (`hive_label = "hive.openshift.io/disable-creation-webhook-for-dr"`, patched on by `updateHiveResources()` in `pre_backup.go`). Hive's webhook was presumably updated on Hive's side to honor that label and skip validation when present. **No equivalent bypass label exists for the InfraEnv webhook today** — confirmed nothing in `openshift/assisted-service`'s webhook code (per the PRs found) checks for any DR/restore-bypass annotation.

### Recommended path forward

This needs a code change in `assisted-service`, most plausibly one of:
- Add a bypass label/annotation to the InfraEnv webhook's Create-path check (mirroring Hive's `disable-creation-webhook-for-dr` pattern), and have `cluster-backup-operator` patch it onto InfraEnv objects the same way it does for ClusterDeployment — OR
- Have the webhook detect a Velero restore context (e.g., presence of `velero.io/backup-name` label, which Velero adds during restore) and relax the Create-path check in that case specifically.

Either fix has to land upstream in `assisted-service` / with the Infrastructure Operator team; recommend filing/tagging that team on ACM-38832 with this finding (rather than treating it as a cluster-backup-operator defect).

---

## What's needed if/when discussing with the customer or filing follow-ups

- [x] Exact webhook message and which field combination triggers it (verified against upstream source)
- [x] Confirmed the Create-vs-Update distinction in the webhook and why restore lands in the stricter Create path
- [x] Confirmed no code in `cluster-backup-operator` touches `CertificateBundle` secrets or InfraEnv fields today
- [x] Identified the existing `hive_label` bypass precedent as the template for a possible InfraEnv-side fix
- [x] Drafted, compiled, and unit-tested the `updateCertificateBundleSecrets()` fix for ACM-38831 — reverted after QE feedback (see update above)
- [x] Got QE input on ACM-38831 design question — resolved as expected/manual-label behavior, not a code bug
- [ ] Not yet done: live repro on a real assisted-service-backed cluster for ACM-38832 (this investigation was desk/code-only, no cluster access)
- [ ] Not yet done: confirm with Infrastructure Operator/MGMT team whether they'd accept a bypass-label approach or prefer detecting restore context another way for ACM-38832
- [ ] Not yet done: doc update naming `certificateBundles`/`manifestsConfigMapRef`/`manifestsSecretRef` as requiring manual backup labels

## Suggested short customer-facing summary

ACM-38831 (certificateBundles secrets) is expected behavior per QE — these are user-provided data (like `manifestsConfigMapRef`/`manifestsSecretRef`), so the referenced secret needs the `cluster.open-cluster-management.io/backup` label added manually, same as other custom/GitOps-created resources. ACM-38832 (InfraEnv webhook) is a design limitation in the assisted-service admission webhook, not something cluster-backup-operator can fix directly — needs to go to the Infrastructure Operator/MGMT team.

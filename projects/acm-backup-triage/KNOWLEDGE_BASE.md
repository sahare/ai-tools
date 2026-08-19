# ACM Backup & Restore - Knowledge Base

## What is the Cluster Backup and Restore Operator?

The cluster-backup-operator provides disaster recovery for Red Hat Advanced Cluster Management (ACM) hub clusters. It runs on the hub cluster and uses OADP/Velero to back up and restore hub configuration — managed clusters, policies, applications, credentials, and other hub resources.

It does **NOT** handle:
- Application DR on managed clusters (use OADP/Velero policies instead — see [issue #12](#12-application-data-backup-on-managed-clusters))
- Managed cluster availability
- Velero internals (that's the OADP team)

**Getting started:** Enable `cluster-backup` on the `MultiClusterHub` resource. This installs both the backup operator and the OADP operator in the `open-cluster-management-backup` namespace. Then create a `DataProtectionApplication` to connect to your S3 storage, and create a `BackupSchedule` to start backing up.

**GitHub:** https://github.com/stolostron/cluster-backup-operator
**Official docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index

## CRITICAL RULES (never violate these)

1. **NEVER recommend deleting ManagedClusters from any hub before or during a restore operation.** The restore handles state reconciliation. Deleting ManagedClusters while they are `Available` destroys workloads on managed clusters. The `disable-auto-import` annotation (or `ImportOnly` strategy) on the old hub prevents split-brain WITHOUT deleting anything. This is basic ACM knowledge.
2. **When reviewing customer DR playbooks**, always compare each step against the official documented procedure. Flag ANY deviation, especially deletions or detachments that aren't in the docs.
3. **Only delete ManagedClusters from the old hub if:** (a) restore is fully complete on the new hub, (b) clusters show `Unknown` on the old hub (meaning they've moved), and (c) you don't plan to failback to that hub.
4. **The docs explicitly say:** "If you want to restore the data to the backup after your recovery test completes, skip cleaning the resources."

5. **When advising on `cleanupBeforeRestore`, always default to the safest option.** For partial/incremental migrations or "move managed clusters" scenarios, ALWAYS recommend `cleanupBeforeRestore: None`. It's additive and non-destructive. Only recommend `CleanupRestored` for standard active/passive sync restores where the passive hub's data should mirror the active hub's backups. Never recommend `CleanupAll` without extreme justification.
6. **For "move managed clusters" repeated operations:** Step 0 (restore policies/apps/credentials) is cheap and safe with `cleanupBeforeRestore: None`. When in doubt, recommend running it again to pick up any delta from the source hub. Do NOT recommend skipping it unless you are certain nothing changed on the source hub — the risk of missing new policies outweighs the cost of a redundant restore.
7. **The `open-cluster-management-agent` and `open-cluster-management-agent-addon` namespaces** should be excluded from restores on a different hub. They contain hub-specific klusterlet credentials (`hub-kubeconfig-secret`). While these secrets typically don't have backup labels (and thus shouldn't appear in backups), always recommend excluding these namespaces as a safeguard in "move managed clusters" scenarios.

## Ownership Boundaries

| Component | Team | Slack Channel |
|-----------|------|---------------|
| BackupSchedule / Restore CRs, backup selection, collision detection, sync mode, cleanup, auto-import | **cluster-backup-operator** | #forum-acm-backupandrestore |
| DataProtectionApplication, BackupStorageLocation, Velero pod, Velero backup/restore execution | **OADP team** | #forum-oadp |
| MultiClusterHub, operator installation, cluster-backup chart deployment | **MCH/MCE team** | #forum-acm |
| ManagedServiceAccount, addon framework | **MCE/Foundation team** | #forum-acm |
| Managed cluster import/detach mechanics | **Foundation team** | #forum-acm |
| InfraEnv, AgentClusterInstall, `infraenvvalidators` admission webhook | **Infrastructure Operator / MGMT (assisted-service) team** | #forum-agent-install (verify channel name) |

## How Backups Work

The operator creates 5 Velero schedules when a `BackupSchedule` is created:

| Velero Schedule | What it backs up |
|-----------------|-----------------|
| `acm-credentials-schedule` | Secrets and ConfigMaps with Hive/ACM backup labels |
| `acm-resources-schedule` | ACM resources — policies, applications, placements |
| `acm-resources-generic-schedule` | User-labeled resources (`cluster.open-cluster-management.io/backup`) |
| `acm-managed-clusters-schedule` | Managed cluster activation data (ManagedCluster, ClusterDeployment, etc.) |
| `acm-validation-policy-schedule` | Short-lived heartbeat backup for cron validation |

Resources are backed up in two categories:
- **Passive data** — credentials, resources, policies, apps. Restoring these does NOT activate managed clusters on the new hub.
- **Activation data** — managed cluster resources. Restoring these makes managed clusters connect to the new hub.

## What Gets Backed Up

**Backed up by default (no label needed):**
- Resources from API groups: `*.open-cluster-management.io`, `*.hive.openshift.io`, `argoproj.io`, `app.k8s.io`, `core.observatorium.io`
- `agent-install.openshift.io` resources (in managed-clusters backup)
- ManagedCluster, ClusterDeployment, MachinePool, KlusterletAddonConfig, ManagedClusterAddon, Policies (root only), Placements, PlacementRules, PlacementBindings
- Secrets/ConfigMaps with labels: `cluster.open-cluster-management.io/type`, `hive.openshift.io/secret-type`, or `cluster.open-cluster-management.io/backup`

**NOT backed up by default (needs label):**
- Resources in excluded API groups: `internal`, `operator`, `work`, `search`, `admission.hive`, `proxy`, `action`, `view`, `clusterview`, `velero.io`
- Excluded CRDs: `clustermanagementaddon`, `backupschedule`, `restore`, `clusterclaim.cluster`, `discoveredcluster`
- User-created ConfigMaps/Secrets without backup labels
- Resources in the MCH namespace (unless labeled)
- AddonDeploymentConfig (excluded by default)
- Child/propagated policies (only root policies are backed up)
- `local-cluster` namespace resources

**How to include custom resources:** Add label `cluster.open-cluster-management.io/backup: ""` (use value `cluster-activation` if the resource should only restore during managed cluster activation)

**How to exclude a resource:** Add label `velero.io/exclude-from-backup: "true"`

**Note:** Secrets used by Hive `ClusterDeployment` are auto-labeled when created via the console UI. If created via GitOps, the `cluster.open-cluster-management.io/backup` label must be added manually.

**ACM-38831 — UPDATE 2026-08-04: reversed again, now fixed in code (was "expected behavior" per QE 2026-07-28, team lead overrode that and asked for the fix):** Secrets/configmaps referenced by name off a `ClusterDeployment` are now auto-labeled for backup in `updateHiveReferencedSecrets()` (`pre_backup.go`), covering `Spec.CertificateBundles[].CertificateSecretRef`, `Spec.PullSecretRef`, and `Spec.Provisioning.ManifestsSecretRef`/`ManifestsConfigMapRef`. Rationale for the reversal: these references are all discoverable directly off a resource we already back up (the ClusterDeployment itself), unlike truly-external user data — QE's "handle it like other user-provided data" argument was judged less important than closing a silent-data-loss gap. `Spec.BoundServiceAccountSigningKeySecretRef` was deliberately left OUT (private AWS STS signing key material — different risk profile than a cert bundle, open question raised with the team rather than auto-labeled). PR: [stolostron/cluster-backup-operator#1684](https://github.com/stolostron/cluster-backup-operator/pull/1684).
- **CodeRabbit caught a real gap during review:** the fix's `local-cluster` exclusion (added because `updateHiveResources` must never label `local-cluster`'s resources for backup — restoring them corrupts the target hub) only guarded the `ClusterDeployment` loop. The **separate, pre-existing `ClusterPool` loop** in the same function had no such guard — a `ClusterPool` sitting in the `local-cluster` namespace would still get its namespace's secrets labeled. Fixed by reusing the already-resolved `localClusterName` variable in that loop too, with a regression test. **General lesson:** when `local-cluster` needs to be excluded from a function, audit *every* loop/branch in that function, not just the one you're actively touching — the exclusion doesn't automatically propagate.
- Also fixed while implementing: `updateHiveResources` now fails closed (skips the whole reconcile cycle) if resolving `localClusterName` itself errors, rather than defaulting to an empty string that would silently bypass the exclusion check.
- **Prior "expected behavior" guidance below (customer-facing manual-label workaround) is now superseded for the three fields above** — they no longer need manual labeling once this PR ships. Manual labeling is still required for anything NOT in that list (e.g. `sshPrivateKeySecretRef`, `BoundServiceAccountSigningKeySecretRef`, GitOps-created Hive admin-kubeconfig secrets).

## BackupSchedule Phases

| Phase | Meaning | Common Causes |
|-------|---------|---------------|
| **New** | Velero schedules just created | Normal after creating BackupSchedule |
| **Enabled** | All Velero schedules running normally | Healthy state |
| **FailedValidation** | Configuration error | Invalid cron, no BSL, BSL unavailable, active Restore while schedule not paused, MSA CRD missing |
| **Failed** | Velero schedule creation error | Internal error creating Velero schedule objects |
| **BackupCollision** | Another hub writing to same storage | Two hubs sharing storage with active schedules, or passive hub ran restore activation |
| **Unknown** | Velero schedules not fully enabled | Velero pod not running, OADP misconfigured |
| **Paused** | User paused the schedule | `spec.paused: true` |

**Important behavior:** A non-paused BackupSchedule cannot coexist with an active Restore (any phase except Finished/FinishedWithErrors). A paused BackupSchedule can coexist with an active Restore. A completed Restore (Finished/FinishedWithErrors) does not block a BackupSchedule.

## Restore Phases

| Phase | Meaning | Common Causes |
|-------|---------|---------------|
| **Started** | Cleanup or initial restore in progress | Normal early phase |
| **Running** | Velero restores executing | Normal during restore |
| **Finished** | All restores completed successfully | Healthy completion, or activation completed |
| **FinishedWithErrors** | Partial failures | Velero `PartiallyFailed`, concurrent Restore/BackupSchedule active, invalid cleanupBeforeRestore value |
| **Error** | Hard failure | BSL unavailable, Velero restore `Failed`/`FailedValidation`, initialization error |
| **Enabled** | Passive sync active | `syncRestoreWithNewBackups: true` with MC=skip and creds/resources=latest, syncing periodically |
| **Unknown** | Velero restore status unclear | Velero pod issue |

**Important behavior:**
- Only one active Restore is allowed at a time. "Active" means any phase except Finished/FinishedWithErrors.
- Patching `veleroManagedClustersBackupName` from `skip` to `latest` on an Enabled Restore triggers activation. The phase transitions from Enabled → Started → Running → Finished.
- After activation completes (Finished), the sync stops — it does not return to Enabled.

## Cleanup Options (`cleanupBeforeRestore`)

| Value | Behavior |
|-------|----------|
| **None** | No cleanup. Use on a brand new hub or when restoring all resources for the first time. |
| **CleanupRestored** | Removes resources that were created by a **previous ACM restore** and are not in the current backup. Identifies them by the `velero.io/backup-name` label. Safe for passive hubs. **Recommended for most cases.** |
| **CleanupAll** | Removes **all** resources that could be part of an ACM backup, even if not created by a restore. **Use with extreme caution** — this deletes user-created resources too. |

**CleanupRestored detail:** For secrets/configmaps, requires the `velero.io/backup-name` label to exist AND point to a different backup than the current one. For dynamic resources, uses label selectors matching the backup's included resource kinds. Resources with `velero.io/exclude-from-backup: true` are never cleaned up. Resources in the `local-cluster` namespace and MCH namespace are excluded from cleanup.

**When to recommend each value:**
- `None` — "move managed clusters" scenarios, first restore on a new hub, incremental migrations, any scenario where you DON'T want to delete existing resources on the target hub
- `CleanupRestored` — standard active/passive activation restore, failback to primary, anywhere the target hub should mirror the source backup exactly
- `CleanupAll` — almost never; only for complete hub reset scenarios where ALL existing ACM data should be wiped before restore

**Common mistake:** Recommending `CleanupRestored` for "move managed clusters" — this can delete resources on Hub 2 that were created by a previous restore but aren't in the current backup (e.g., if a cluster was moved earlier and its resources got the `velero.io/backup-name` label).

## OADP Version Compatibility

| ACM Version | OADP Version |
|-------------|-------------|
| 2.13+ | 1.4 or stable channel (stable for OCP 4.19+) |
| 2.12 | 1.4 |
| 2.11 | 1.4 |
| 2.10.4 | 1.4 |
| 2.10 | 1.3 |
| 2.9.3 | 1.3 |
| 2.9 | 1.2 |
| 2.8.5 | 1.3 |
| 2.8 | 1.1 |

**Key rule:** Use the OADP version that ships with your ACM version. Do not upgrade OADP independently.

**Override:** Set this annotation on MCH **before** enabling cluster-backup:
```
installer.open-cluster-management.io/oadp-subscription-spec: '{"channel": "stable-1.4"}'
```

**Selection is automatic, not something the operator/team tracks per-hub (clarified by vbirsan,
2026-08-19):** the backup chart's OLM subscription simply points at the OADP `stable` channel. OLM
resolves which OADP version that channel means **based on the hub's own OCP version** at
install/upgrade time — there's no manual "pick the right OADP version" step or per-hub bookkeeping
on our side. The table above documents the resulting mapping for reference/support-case triage, it
is not something we (or customers) need to actively manage day to day.

**OADP ↔ Velero server version mapping** (what actually runs on the hub, via the `stable` channel):

| OCP version | OADP version | Velero version (server-side) |
|-------------|--------------|-------------------------------|
| 4.14–4.15 | 1.3 / 1.4 | v1.12 / v1.14 |
| 4.16–4.18 | 1.4 | v1.14 |
| 4.19–4.21 | 1.5 | v1.16 |
| 4.22–4.23 (~Q3 2026) | 1.6 | v1.18 |

**Separate, narrower gotcha this does NOT resolve — our own `go.mod` Velero dependency:**
`cluster-backup-operator`'s `go.mod` vendors `github.com/vmware-tanzu/velero` as a Go library, only
to get the `Backup`/`Restore`/`Schedule` API types used to *construct* those CRs in code. That
version is **independent of, and not auto-synced with**, whatever OADP/Velero version OLM's
`stable` channel actually installs on a given hub. E.g. as of Aug 2026 our `go.mod` is pinned to
Velero v1.16.2 (matches OADP 1.5 / OCP 4.19-4.21, the current default) — but once a hub moves to
OCP 4.22+ and auto-gets OADP 1.6/Velero 1.18 server-side, our operator binary keeps building CRs
using the older v1.16 API types. Usually harmless since Velero CRDs are additive across minors, but
a new *required* field or stricter validation in 1.18 could make our CRs fail — and our envtest
fixtures (`hack/crds/`) are also still pinned to the older CRD version, so CI wouldn't catch it
either. See also the "`main` → release-branch fast-forwarding" note below — as of Aug 2026, `main`
does **not** auto-propagate to `release-5.0`, so a `main` bump would need an explicit backport to
actually reach 5.0.

**RESOLVED (2026-08-19, #forum-acm-backupandrestore thread, sahare/vbirsan/Tesshu
Flower/Thuy Nguyen/msmigiel): ACM 5.0's actual OCP support range confirmed, decision made to bump
now, not hold.**
- Initial open question in the thread: does ACM 5.0 actually support OCP 4.22, or only OCP 5.0+
  (Tesshu Flower's assumption, guessing OCP 4.22 might only be a transient "during upgrade" state)?
- **Confirmed via an internal "ACM Upgrade to 5.0" planning chart** (support-matrix image, sourced
  from the HPSTRAT-30/ACM-5.0-MVP planning docs; the PDF's text layer loses the table grid on
  extraction — render it to an image and read pixel colors per cell if this needs re-verifying):
  **ACM 5.0 has full support (not upgrade-only) for OCP 4.20, 4.21, 4.22, 4.23, 5.0, and 5.1** (not
  5.2). Cross-confirmed independently by Thuy Nguyen citing msmigiel: "ACM 5.0 supports 4.22 / 4.23
  / 5.0 / 5.1." Tesshu's "upgrade-only" theory was incorrect — this is full support, not a
  transient upgrade state.
- **Practical conclusion (vbirsan):** since OADP's own version-to-OCP mapping means OADP 1.6
  (Velero v1.18) is what actually installs on OCP 4.22+, and ACM 5.0 supports OCP 4.22+, **OADP
  1.5/Velero v1.16 can be dropped from consideration for ACM 5.0 entirely** — there's no scenario
  where an ACM-5.0-supported hub runs OADP 1.5 without also being able to run 1.6.
- **Decision:** bump `go.mod`'s `github.com/vmware-tanzu/velero` to v1.18.x for `main`/ACM 5.0 now
  (not "hold until closer to when 5.0 claims 4.22 support" — that condition is already satisfied).
  This reverses the earlier "hold #1578/#1576" guidance above — those PRs (or a fresh equivalent
  bump) should now be pursued, not held. Also update `hack/crds/` envtest fixtures to the matching
  Velero 1.18 CRDs so CI actually exercises the new schema.
- **Still true and unaffected by this resolution:** the `main` → `release-5.0` fast-forwarding gap
  (see below) — bumping on `main` still needs an explicit backport PR to reach `release-5.0`.
- **Separately tracked, not resolved by this decision:** [ACM-42551](https://redhat.atlassian.net/browse/ACM-42551)
  (moving to the unstructured/dynamic Velero client to remove this whole class of go.mod-vs-runtime
  drift risk going forward) is still valid future work for 5.1+, independent of this immediate
  version bump.

## ImportOnly Strategy (ACM 2.14+ / MCE 2.9+)

The `ImportOnly` import strategy is critical for DR scenarios. It controls whether a hub cluster automatically re-imports managed clusters that become unreachable.

**With `ImportOnly` (default for new installs since MCE 2.9 / ACM 2.14):**
- Once a managed cluster has successfully joined and `ManagedClusterImportSucceeded` is True, the hub stops applying klusterlet manifests
- If the cluster later becomes Unknown (moved to another hub, or network issue), the hub will NOT try to re-import it
- Manual import is required to reclaim the cluster

**With `ImportAndSync` (default for upgraded hubs from pre-2.14):**
- The hub continuously synchronizes klusterlet manifests
- If a cluster becomes Unknown, the hub WILL try to reconnect it — causing conflicts in DR scenarios

**Official docs state:** *"Use the ImportOnly strategy for a hub cluster disaster recovery scenario where you want to prevent the initial hub cluster from recovering the managed clusters, if the initial hub cluster restarts unexpectedly after the managed clusters were moved to a different hub cluster."*

**Check current strategy:**
```bash
oc get configmap import-controller-config -n multicluster-engine -o yaml
```

**Set ImportOnly:**
```bash
oc -n multicluster-engine create configmap import-controller-config \
  --from-literal=autoImportStrategy=ImportOnly
```

**Include in backups (so restored hubs also use it):**
```bash
oc -n multicluster-engine label configmap import-controller-config \
  cluster.open-cluster-management.io/backup=true
```

**ALWAYS mention ImportOnly when discussing:** controlled failover, planned switchover, non-destructive DR testing, moving managed clusters, or any scenario where two hubs could compete for the same clusters.

## Controlled Failover / Planned Switchover

For planned maintenance, DR testing, or intentional site switches (not just disaster scenarios):

**Steps:**
1. **Ensure passive hub is synced** — Restore in `Enabled` phase with `syncRestoreWithNewBackups: true`
2. **Pause backups on primary** — Set `spec.paused: true` on BackupSchedule (prevents backup collision)
3. **Shut down primary hub** (or ensure ImportOnly is set if keeping it running for DR testing)
4. **Activate on passive** — Patch Restore: `veleroManagedClustersBackupName: latest`
5. **Delete the Restore** on the new active hub after activation completes
6. **Create BackupSchedule** on the new active hub

**For non-destructive DR testing (primary stays running):**
- ACM 2.14+: Set `ImportOnly` strategy → primary won't reclaim clusters
- ACM < 2.14: Add `import.open-cluster-management.io/disable-auto-import: ''` annotation to all ManagedClusters on primary
- Pause BackupSchedule on primary before activating on secondary

**Failback to original primary:**
1. On secondary (current active): Set `ImportOnly` strategy or add `disable-auto-import` annotation to all ManagedClusters
2. Create BackupSchedule on secondary, wait for at least one successful backup
3. Pause backups on secondary
4. Restore on original primary with `cleanupBeforeRestore: CleanupRestored`
5. **Important:** For imported (non-Hive) clusters, MSA auto-import will likely fail because the token was invalidated when spokes connected to the secondary during failover. Manual reimport with fresh spoke credentials is required (see issue #5 below).
6. Re-enable BackupSchedule on original primary
7. Re-enable passive sync on secondary

**CRITICAL — DO NOT delete ManagedClusters from any hub before or during restore:**
- **NEVER delete ManagedClusters from the source/DR hub before restoring on the target hub.** The restore process handles state reconciliation — deletion is not needed and causes damage.
- Deleting a ManagedCluster while status is `Available` triggers cleanup on the spoke (removes addons, ManifestWorks, apps). For Hive clusters, it also triggers deprovisioning (infrastructure destruction).
- The docs explicitly state: "If you want to restore the data to the backup after your recovery test completes, **skip cleaning the resources**" (section 1.1.8.3).
- Cleanup is ONLY appropriate AFTER restore is complete AND clusters have successfully moved to the new hub AND their status shows `Unknown` on the old hub.
- Even then, cleanup is optional — not required for the restore to work.
- If ArgoCD manages ManagedCluster CRs, deleting them will fail anyway (ArgoCD recreates them via sync), causing split-brain.
- **When reviewing customer playbooks:** ALWAYS flag any step that deletes ManagedClusters before restore. This is a dangerous anti-pattern.

**Docs:** Business Continuity guide, sections "Restoring activation resources", "Backup Collisions", "Restoring data to the initial hub cluster"

## Restore Is a Soft Reconnect, Not a Detach/Reattach

**Source:** internal Slack thread, 2026-07-24, jbanerje/Subbarao Meduri raising an Observability-addon concern, answered by Valentina Birsan (vbirsan). Cross-team architectural clarification, not customer-specific — kept here since it directly informs how we should describe restore/activation behavior to customers and how addon teams should reason about DR events.

**The question:** does ACM backup/restore put managed clusters through the same detach → reattach cycle as a manual `oc delete managedcluster` + re-import? A traditional detach cleans up spoke-side state (policies, ManifestWork-deployed resources, addon config) — which would be far more invasive than customers doing a "planned failover" would expect, and could cause disruptive side effects for addons that react to detach events (e.g., the Observability addon touching the CMO ConfigMap and restarting spoke Prometheus).

**Answer (confirmed architecture, not the detach path):**
- Activation restore on the new hub restores `ManagedCluster`, `ManagedClusterAddOn`, `KlusterletAddonConfig`, etc. as data — it does **not** run the detach/cleanup finalizer logic that a real `ManagedCluster` deletion would trigger.
- The import/MSA auto-import mechanism's role on the spoke is **intentionally narrow**: it only gets/updates the `bootstrap-hub-kubeconfig` secret on the spoke. (This is the same secret referenced in the ACM-34619/ACM-38012 work-agent race we already have documented above — reinforces that `bootstrap-hub-kubeconfig` is the single, minimal point of contact for hub redirection.)
- The klusterlet then re-registers to the new hub using that updated bootstrap kubeconfig (new CSRs, new hub kubeconfig) — this is a **re-registration**, not a teardown-and-reimport.
- **There is no detach-finalizer path in the restore flow that tears down addons, policies, or custom resources on the spoke.** Any cleanup that happens is scoped to the *hub* side (see `CleanupRestored`/`CleanupAll` in `restore_post.go`), not the spoke.
- **Implication for addon teams:** each addon is individually responsible for detecting "my hub's identity/fingerprint changed" and reconciling (e.g., re-registering with the new hub) — the restore process does not do this for them generically. Per vbirsan, the application-addon was previously *missing* this re-registration step and was fixed by Xiangjing Li. Other addons (e.g., Observability, per Subbarao's original question) should verify they handle this "soft reconnect" signal correctly and don't assume a full detach/reattach semantics that would justify actions like restarting spoke Prometheus.
- **Documentation gap noted in the thread:** current external docs only describe *how MSA auto-import works*, not this broader "restore is a soft reconnect, addons must react on their own" architecture point — Subbarao asked and vbirsan confirmed this low-level detail isn't spelled out for customers or addon teams today.
- **Reference:** [README — Automatically connecting clusters using ManagedServiceAccount](https://github.com/stolostron/cluster-backup-operator#automatically-connecting-clusters-using-managedserviceaccount)

**Relevance to the ACM-38215 MSA ownerRef bug (2026-07-24, see below):** this clarifies that the *only* spoke-side mechanism restore relies on is the narrow `bootstrap-hub-kubeconfig` update — separate and upstream from the *hub-side* `auto-import-account` token secret refresh problem. The two are related (both are part of "how a spoke reconnects after restore") but are different failure surfaces: one is spoke-side kubeconfig routing (work-agent race, ACM-34619/38012), the other is hub-side MSA token refresh permissions (ACM-38215).

## Argo CD / ApplicationSet DR Considerations

When the hub runs Argo CD ApplicationSets (especially the ACM-Argo CD pull model), DR has additional risks due to cascade deletion chains.

**What's backed up automatically (no label needed):**
- Applications, ApplicationSets, AppProjects, ArgoCD CR — all in `argoproj.io`, which is in `includedAPIGroupsByName`
- GitOpsCluster — in `apps.open-cluster-management.io`
- ManagedServiceAccount — in `authentication.open-cluster-management.io`

**What NEEDS the backup label:**
- Argo CD repo credential Secrets (`argocd.argoproj.io/secret-type: repository`)
- Argo CD cluster Secrets (`argocd.argoproj.io/secret-type: cluster`)
- Argo CD ConfigMaps (`argocd-cm`, `argocd-rbac-cm`, `argocd-ssh-known-hosts-cm`, `argocd-tls-certs-cm`)
- These are core `v1` resources in `openshift-gitops` namespace — need `cluster.open-cluster-management.io/backup` label

**Cascade deletion risk (Chain 4 — hub temporarily unavailable):**
```
Hub goes down (upgrade or DR failover)
  → Hub comes back / new hub activates
    → Managed clusters appear unreachable during reconnection window
      → Placement de-selects clusters (no/short toleration)
        → ApplicationSet removes Applications for those clusters
          → Cascade-delete of workloads (VMs, etc.) on managed clusters
```

**Protection layers (defense in depth):**
1. `preserveResourcesOnDeletion: true` on ApplicationSets (both AppSet-level and template-level) — prevents cascade delete even if Applications are removed
2. Placement tolerations with explicit `tolerationSeconds` (e.g., 14400 = 4 hours) — buys time during hub restart/failover reconnection window
3. ValidatingAdmissionPolicy on critical namespaces (OCP 4.15+) — blocks all deletions in protected namespaces

**Key point for DR:** `preserveResourcesOnDeletion` and Placement tolerations should be configured BEFORE disaster occurs. They are DR prerequisites, not just deletion protection.

## Common Customer Issues and Triage

### 1. "Restore stuck in Error after temporary BSL outage"
**Category:** Known limitation
**Symptoms:** syncRestoreWithNewBackups: true, BSL went down temporarily, now back but Restore stays in Error
**Root cause:** When BSL is unavailable, Velero restores fail with FailedValidation. The controller only syncs when phase is Enabled (code: `sync := isValidSync && restore.IsPhaseEnabled()`), but `setRestorePhase()` sets it to Error on any Velero failure — preventing auto-recovery.
**Workaround:** Delete the failed Velero restore objects:
```
oc -n open-cluster-management-backup get restores.velero.io
oc -n open-cluster-management-backup delete restore.velero.io <failed-restore-name>
```
After deletion, the controller will create new Velero restores on the next sync interval and transition back to Enabled. To speed up recovery, temporarily reduce `restoreSyncInterval`.
**Status:** Enhancement proposed (EnabledWithErrors phase).

### 2. "BackupSchedule in BackupCollision"
**Category:** Configuration issue
**Symptoms:** BackupSchedule shows BackupCollision phase
**Root cause:** The controller compares the `cluster.open-cluster-management.io/backup-cluster` label on the latest `acm-resources-schedule` backup against this hub's cluster ID. If they don't match, another hub wrote the latest backup. Two scenarios:
  - Two hubs have active BackupSchedules writing to the same storage location
  - A passive hub ran managed cluster activation while this hub's schedule was active
**Resolution:** 
  - Ensure only ONE hub has an active BackupSchedule per storage location
  - Delete the BackupSchedule on the wrong hub, create a new one on the correct hub
  - Check `status.lastMessage` for which cluster ID is conflicting
**Note:** If this hub ran a managed-clusters restore AFTER the foreign backup, collision is bypassed (DR failback scenario).

### 3. "BackupSchedule in FailedValidation"
**Category:** Configuration issue
**Check these in order:**
  1. Is the cron expression valid? (`spec.veleroSchedule`)
  2. Does a BackupStorageLocation exist? (`oc get bsl -n open-cluster-management-backup`)
  3. Is the BSL Available? (check BSL status phase)
  4. Is there an active Restore running? (schedule cannot run while restore is active unless schedule is paused)
  5. Is `useManagedServiceAccount: true` but MSA CRD not installed?
**Error messages to look for:**
  - "Schedule must be a non-empty valid Cron expression"
  - "velero.io.BackupStorageLocation resources not found"
  - "Backup storage location is not available"
  - "Restore resource X is currently active"
  - "UseManagedServiceAccount option cannot be used"

### 4. "Restore in FinishedWithErrors"
**Category:** Could be config or issue
**Check these:**
  1. Is another Restore or BackupSchedule active? (only one active Restore allowed — second gets FinishedWithErrors with "currently active" message)
  2. Is `cleanupBeforeRestore` valid? (must be `None`, `CleanupRestored`, or `CleanupAll`)
  3. Check `status.lastMessage` for Velero `PartiallyFailed` — some resources may fail to restore but overall restore works
  4. Velero PartiallyFailed is often **normal** for empty backup files (no resources matched the selector in `acm-resources-generic-schedule`)

### 5. "Managed clusters not reconnecting after restore"
**Category:** Expected behavior / configuration
**Key points:**
  - Managed clusters reconnect at **activation time** only — when `veleroManagedClustersBackupName` is set to `latest`
  - Passive sync (`veleroManagedClustersBackupName: skip`) does NOT activate clusters — this is by design
  - **Hive-created clusters** (via ClusterDeployment) reconnect automatically because their kubeconfig is backed up
  - **Imported clusters** need either:
    - `useManagedServiceAccount: true` on the BackupSchedule (auto-import)
    - Or manual creation of `auto-import-secret` under each managed cluster namespace
  - Check `status.messages` on the Restore for per-cluster import details
  - Non-OCP imported clusters (e.g., EKS) need `managedClusterClientConfigs.url` set on the ManagedCluster resource for auto-import to work
  - If MSA token expired before restore, auto-import fails for that cluster (check Restore status messages)
  - **Failback scenario (round-trip failover/failback):** MSA auto-import will ALWAYS fail on failback for imported clusters. When the spoke connected to the passive hub during failover, the passive hub recreated the `auto-import-account` ServiceAccount on the spoke (new UID). The token in the backup references the old SA UID — Kubernetes rejects it with "Unauthorized" even though the JWT hasn't expired. This is a known limitation.
    - **Fix:** Manual reimport with fresh credentials (kubeconfig or token from the spoke)
    - **Diagnostic:** `oc --server=<spoke-url> --token=<token-from-auto-import-secret> --insecure-skip-tls-verify get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent` — if unauthorized, the SA was invalidated
    - **Prevention:** Before failback, validate the token from the backup is still valid on the spoke. If not, create a fresh backup on the passive hub after MSA token refresh.
    - **Confirmed occurrences:**
      1. Cristian Ungureanu (OCP 4.20.18, ACM 2.16.0), June 2026 — active/passive round-trip on `managed-cluster-dr-ocp44` and a second cluster. Error: `AutoImportSecretInvalid ... apply resources error: Unauthorized`. Token JWT `exp` was still days away — proved not a real expiry. Resolved with manual `auto-import-secret` recreation (kubeconfig or token+server). Full writeup: `acm-active-passive-failback-auto-import-resolution.md` (not yet added to this repo — ask sahare for a copy if needed).
      2. Jorge Lasquinha (#forum-acm-backupandrestore, ACM 2.14), July 2026 — DR lab test with two managed clusters, ARO (`z6hs10`) and AKS (`z6hs11`). z6hs10 reconnected automatically on every failback cycle; z6hs11 failed every time with `Ignoring MSA access token... no longer valid!`. This was their first full round-trip failover+failback test (earlier tests only exercised failover), consistent with the failure being scoped to failback specifically. Confirmed manually: testing the token from the previously-created (MSA-derived) `auto-import-secret` directly against z6hs11 returned **`Unauthorized`** — not an expiry error — matching the SA-UID-invalidation signature exactly (a real expired-JWT would fail differently). Recreating the `auto-import-secret` from a fresh spoke kubeconfig fixed reconnection.
    - **RETRACTED heuristic:** earlier note here claimed "check Hive vs imported, non-OpenShift platforms are the likely failure point" — **this was proven wrong** by occurrence #2 follow-up: `oc get clusterdeployment -n z6hs10` returned no resources, i.e. z6hs10 (ARO) is **also** an imported, non-Hive cluster (ARO is SRE-managed, never Hive-provisioned) yet it reconnects on every failback cycle while z6hs11 (AKS) fails every time. So Hive-vs-imported does NOT explain a per-cluster split when both clusters are non-Hive. Don't repeat this heuristic.
    - **CONFIRMED root cause of the z6hs10-vs-z6hs11 split (code-verified, not speculative):** the differentiator is not the cluster platform — it's whether an `auto-import-secret` **already existed** in the cluster's namespace before restore, and it wasn't one we created. z6hs10 is also used as a GitOps cluster and is the *only* one of the two with a pre-existing `auto-import-secret` in its namespace (confirmed by Jorge, July 2026). Code path in `postRestoreActivation()` (`controllers/restore_post.go`):
      1. Before creating a fresh secret, the controller only **deletes** an existing `auto-import-secret` if it carries our own label `cluster.open-cluster-management.io/restore-auto-import-secret: "true"` (`activateLabel`) — i.e., only if *we* created it during a prior restore activation (`restore_post.go` ~L664-679).
      2. If a secret exists **without** that label (e.g., one created out-of-band by GitOps/ArgoCD cluster registration, or manually), the controller does NOT touch it.
      3. It then calls `createAutoImportSecret()`, which does a plain `c.Create()` (`restore_post.go` ~L712-738) — **not** an upsert. If a secret with that name already exists, `Create()` fails with `AlreadyExists`. The error is only logged (`"Failed to create auto-import-secret for (%s)"`) — it is **not** surfaced as a hard restore failure, and the old secret is left completely untouched.
      4. Net effect: on z6hs10, our (SA-UID-invalidated) MSA token is silently **never written** — the import-controller keeps using whatever was already sitting in the pre-existing `auto-import-secret`, which still works. On z6hs11, no pre-existing secret exists, so our fresh MSA-derived secret gets created and used — and that's the one that fails the SA-UID check.
      5. This also directly answers "does MSA handle reconnection without needing auto-import-secret?" — **no**. MSA is only the token *source*; our controller's whole mechanism for auto-import IS writing that token into `auto-import-secret`. There's no separate/independent MSA-based reconnection path.
      6. This also explains why increasing `managedServiceAccountTTL` won't help z6hs11: TTL only affects token *time* validity, not the SA-UID-identity mismatch, and z6hs10's success has nothing to do with TTL — it succeeds because our controller's write attempt is silently rejected, preserving separate working credentials.
      7. Why the first test(s) succeeded (Monday/Tuesday) then later ones failed: the SA-UID mismatch only manifests after a **round trip** (failover then failback). The very first failover+failback cycle backs up/restores tokens tied to the SA UID that still matches; only after clusters re-register during failover does the SA get recreated with a new UID, invalidating tokens captured in *earlier* backups used on a later failback.
    - **Practical implication / workaround for scale:** pre-staging a persistent, non-MSA `auto-import-secret` (e.g. a long-lived admin kubeconfig/token, refreshed by the customer's own automation, not derived from the rotating `auto-import-account` MSA) in each managed cluster's namespace on the DR hub makes that cluster immune to this failure. This could be scripted per-cluster instead of manual reimport after every failback.
    - **FALSIFIED sub-theory — GitOps registration does NOT create/preserve the persistent secret:** Jorge tested this directly (July 2026) — added z6hs11 to the same `GitOpsCluster`/`Placement` used by z6hs10, confirmed Argo sync was `Successful`, then ran the same DR round-trip. Result: z6hs11 still went to `Pending Import` with **no** `auto-import-secret` created by GitOps/Argo at all — identical failure to before. So `GitOpsCluster` registration itself does not write/maintain an `auto-import-secret` as part of its normal flow. This means z6hs10's persistent secret is **not** a byproduct of "being a GitOps cluster" — its origin remains unexplained (most likely a leftover from an earlier manual/one-time action on that specific cluster, unrelated to GitOps). The core mechanism (pre-existing secret blocks our controller's `Create()`, so whatever is already there — valid or stale — determines the outcome) still stands; only the *cause* of z6hs10 having one in the first place is still an open question.
    - **IMPORTANT — version-specific code difference, ACM 2.14 vs 2.15+:** Jorge is on ACM 2.14. Verified via `git log`/branch diff that `release-2.14` predates commit `624d6c69` ("Improve selection of MSA secret on post restore", merged Sept 2025, first in `release-2.15`). This is a materially different code path:
      - **2.14 logic** (`findValidMSAToken` in `controllers/utils.go`, message literally `"Skip MSA access token for secret (%s:%s) no loger valid!"` — matches the KCS article's typo exactly, confirming this is the exact code path Jorge is hitting): iterates MSA secrets **one at a time**, checks only that **single** secret's `expirationTimestamp` annotation, and **skips creating `auto-import-secret` entirely** (no attempt at all) if the annotation says expired — it does NOT fall back to trying anyway. Contrast with 2.15+'s `selectValidMSASecret`, which always returns *some* candidate (even one with a stale/missing annotation) specifically because annotations are known to lag real MSA rotation.
      - **Practical implication:** on 2.14, if the specific MSA secret evaluated first for a cluster shows (or appears to show, since annotations can lag) an expired annotation, our controller may **never attempt** to write a fresh `auto-import-secret` at all — this is a distinct, additional failure mode from the SA-UID-mismatch issue, specific to pre-2.15 code, and not present in the KCS's or our own newer analysis of `main`.
      - **This also sharpens the `auto-import-secret`-blocking mechanism:** the MSA secrets (`auto-import-account`, `auto-import-account-pair`, filtered by label `authentication.open-cluster-management.io/is-managed-serviceaccount`) are a **completely separate object** from the final `auto-import-secret` that gets created/consumed for reconnection. Jorge confirmed the *pre-existing* `auto-import-secret` in z6hs11's namespace (on the source hub) carried **OADP/ACM backup labels** — meaning it is restored by Velero **independently of MSA and independently of our controller's activation logic**, purely because it's a normal labeled Secret in the backup. Since it lacks our own `activateLabel`, our controller never deletes it, and `createAutoImportSecret()`'s plain `Create()` then fails silently either way — regardless of whether a valid MSA token was even found. This means the `Unauthorized` token Jorge tested from "the previous auto-import-secret" was very plausibly **the old Velero-restored secret itself**, not a freshly MSA-derived one — i.e., our controller may never have gotten the chance to write anything for z6hs11 at all, on either the current OR older code path.
      - **Actionable next diagnostic (not yet confirmed):** ask Jorge to check whether z6hs10's *current* `auto-import-secret` also carries a `cluster.open-cluster-management.io/backup` (or similar backup) label. If yes, this would fully close the loop: both clusters have the identical blocking mechanism (a labeled, Velero-restored secret pre-empting our controller's write); the only difference is whether that persisted secret's content happens to still be valid — which is a matter of that specific secret's history/age, unrelated to GitOps, Hive, or platform.
      - **Also worth checking:** exact ACM/backup-operator patch version (`oc get csv -n open-cluster-management-backup`) to confirm whether Jorge's specific 2.14.x build includes any backport of the 2.15 MSA-selection improvement (backports of targeted fixes do happen), since that changes which failure mode above is actually in play.
    - **Possible product gap worth flagging (not yet filed):** `createAutoImportSecret()` should arguably use an upsert (`Create` then `Update` on `AlreadyExists`, or `CreateOrUpdate`) instead of silently failing when a foreign secret is present, so that a stale foreign secret can't accidentally "win" over a legitimate need to refresh credentials, and so that the log at least distinguishes "skipped because a foreign secret already provides valid access" from "failed to create for an unrelated reason."
    - **Note:** This only affects imported clusters. Hive-created clusters use ClusterDeployment admin kubeconfig and don't rely on MSA tokens.
    - **Official KCS article:** [7039710 — "RHACM Managed Cluster restoration fails with 'Skip MSA access token for secret (cluster-name) no loger valid!'"](https://access.redhat.com/solutions/7039710). Its guidance: set `managedServiceAccountTTL` to ~2.5x `veleroTtl` (e.g. veleroTtl=120h → managedServiceAccountTTL=300h) to guarantee token validity for a given backup at restore time. **This does NOT fix the round-trip failback SA-UID-invalidation issue** — occurrence #2 followed this guidance exactly (veleroTtl=336h, managedServiceAccountTTL=504h, fresh BackupSchedule) and still hit the identical failure on z6hs11. The KCS TTL guidance addresses token *time* validity; the failback problem is an identity/UID invalidation problem that TTL tuning cannot fix.
    - **NEW — live-cluster-confirmed root cause, 2026-07-24 (supersedes the "pre-existing secret" theory as the *primary* explanation):** got temporary direct `oc` access to both of Jorge's hubs. Full raw evidence, commands, and outputs are in [`incidents/jorge-z6hs11-msa-ownerref-2026-07-24.md`](incidents/jorge-z6hs11-msa-ownerref-2026-07-24.md) (kept as a standalone record since the clusters may be torn down). Finding: the `ManagedServiceAccount` token secrets `auto-import-account`/`auto-import-account-pair` come back from every Velero restore with **empty `ownerReferences`**, and the `managed-serviceaccount` addon controller then permanently fails to refresh them with `TokenReported=False reason=TokenReportFailed msg="...cannot set an ownerRef on a resource you can't delete..."`. This is **not** a one-off — confirmed identically on both hubs, for both z6hs10 and z6hs11. Other MSA-backed secrets on the same clusters (`application-manager`, `klusterlet-addon-workmgr-log`) have healthy populated ownerReferences and refresh fine, isolating the bug specifically to the two objects our own `createMSA()` manages. **This reframes the whole z6hs10-vs-z6hs11 story:** both clusters' MSA tokens are equally broken (frozen, non-refreshing) after restore; z6hs10 only *looks* fine because its last-refreshed token (before the bug's effects accumulated) happens to still be time-valid until 2026-07-28, while z6hs11's had already expired. z6hs10 is expected to hit the identical `Pending Import` failure once its token also expires, unless this is fixed first — this is a **ticking time bomb**, not a resolved-differently case. Root cause is suspected to be in either the `managed-serviceaccount` addon-framework (Foundation/MCE team) not re-establishing ownership after Velero restore, or possibly our own restore-item-action for these two objects — needs code-level confirmation from Foundation before filing, but evidence is solid enough to file now given cluster availability risk. Checked and ruled out against [ACM-31624](https://redhat.atlassian.net/browse/ACM-31624), [ACM-34619](https://redhat.atlassian.net/browse/ACM-34619), and [ACM-38012](https://redhat.atlassian.net/browse/ACM-38012) — none document this ownerRef mechanism; this is a new, previously-undocumented bug.
    - **JIRA tracking:** [ACM-35067](https://redhat.atlassian.net/browse/ACM-35067) — "Document failback limitation: MSA auto-import fails for imported (non-Hive) clusters after round-trip failover." Scoped as a **documentation** ticket, not a code fix, as of July 2026. (Tonight's ownerRef finding above is a distinct, more fundamental code bug that ACM-35067 does not cover — a new Jira should be filed for it, tagging Foundation/MCE.)
    - **Scale concern (occurrence #2):** customer has ~40 AKS clusters (Azure) plus a separate ACM/EKS environment (AWS) — manual per-cluster reimport after every failback does not scale to fleets this size and raises product-DR-capability concerns when communicated to customers. No engineering fix exists yet (see JIRA above); mitigations to suggest: (a) script/automate the reimport step (batch-regenerate `auto-import-secret` from stored per-cluster admin kubeconfigs post-restore) rather than doing it manually per cluster; (b) note that only the failback (return) leg is affected — forward failover reconnects automatically via MSA; (c) consider whether round-tripping back to the original primary is required at all, vs. promoting the DR hub to the new steady-state primary, if the customer's DR requirements allow it.
  - **Work-agent timing race (ACM-34619):** Not Hive-specific but more likely with Hive clusters. The work-agent on the spoke reconciles ManifestWorks every ~4 minutes. If it fires shortly after the bootstrap secret is updated by the restore hub (while still connected to the old hub with valid certs), it fetches ManifestWorks from the old hub — which contain a bootstrap secret pointing back to the old hub. The work-agent detects "drift" and overwrites the bootstrap secret back to the old hub URL. Registration-agent then connects to the old hub instead of the restore hub. Failure rate: ~5-6%.
    - **Symptoms:** Cluster shows `Unknown` on restore hub, may show `Available` on backup hub despite `disable-auto-import` annotation
    - **Root cause:** Work-agent periodic reconcile (4 min interval) overwrites bootstrap secret before registration-agent restarts
    - **Fixed in:** PR #1109 in `managedcluster-import-controller` — when `disable-auto-import` annotation is set, ManifestWorks are marked ReadOnly so work-agent cannot overwrite resources. Ships in ACM 2.17+.
    - **Workaround (pre-fix versions):** Shut down ACM on the backup hub before restoring on the new hub, or if cluster reconnects to wrong hub, delete ManagedCluster on the wrong hub (ensure status is `Unknown` first) then re-run restore
  - **Import controller skip logic (ACM-31624):** For imported clusters, if `ManagedClusterImportSucceeded` condition is `True` on the restored ManagedCluster, the import controller skips auto-import when using `ImportOnly` strategy. But the cluster is actually pointing to the old hub. The auto-import-secret (created by our post-restore logic) is not checked before the skip decision. Fix: PRs in `stolostron/managedcluster-import-controller` (#1107, #1108) — check for `backupRestore`-labeled auto-import-secret BEFORE the importSucceeded skip logic.
    - **Note on timing:** Our backup operator creates the `auto-import-secret` in `postRestoreActivation`, which runs ONLY after all Velero restores reach `Finished` phase. The import controller starts processing restored ManagedClusters immediately. This gap is expected — the import controller re-reconciles and picks up the secret on subsequent loops.
**Docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

### 6. "What gets backed up? My resource X is not restored"
**Category:** Informational
See the [What Gets Backed Up](#what-gets-backed-up) section above for the complete list.
**Common missed resources:**
  - Secrets used by GitOps-created ClusterDeployments — need manual `cluster.open-cluster-management.io/backup` label
  - Search CRs in MCH namespace — need the backup label to be included in generic backup
  - AddonDeploymentConfig — excluded by default, needs backup label if user wants it preserved
  - Resources in custom namespaces from non-ACM API groups — need the backup label

### 7. "Velero pod OOM / restore taking too long"
**Category:** OADP team / resource tuning
**Symptoms:** Large hub (1000+ managed clusters), Velero pod OOM kills, restores timeout
**Resolution:** Increase Velero pod resource limits via DataProtectionApplication:
```yaml
spec:
  configuration:
    velero:
      podConfig:
        resourceAllocations:
          limits:
            cpu: "2"
            memory: 1Gi
          requests:
            cpu: 500m
            memory: 256Mi
```
**Scale reference (ACM 2.15, 3500+ SNO clusters):**
- Backup: ~6 min total, ~111 MB
- Restore (CleanupRestored): ~12 min
- Recommended: cpu=4, memory=8Gi for very large hubs
**Redirect to:** OADP team if Velero-specific tuning needed

### 8. "How to set up active/passive hub clusters"
**Category:** Informational / setup guidance
**Prerequisites:**
  - Both hubs: same ACM version, same OCP version, same namespace layout
  - Both hubs: same additional operators installed (GitOps, Ansible, cert-manager, etc.)
  - Both hubs: `cluster-backup` enabled on MultiClusterHub
  - Both hubs: DataProtectionApplication pointing to the same storage location (or replicated storage)
**Steps:**
  1. Create BackupSchedule on primary hub only
  2. Create passive sync Restore on secondary hub:
     ```yaml
     spec:
       syncRestoreWithNewBackups: true
       restoreSyncInterval: 10m
       cleanupBeforeRestore: CleanupRestored
       veleroManagedClustersBackupName: skip
       veleroCredentialsBackupName: latest
       veleroResourcesBackupName: latest
     ```
  3. When disaster strikes: edit the Restore to set `veleroManagedClustersBackupName: latest`
  4. Wait for Finished, then create BackupSchedule on the new active hub
**Important:** Do not create a second Restore — edit the existing one. The webhook enforces a two-step workflow: create with `skip`, then update to `latest`.
**For planned/controlled failover:** See the [Controlled Failover / Planned Switchover](#controlled-failover--planned-switchover) section above. Key additions: pause BackupSchedule first, ensure ImportOnly strategy is set (ACM 2.14+).
**For Argo CD pull-model architectures:** See [Argo CD / ApplicationSet DR Considerations](#argo-cd--applicationset-dr-considerations). Ensure `preserveResourcesOnDeletion` and Placement tolerations are configured before disaster.
**Blog:** https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes
**Blog:** https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup

### 9. "OADP version compatibility"
**Category:** Informational
See the [OADP Version Compatibility](#oadp-version-compatibility) table above.
**Override annotation:** `installer.open-cluster-management.io/oadp-subscription-spec`
**Note:** OADP CRDs are cluster-scoped — you cannot have multiple versions on the same cluster. All namespaces must use the same version.
**Redirect to:** OADP team for OADP-specific bugs

### 10. "Moving managed clusters between two non-identical hubs"
**Category:** Architecture guidance — COMMON QUESTION
**Key insight:** If customer has two independent ACM hubs each managing their own clusters and wants DR between them, this is a **"move managed clusters"** scenario, NOT a standard active/passive restore.

**Why full restore is wrong:**
- The two hubs are NOT identical — different apps, policies, resources
- Full restore would overwrite existing resources on hub2 or create new ones
- `cleanupBeforeRestore: CleanupAll` would remove hub2's own managed clusters
- Even `CleanupRestored` is risky if a prior restore was done (hub2's clusters could get tagged with `velero.io/backup-name` and cleaned up)
- Policies/placements from hub1 could unexpectedly apply to hub2's clusters

**Correct approach:** Use the "move managed clusters" procedure — only move activation data, not all hub content. Both hubs MUST have identical policies/apps for any placement that could match moved clusters.

**Uncontrolled failover (hub1 dies without preparation):**
- ACM 2.14+ has `ImportOnly` import strategy (default on new installs) — prevents the hub from re-importing clusters it already knows about. See [ImportOnly Strategy](#importonly-strategy-acm-214--mce-29) section.
- For ACM < 2.14, there is no workaround for uncontrolled DR

**Strong recommendation:** Full active/passive with identical hubs is the supported, well-tested path.
**Cleanup is optional** — the doc says "you can choose to clean up."
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

### 10b. "Incremental/repeated cluster migration (move one cluster at a time)"
**Category:** Architecture guidance — NOT OFFICIALLY TESTED
**Context:** Customer moves cluster A from Hub 1 to Hub 2 one week, then wants to move cluster B the next week. Hub 1 stays active throughout.

**Key insight:** The blog's "move subset" workflow is designed as a single operation, not for repeated use over time. However, it CAN work incrementally with proper understanding:

**Step 0 (policies/apps/credentials):**
- NOT cluster-specific — restores ALL user resources from the latest backup
- Safe to repeat with `cleanupBeforeRestore: None` (additive)
- RECOMMEND re-running if Hub 1 had any policy/app/credential changes since last step 0
- When in doubt, run it — cost is low, risk of skipping is higher

**Steps 1 + 2 (cluster namespace + ManagedCluster activation):**
- ARE cluster-specific — only bring over the target cluster's data
- Must be run for each cluster being moved
- Step 1 `includedNamespaces` should list only the new cluster's namespace
- Step 2 `orLabelSelectors` should match only the new cluster's ManagedCluster

**Namespace exclusions for step 0 (cumulative):**
- All managed cluster namespaces (already moved + about to move)
- `open-cluster-management-agent`
- `open-cluster-management-agent-addon`

**Why policies auto-apply to new clusters:** ACM governance uses Placement to select clusters by labels. Once a ManagedCluster resource lands on Hub 2 (step 2), existing Placements evaluate it and policies propagate automatically. This is why step 0 doesn't need to be cluster-specific.

**NOT officially tested by QE.** Advise customers to test on non-critical clusters first.

### 11. "Primary hub still running, want to move clusters to new hub"
**Category:** Informational / procedure
**Steps:**
  1. On primary: ensure BackupSchedule is Enabled, latest backup is recent
  2. On primary: prepare the hub (follow "Prepare the primary hub" steps)
  3. On new hub: create Restore to move managed clusters
  4. Cleanup on primary is optional
**ACM 2.14+:** `ImportOnly` strategy eliminates the need for the prepare step in uncontrolled scenarios. See [ImportOnly Strategy](#importonly-strategy-acm-214--mce-29) section.
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

### 12. "Application data backup on managed clusters"
**Category:** Out of scope
**This operator does NOT backup application data on managed clusters.** It only backs up hub cluster configuration. For application data DR, use OADP/Velero policies deployed to managed clusters via ACM policies.
**Blog:** https://www.redhat.com/en/blog/back-up-and-restore-application-persistent-data-with-red-hat-advanced-cluster-management-for-kubernetes-policies

### 13. "Restore validation webhook rejection"
**Category:** Expected behavior
**When `syncRestoreWithNewBackups: true`, the webhook enforces:**
  - All three backup names must be set
  - `veleroManagedClustersBackupName` must be `skip` or `latest` (not a specific backup name)
  - `veleroCredentialsBackupName` must be `latest`
  - `veleroResourcesBackupName` must be `latest`
  - On initial create, `veleroManagedClustersBackupName` must be `skip`
  - To activate, edit the existing Restore to change from `skip` to `latest` (only allowed when phase is Enabled)
**Note:** The webhook only applies when `syncRestoreWithNewBackups` is true. Non-sync restores can use any valid backup name.

### 14. "Cross-datacenter DR with separate S3 buckets per site"
**Category:** Architecture guidance
**Scenario:** Customer has two data centers and wants each to have its own S3 storage rather than sharing a single bucket.
**Solution:** Use S3 cross-datacenter replication. Each hub writes to its local S3, and a replication layer copies data to the other site. Options:
  - AWS S3 Cross-Region Replication (async, < 15 min)
  - MinIO bucket replication (near-real-time)
  - Noobaa MCG mirror (synchronous, ODF required)
**Key points:**
  - Use one-way replication (active → passive), reverse on failover
  - Set `restoreSyncInterval` to at least 2x the replication lag
  - Prefix must match on both hubs' DPA configuration
  - No new ACM features needed — this is a storage-layer solution

### 15. "`local-cluster` settings not restored"
**Category:** Expected behavior
Settings for the `local-cluster` managed cluster resource (such as owning managed cluster set) are not backed up or restored because they contain cluster-specific information. Any customizations to `local-cluster` on the primary hub must be manually applied on the restored hub.

### 15b. "certificateBundles secrets and InfraEnv webhook rejection during incremental hub migration" (ACM-38831, ACM-38832)
**Category:** ACM-38831 = confirmed cluster-backup-operator bug (fixable here). ACM-38832 = assisted-service/Infrastructure Operator design limitation (not fixable in this repo).
**Reporter:** afaulhab, July 2026, discovered while migrating clusters one-at-a-time between two independent ACM hubs (see issue #10b).

**ACM-38831 — `ClusterDeployment`-referenced secrets never get a backup label — history: "expected behavior" (QE, 2026-07-28) → REVERSED, now fixed in code (team lead, 2026-08-04):**
- These are customer-provided secrets (custom API/ingress TLS certs, pull secrets, manifest overrides) that Hive only *references*, it doesn't create/manage them, so they never get `hive.openshift.io/secret-type`.
- Result before the fix: silently excluded from every backup; missing entirely after restore (Hive will surface `ControlPlaneCertificateNotFoundCondition`/`IngressCertificateNotFoundCondition` for the cert-bundle case).
- **First pass (2026-07-28):** a code fix was drafted (walk `Spec.CertificateBundles` and label the referenced secret, mirroring `updateAISecrets`/`updateMetalSecrets`), compiled and unit-tested clean, but QE argued these are user-provided data that should be manually labeled like other user-supplied Hive references (`manifestsConfigMapRef`/`manifestsSecretRef`) — fix was reverted, ticket was going to be resolved as "working as intended."
- **Second pass (2026-08-04):** team lead reconsidered and asked for the fix after all — closing a silent-data-loss gap outweighed the "handle it like other user data" consistency argument, especially since (unlike truly external user data) these references are discoverable directly off a resource we already back up. **Implemented and merged into the fix:** `Spec.CertificateBundles[].CertificateSecretRef`, `Spec.PullSecretRef`, `Spec.Provisioning.ManifestsSecretRef`/`ManifestsConfigMapRef`, in `updateHiveReferencedSecrets()` (`pre_backup.go`). **Deliberately excluded:** `BoundServiceAccountSigningKeySecretRef` (private AWS STS token-signing key material — different risk profile, raised as an open question with the team rather than silently auto-labeled).
- **PR:** [stolostron/cluster-backup-operator#1684](https://github.com/stolostron/cluster-backup-operator/pull/1684).
- **Correct customer-facing guidance now:** `certificateBundles`, `pullSecretRef`, and `manifestsSecretRef`/`manifestsConfigMapRef` referenced secrets/configmaps are auto-labeled — no manual action needed once this PR ships. Still-manual: anything not in that list, e.g. `sshPrivateKeySecretRef`, `BoundServiceAccountSigningKeySecretRef`, GitOps-created Hive admin-kubeconfig secrets.
- **Bug caught in review (CodeRabbit) — general lesson, not just this PR:** the `local-cluster` exclusion added alongside this fix only covered the `ClusterDeployment` loop in `updateHiveResources`; a separate, pre-existing `ClusterPool` loop in the same function had no equivalent guard, so a `ClusterPool` in the `local-cluster` namespace would still get its namespace's secrets labeled for backup. When adding a `local-cluster` exclusion to a function with multiple independent loops/branches, audit *all* of them — the guard doesn't propagate automatically. Also hardened: the function now fails closed (skips the cycle) if resolving `localClusterName` itself errors, instead of silently treating an unresolved name as "no exclusion needed."

**ACM-38832 — InfraEnv restore fails `infraenvvalidators.admission.agentinstall.openshift.io` webhook when both `spec.ClusterRef` and `spec.OSImageVersion` are set:**
- This combination is a legitimate end-state (add a worker node after an OS upgrade — see upstream assisted-service docs), reachable only via an **Update** to an existing InfraEnv.
- The webhook's **Create**-path unconditionally rejects this combination — no exception for restore scenarios. A Velero restore onto a new hub is a Create from the target API server's perspective, so it always hits this rejection.
- Verified upstream in `openshift/assisted-service` (PR #5569, commit 36d3543, PR #8818) — this is by design in the webhook, not a bug in our restore logic, and not fixable from this repo.
- No bypass-label mechanism exists for this webhook (contrast with Hive's own `hive.openshift.io/disable-creation-webhook-for-dr`, which `updateHiveResources()` in `pre_backup.go` patches onto ClusterDeployments to skip an analogous Hive creation-webhook check).
- **This needs a fix in `assisted-service` / Infrastructure Operator (MGMT) team** — e.g. a bypass label the webhook honors, or detecting restore context (`velero.io/backup-name` label) and relaxing the check.
- **No workaround known yet** other than manually recreating the InfraEnv without both fields set, then re-adding `osImageVersion` via Update after the referenced ClusterDeployment is confirmed `Installed` on the new hub.

**Full investigation, code references, and upstream links:** [`incidents/afaulhab-certificatebundles-infraenv-2026-07-28.md`](incidents/afaulhab-certificatebundles-infraenv-2026-07-28.md)

## Cluster Role Assessment

Use the `assess-acm-backup-config` skill/script to determine a cluster's role and health.

### How to Determine Cluster Role

The primary indicator is the **heartbeat backup** (`acm-validation-policy-schedule`) — a short-lived backup with TTL ≈ cron interval. The `backup-cluster` label on the latest heartbeat proves which hub last ran the backup schedule.

| Role | How Detected |
|------|-------------|
| **ACTIVE HUB** | Latest heartbeat's `backup-cluster` label matches this cluster's ID |
| **ACTIVE HUB (paused)** | Heartbeat matches but BackupSchedule is paused |
| **ACTIVE HUB (collision)** | Heartbeat matches but another cluster also started writing |
| **PASSIVE HUB** | Has a Restore with `veleroManagedClustersBackupName: skip` |
| **PASSIVE HUB (sync)** | Passive + `syncRestoreWithNewBackups: true` |
| **COLLIDING** | BackupSchedule exists but another hub owns the latest backups |
| **FAILOVER / ACTIVATION** | Restore with `veleroManagedClustersBackupName` != skip |
| **NOT CONFIGURED** | No BackupSchedule or Restore found |

### Key Labels

| Label | Purpose |
|-------|---------|
| `cluster.open-cluster-management.io/backup-cluster` | Hub cluster ID that created the backup |
| `cluster.open-cluster-management.io/restore-cluster` | Hub that ran managed-clusters restore (failover) |
| `velero.io/schedule-name` | Velero schedule that created the backup |
| `cluster.open-cluster-management.io/backup-schedule-type` | Type: credentials, resources, managed-clusters |
| `velero.io/backup-name` | Set on restored resources, used by CleanupRestored |

### Governance Policy Validation (`backup-restore-enabled`)

This policy is installed by the backup Helm chart on both hubs. It validates backup health on the active hub and OADP readiness on the passive hub. When NonCompliant, check these templates:

| Template | What it checks |
|----------|---------------|
| `acm-cluster-backup-enabled` | cluster-backup component enabled in MCH |
| `oadp-operator-exists` | OADP operator installed in backup namespace |
| `oadp-channel-validation` | OADP version matches expected version |
| `custom-oadp-channel-validation` | OADP in other namespaces matches backup namespace version |
| `acm-backup-pod-running` | Backup operator pod is running |
| `oadp-pod-running` | OADP operator pod is running |
| `velero-pod-running` | Velero pod is running |
| `data-protection-application-available` | DPA resource exists |
| `backup-storage-location-available` | BSL exists with status Available |
| `acm-backup-clusters-collision-report` | BackupSchedule not in BackupCollision |
| `acm-backup-phase-validation` | BackupSchedule/Restore not in Failed/Empty |
| `acm-managed-clusters-schedule-backups-available` | Velero backups exist at storage |
| `acm-backup-in-progress-report` | No backups stuck in InProgress |
| `backup-schedule-cron-enabled` | Primary hub actively generating new backups |
| `auto-import-account-secret` | MSA secret exists in managed cluster namespaces |
| `auto-import-backup-label` | MSA secrets have the backup label |

**Note:** If hub self-management is disabled (`disableHubSelfManagement=true`), the policy won't be placed on the hub. Set `is-hub=true` label on the local ManagedCluster to enable it.

The policy is also automatically enabled on managed hubs in a global hub scenario (clusters with the `feature.open-cluster-management.io/addon-multicluster-global-hub-controller` label).

### Common Diagnostic Scenarios

| Scenario | Meaning |
|----------|---------|
| This cluster ran failover but has no BackupSchedule | Should be active — needs a BackupSchedule |
| This cluster ran failover but another hub owns latest backups | Other hub should be passive |
| BackupSchedule exists but another hub owns backups | Collision — only one hub should write |
| Passive cluster but no backups in storage | Active hub may not be running, or BSL not syncing |
| Passive cluster but no heartbeat backups | Active hub's backup cron may have stopped or TTL expired |
| `backup-restore-enabled` policy NonCompliant | Check per-template violations for specific issue |

### Manual Investigation Commands

```bash
# Get this cluster's ID
oc get clusterversion version -o jsonpath='{.spec.clusterID}'

# Full BackupSchedule status
oc get backupschedule -n open-cluster-management-backup -o yaml

# Full Restore status
oc get restore.cluster.open-cluster-management.io -n open-cluster-management-backup -o yaml

# All ACM backups with cluster ownership labels
oc get backups.velero.io -n open-cluster-management-backup \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp,HUB:.metadata.labels.cluster\.open-cluster-management\.io/backup-cluster'

# Velero schedules
oc get schedules.velero.io -n open-cluster-management-backup

# BSL details
oc get bsl -n open-cluster-management-backup -o yaml

# Policy compliance
oc get policy backup-restore-enabled -n open-cluster-management-backup -o yaml

# Check Velero pod logs
oc logs -n open-cluster-management-backup -l app.kubernetes.io/name=velero --tail=100

# Check operator pod logs
oc logs -n open-cluster-management-backup -l app=cluster-backup-chart-clusterbackup --tail=100
```

### 16. "BareMetal / ClusterInstance clusters and DR"
**Category:** Informational / Architecture
**Scenario:** Customer uses ClusterInstance (siteconfig-operator) to provision BareMetal clusters and wants active/passive DR.

**What gets backed up:**
- `ClusterInstance` CRs (from `siteconfig.open-cluster-management.io` — included via `.open-cluster-management.io` suffix match)
- `ClusterDeployment` and Hive resources (from `.hive.openshift.io`)
- `agent-install.openshift.io` resources (InfraEnv, AgentClusterInstall, etc.) — in activation backup
- Cluster credentials/kubeconfigs — in credentials backup

**Cluster reconnection:** ClusterInstance-provisioned clusters are Hive-created (ClusterDeployment exists). They reconnect automatically after restore — no ManagedServiceAccount needed. `useManagedServiceAccount: true` is only needed for imported clusters without a Hive kubeconfig.

**BareMetalHost (BMH) backup:**
- ACM 2.16+: BMHs are backed up by default (MGMT-18971)
- ACM < 2.16: BMHs need manual label `cluster.open-cluster-management.io/backup: cluster-activation` and `restoreStatus` configuration in the Restore CR:
  ```yaml
  restoreStatus:
    includedResources:
      - BareMetalHost
  ```

**MCE PVs (assisted-service, assisted-image-service, postgres):**
- PVs are NOT backed up by default and are NOT needed for DR
- When CRs (InfraEnv, AgentClusterInstall, etc.) are restored, assisted-service automatically syncs cluster data from the CRs into its postgres DB
- Logs and events are lost, but operational data is recreated
- This auto-sync feature is available since ACM 2.11
- No PV backup or volume snapshot needed for the hub DR scenario

**GitOps + backup coexistence:**
- Restoring everything without excluding GitOps-managed resources is safe — larger backup footprint but no conflicts
- Velero restores resources, then GitOps reconciles and applies its desired state — they converge
- Minimal risk of ordering/race conditions, typically harmless
- If you want to minimize backup scope: only cluster installation artifacts (credentials, ClusterDeployment, activation data) are essential. GitOps can recreate the rest.

**Unsupported configuration:** Using a managed cluster (provisioned by the primary hub) as the passive hub is NOT officially supported.

### 17. "oadp-hdr-app-install policy (community policy for managed cluster app DR)"
**Category:** Out of scope (different from hub backup)
**What it is:** Community policy from `open-cluster-management-io/policy-collection` that installs OADP on managed clusters for application data DR. NOT part of the cluster-backup-operator.
**Location:** `community/CM-Configuration-Management/acm-app-pv-backup/`
**If issues reported:** Check Velero restore status on the managed cluster. Common issue: restore references an expired backup → delete the stale Velero Restore resource.

### 18. "ArgoCD managing ManagedCluster CRs causes split-brain during DR cleanup"
**Category:** Design pattern / operational
**Symptoms:** After failover, customer tries to delete/detach ManagedClusters from the source hub, but ArgoCD immediately recreates them (sync policy detects drift). Both hubs end up claiming the same clusters.
**Root cause:** ArgoCD Application managing ManagedCluster CRs via Helm chart with `hubAcceptsClient: true` hardcoded. ArgoCD sync prevents any manual deletion.
**Solutions:**
  - **Option A (GitOps native):** Parameterize `hubAcceptsClient` in the Helm chart. During failover, update Git values to `hubAcceptsClient: false` and let ArgoCD sync the change.
  - **Option B (Playbook):** Pause ArgoCD sync before cleanup: `argocd app set cluster-<name> --sync-policy none`, then delete ManagedCluster.
  - ArgoCD sync must be paused on the source hub BEFORE any cluster deletion/detach operations.
**Related:** This is separate from the backup-restore operator — it's an ArgoCD/GitOps design pattern issue that intersects with DR.
**Case reference:** #04440443 (Amadeus)

### 19. "Hive ClusterDeployments stuck in Deleting state after DR — stale cloud credentials"
**Category:** Operational / Hive
**Symptoms:** After failover/failback, deleting ClusterDeployments on the old hub causes them to hang in `Deleting` state. Hive controller logs show cloud authentication errors (e.g., `AADSTS7000215: Invalid client secret`).
**Root cause:** Hive attempts to deprovision cloud infrastructure when ClusterDeployment is deleted. If cloud credentials (Azure SP, GCP OAuth, AWS keys) stored in the backup are stale/rotated, Hive can't authenticate and the `hive.openshift.io/deprovision` finalizer never gets removed.
**Key insight — failover vs failback asymmetry:**
  - **Failover:** Does NOT trigger Hive deprovisioning (clusters are moved via restore, not deleted). Stale credentials don't matter during failover.
  - **Failback/cleanup:** Triggers Hive deprovisioning when you DELETE ClusterDeployments. Stale credentials cause failures.
**Prevention:**
  - Always set `spec.preserveOnDelete: true` on ALL ClusterDeployments BEFORE any deletion. This skips deprovisioning entirely.
  - Validate cloud credentials on both hubs before DR operations.
  - Correct playbook order: patch `preserveOnDelete=true` FIRST, then delete ManagedCluster/ClusterDeployment.
**Recovery (if already stuck):**
  - If `preserveOnDelete` was the intended state, manually remove the finalizer:
    ```
    oc patch clusterdeployment <name> -n <namespace> --type merge -p '{"metadata":{"finalizers":null}}'
    ```
**Pre-flight check:**
  ```
  oc get clusterdeployment -A -o json | jq -r '.items[] | select(.spec.preserveOnDelete != true) | "\(.metadata.namespace)/\(.metadata.name)"'
  ```
  If any returned, STOP and patch before proceeding with DR.
**Case reference:** #04440443 (Amadeus)

### 20. "DR at scale — guidance for large fleets (70-137 clusters)"
**Category:** Scaling / operational
**Key considerations for large environments:**
  - **Race condition (ACM-34619):** At 5-6% failure rate, expect 4-8 affected clusters per 70-cluster fleet. Mitigation: shut down source hub before restore, or automate the manual reconcile trigger as a recovery step.
  - **ArgoCD sync:** Must be paused on BOTH hubs before cleanup. Automate this in the playbook.
  - **Credential validation:** Automate pre-flight credential checks at scale.
  - **preserveOnDelete:** Enforce via governance policy (always-on, not just during DR).
  - **Backup duration:** With 137 clusters, backup cycle takes longer. Ensure cron schedule allows completion.
  - **Go/No-Go criteria before DR:** All ClusterDeployments have preserveOnDelete=true, credentials validated, ArgoCD sync pause automated, manual recovery steps documented.
**Case reference:** #04440443 (Amadeus)

### 21. "BareMetalHost stuck in Inspecting after DR / ClusterInstance restored when it shouldn't be" (ACM-39330)
**Category:** Confirmed cluster-backup-operator gap, fix delivered (partial), fixed in code.
**Reporter:** Sunny, Aug 2026 — ZTP/bare-metal fleet with passive-sync DR.

**Symptom:** `BareMetalHost` objects for already-installed ZTP clusters flip back to `Inspecting`
state after a DR failover, or even just during routine passive-sync cycles with no real failover.

**A hypothesis worth ruling out fast, not chasing:** singular vs. plural resource name in
`Restore.spec.restoreStatus.includedResources` (e.g. `BareMetalHost` vs `baremetalhosts`) is **not**
the cause — Velero's RESTMapper matches singular/plural case-insensitively, and that field only
controls `.status` subresource restoration, not object creation. Don't spend time on resource-name
casing for this class of bug.

**Real root cause:** `ClusterInstance` (`siteconfig.open-cluster-management.io`) drives Day-1
manifest rendering (including `BareMetalHost`) on every SiteConfig controller reconcile. Before the
fix, `ClusterInstance` was restored **unconditionally** via `acm-resources-schedule` — not
activation-gated like `agent-install.openshift.io` resources — so it got restored/updated even
during passive sync (`veleroManagedClustersBackupName: skip`), with no failover happening at all,
triggering unwanted Day-1 re-renders.

**Fix (Exposure #1 — passive-sync, DONE):** added `siteconfig.open-cluster-management.io` to
`includedActivationAPIGroupsByName` (`controllers/backup.go`), routing `ClusterInstance` into the
managed-clusters activation tier. Now it's only restored during a real failover (`latest`), same as
`agent-install.openshift.io` resources. PR: [#1685](https://github.com/stolostron/cluster-backup-operator/pull/1685)
(merged to `main`), cherry-picked to `release-2.17` as [#1687](https://github.com/stolostron/cluster-backup-operator/pull/1687).

**NOT yet fixed (Exposure #2 — failover-ordering):** even during a *real* failover, `ClusterInstance`
has no restore-order priority and Velero doesn't restore `.status` by default, so SiteConfig can
still race ahead of `BareMetalHost` and re-trigger Day-1 rendering. Needs SiteConfig/ZTP team input
— flagged on the Jira, response pending.

**Backport status / OCP-version gotcha:** merging to `main` + cherry-picking to `release-2.17`
does NOT automatically help every affected customer — always check the customer's actual OCP
version against that ACM release's support matrix first. A customer on an older OCP version (e.g.
4.18) needs the fix in whichever ACM release actually supports that OCP version (e.g. 2.14/2.15),
not necessarily the newest release branch.

**Manual workaround (use with caution, not reversible):**
```bash
oc patch clusterinstance <name> -n <ns> --type merge -p '{"spec":{"suppressedManifests":["BareMetalHost"]}}'
oc patch bmh <name> -n <ns> --type merge -p '{"spec":{"externallyProvisioned":true}}'
```
`suppressedManifests` and `externallyProvisioned` are both real fields — but `externallyProvisioned:
true` is **not reversible** (confirmed against upstream metal3 docs/issue) once set. Apply
`suppressedManifests` first, check existing values before overwriting (merge patches replace list
fields wholesale), and only use `externallyProvisioned` as a last resort if impact is severe —
otherwise wait for the real fix.

**Full writeup:** [`incidents/sunny-clusterinstance-bmh-inspecting-2026-08-05.md`](incidents/sunny-clusterinstance-bmh-inspecting-2026-08-05.md)
(also has the `openshift-cherrypick-robot` multi-branch gotcha and EUS/support-matrix backport
reasoning — see [Backport Branch Selection Policy](#backport-branch-selection-policy-which-release-branches-to-target) below).

### 22. "Can we use a third-party backup tool (e.g. Kasten) instead of OADP/Velero for the hub?"
**Category:** Not supported — architectural, not just a support-matrix gap.
**Answer: no, with high confidence.** `cluster-backup-operator` is deeply integrated with Velero's
own CRDs and mechanics, not just "a backup tool that happens to be OADP":
- Backup/restore selection logic (`backup.go`, activation-tier gating) is expressed as Velero
  `Schedule`/`Backup`/`Restore` label selectors and `includedResources`/`excludedResources` — a
  different backup engine has no equivalent selector model to plug into.
- Activation semantics (passive vs. managed-clusters activation, `CleanupRestored`/`CleanupAll`,
  sync mode) are implemented as controller logic that creates and watches Velero `Restore` objects
  directly — there's no abstraction layer a third-party tool could sit behind.
- Safety exclusions (`local-cluster`, MCH namespace, excluded API groups/CRDs) are enforced at the
  point resources are handed to Velero for backup — reimplementing this outside our controller
  would require duplicating a large, actively-changing amount of business logic with no upstream
  support if it drifts.
- There is no supported "manual reintegration" path (e.g., recreating cluster connections via
  bootstrap-kubeconfig by hand after a non-Velero restore) — this bypasses the activation
  controller entirely and isn't a documented or tested procedure.
**No official written "not supported" statement exists for this specific question** (Kasten wasn't
named in any doc found) — the confidence here comes from the architecture, not a citation.

## Backport Branch Selection Policy — which release branches to target
When a fix needs backporting beyond the branch it merged to, don't backport to every existing
release branch reflexively. Reasoning to apply:
- **Fully-supported window ("current + 2 previous"):** routine bug backports here need no special
  justification — open a normal cherry-pick PR. (At time of writing: 2.15/2.16/2.17.)
- **EUS releases** (currently 2.11 and 2.13) get a **longer** support tail, but backports still
  need the same "real need + urgent priority" justification/sign-off process used for other EUS
  backport requests (see [Standard CVE Fix Workflow](#standard-cve-fix-workflow-business-continuity--sustaining-admins)
  for the analogous embargo process) — don't open these PRs preemptively without that sign-off, it
  can undercut the process release management asked to be followed.
- **Non-EUS branches outside the current+2 window** (e.g., an older EUS's *predecessor* generation)
  have ambiguous support-phase status — low-cost to attempt (a normal cherry-pick PR) but not
  guaranteed to be accepted by OWNERS; don't assume acceptance.
- **Always cross-check the customer's actual OCP version against the target ACM release's support
  matrix** before telling anyone a backport "will help them" — a newer-sounding ACM release branch
  is not automatically the one that supports an older customer's OCP version.
- **Tooling gotcha:** `openshift-cherrypick-robot` processes a multi-branch `/cherry-pick a b c`
  comment sequentially and **stops at the first branch that fails to apply** — it does not attempt
  the remaining branches in that same request. If you only see one bot reply after requesting
  several branches, assume the rest were never attempted (not that they silently succeeded) and
  either re-request them individually or cherry-pick manually.

## Code Review Process Notes

### CodeRabbit flagging a concern on a cherry-pick PR that it didn't flag on the original PR
Observed on `release-2.17`'s cherry-pick ([#1687](https://github.com/stolostron/cluster-backup-operator/pull/1687))
of [#1685](https://github.com/stolostron/cluster-backup-operator/pull/1685): CodeRabbit flagged
`processResourcesToBackup` mutating a package-level slice (`backupManagedClusterResources`) as a
concurrency concern on the cherry-pick, but said nothing about the identical code on the original
PR. Investigated whether the two PRs' diffs actually differed (they didn't, functionally) —
concluded this is LLM non-determinism in the review tool itself, not a real difference in the code
being reviewed. **Before spending time hardening code in response to a review comment, check
whether the same code already went through review unflagged elsewhere** — if so, and the concern
isn't actually reachable in practice (e.g., here: the controller runs single-threaded,
`MaxConcurrentReconciles` is unset/defaults to 1, and only one caller invokes the function), it's
reasonable to resolve the comment with an explanation rather than a code change, and note it as a
possible future hardening item rather than a blocking issue.

## Information to Collect for Bug Reports

When a customer issue looks like a potential bug, ask for:

1. **ACM version:** `oc get mch -n open-cluster-management -o jsonpath='{.items[0].status.currentVersion}'`
2. **OCP version:** `oc get clusterversion version -o jsonpath='{.status.desired.version}'`
3. **OADP version:** `oc get csv -n open-cluster-management-backup | grep oadp`
4. **BackupSchedule or Restore status:** `oc get <resource> -n open-cluster-management-backup -o yaml`
5. **Velero backup/restore status:** `oc get backups.velero.io -n open-cluster-management-backup` or `oc get restores.velero.io -n open-cluster-management-backup`
6. **BSL status:** `oc get bsl -n open-cluster-management-backup`
7. **Operator pod logs:** `oc logs -n open-cluster-management-backup -l app=cluster-backup-chart-clusterbackup`
8. **Velero pod logs:** `oc logs -n open-cluster-management-backup -l app.kubernetes.io/name=velero`
9. **Events:** `oc get events -n open-cluster-management-backup --sort-by='.lastTimestamp'`
10. **Policy status:** `oc get policy backup-restore-enabled -n open-cluster-management-backup -o yaml`

## Standard CVE Fix Workflow (Business Continuity → Sustaining Admins)

This is the normal (non-breach) process for handling an embargoed security finding end-to-end, per
the team's CVE workflow onboarding (Jira: ACM-35024).

**While under embargo — private mirror is the staging ground:**

1. All fix development, code review, and cross-stream validation happens in the team's **private
   mirror repo**, not the public repo. Nothing embargoed goes into a public repo or public PR
   before the embargo lifts.
2. Develop and validate the fix on `main` first, then backport (cherry-pick, resolving conflicts as
   needed) to every affected z-stream release branch, opening one PR per branch in the private
   mirror. Build + run the relevant unit tests on every branch before opening its PR.
3. Get the private-mirror PRs reviewed and approved, but **hold off on merging** them until the
   embargo lift date is confirmed — merging early doesn't help since none of it can go public yet,
   and premature merges just create more branches to keep in sync if the embargo timeline shifts.

**Business Continuity team's job stops at `main`.** The team does **not** manually backport fixes
into the public z-stream release branches — that's owned by `ocp-sustaining-admins`.

**Once the embargo lifts:**

1. Merge the fix to the **public `main`** branch only.
2. For each affected z-stream, add a comment to that stream's Jira ticket linking the public
   `main` PR and summarizing backport context: confirm there are no breaking changes, and note
   that a pre-tested backport already exists and was validated in the private mirror (so
   sustaining admins aren't starting from scratch).
3. Reassign each per-stream Jira ticket to `ocp-sustaining-admins`. They own actually opening and
   merging the backport PRs into the public, otherwise-closed/frozen z-stream release branches.
4. Sustaining admins bypass normal branch protection on those frozen branches using the
   **`acknowledge-security-fixes-only`** GitHub label — a label reserved specifically for
   security-only fixes, so it doesn't reopen the branch to general changes.

**Why pre-validate in the private mirror before handoff:** by the time sustaining admins pick up
the per-stream ticket, they can trust the diff is a known-good, build-and-test-verified backport
rather than re-doing that verification themselves under the embargo's disclosure SLA time
pressure.

## Security Fix Verification Methodology

General, reusable process for validating a security fix before it goes public — developed while
verifying a batch of embargoed fixes ahead of their public-PR green light. No CVE-specific details
here by design; see the team's private/local embargo tracking for those.

**Don't just trust that a fix was reviewed before — re-derive it from the code:**
1. Read the actual pre-fix vulnerable code path yourself and confirm it matches the vulnerability's
   description. Don't assume a written summary is accurate without checking it against `main`.
2. Review the fix's diff for completeness (does it close the *whole* vulnerable surface, or just
   the reported instance of it?) and check for an accompanying regression test that fails on the
   old code and passes on the new code.
3. Build and run tests **per fix, in isolation**, not just as part of a combined branch — isolates
   which fix (if any) is actually responsible for a failure.
4. If multiple fixes are landing around the same time (e.g., a batch of CVEs against the same
   component), **merge them all together locally and re-run the full test suite against the
   combined result**, including the slower integration/envtest suite, not just unit tests. Fixes
   that pass individually can still conflict or interact badly once combined — checking this before
   they land publicly is much cheaper than discovering it after.
5. Run the linter against the combined result too, matching CI's exact config — a passing build
   with lint violations still blocks or delays the public PR.

**Classify every fix by *failure mode*, not just correctness — this determines what needs a release
note:**
- **Fails loud:** the fix rejects the now-blocked input/configuration with a clear, actionable error
  or status message (e.g., an admission webhook rejection, or a reconciler status message telling
  the user what changed and what to do). Customers relying on the old (vulnerable) behavior find
  out immediately, with a path to remediate.
- **Fails silent:** the fix makes a previously-effective, previously-documented field or option
  quietly stop doing anything, with no error and no indication to the user. This is the pattern to
  actively watch for: check whether the field/option being closed off is mentioned anywhere in
  docs, sample YAMLs, or a CRD's field-level comments. If it is, **flag it for an explicit release
  note / KCS callout** regardless of how correct the fix is — otherwise the first sign of the change
  will be a confused "this stopped working" support ticket days or weeks after the fix ships,
  looking like a mystery regression instead of an intentional, documented security change.

**Practical takeaway:** a fix being "correct" (closes the vulnerability, doesn't break tests) and a
fix being "safe to ship without a heads-up" are two different bars. Always evaluate both before
signing off on a security fix, and call out any silent-failure-mode fixes explicitly when handing
off for release-note authoring.

## CI / Prow Infrastructure Notes (openshift/release)

### SonarCloud reporting 0.0% coverage on new code despite tests passing
**Symptom:** `ci/prow/sonar` and `sonar-post-submit` pass (Quality Gate green), but the SonarCloud
dashboard shows 0.0% coverage on new code — masking real coverage regressions, since the gate
doesn't fail on this.

**Root cause:** a stale/corrupted Go build cache inside the `sonar` step's container causes the
`controllers` package's test binary to fail compiling with errors like `could not import os` /
`reflect` / `context`. When that compile fails, Sonar has no coverage data for the package and
reports 0%, but the step doesn't hard-fail overall.

**Not unique to this repo:** `insights-client` and `insights-metrics` hit the identical symptom and
root cause; fixed in [openshift/release#82513](https://github.com/openshift/release/pull/82513) by
adding `go clean -cache -modcache` immediately before the `sonar/go/prow` make target in both the
`sonar` and `sonar-post-submit` steps.

**Fix applied to cluster-backup-operator:** same one-line addition, applied to `main` and all 9
release-branch CI configs (2.11–2.17, 5.0, 5.1) in
[openshift/release#82909](https://github.com/openshift/release/pull/82909), since this is a
CI-infra issue, not branch-specific. No Prow job regeneration was needed — the generated job specs
under `ci-operator/jobs/` just invoke `ci-operator --target=sonar`, which reads the `commands:`
block from the config file at runtime.

**If this recurs on another stolostron Go repo:** check for the same `go clean -cache -modcache`
line in that repo's `sonar`/`sonar-post-submit` steps before assuming it's a new issue.

### `main` → release-branch fast-forwarding: history and current state (cluster-backup-operator)
**Current state (as of Aug 2026): fast-forwarding is NOT configured at all** for
`cluster-backup-operator` in `openshift/release` — no `fast-forward` / `ocm-ci-fastforward` job
exists in any of its CI config files. `CONTRIBUTING.md`/repo docs describing an ongoing "main
fast-forwards to the current release branch" post-submit behavior are **stale** as of this
finding.

**History:** [openshift/release#78276](https://github.com/openshift/release/pull/78276) ("ACM
business continuity - remove ffwding from main->release-2.17", merged Apr 23 2026) explicitly
removed the `fast-forward` postsubmit job (workflow `ocm-ci-fastforward`, `DESTINATION_BRANCH:
release-2.17`) from `cluster-backup-operator`'s `main.yaml` — and did the identical removal for
`volsync-addon-controller` in the same PR. It was never re-added for `release-5.0`/`release-5.1`.

**How to tell if a release branch is being actively fast-forwarded vs. just freshly cut:** compare
its HEAD commit SHA to `main`'s (`git ls-remote --heads <repo-url>`). `release-2.14` through
`release-2.17` have all diverged from `main` (expected — actively maintained z-streams, no ffwd).
`release-5.0`/`release-5.1` are currently identical to `main` — not because of an active sync
mechanism, just because no fast-forward job exists to diverge them from, and nothing has been
backported to them yet since they were cut.

**Takeaway for future branch-cut tickets (e.g. ACM-39278-style "branching day" tasks):** don't
assume a fast-forward job exists just because docs/tribal knowledge say so — check the actual
`ci-operator/config/stolostron/<repo>/*.yaml` files directly. If a "disable fast-forwarding before
freeze" warning shows up again, first confirm one is even configured before doing anything.

### ACM 5.1 branching day (ACM-39278) — config was pre-created ahead of the actual cut
`stolostron-cluster-backup-operator-release-5.1.yaml` and branch protection for `release-5.1` were
both added proactively in
[openshift/release#78583](https://github.com/openshift/release/pull/78583) ("ACM business
continuity 5.0 and 5.1 release branch config"), well ahead of the Aug 6 2026 feature-freeze date,
mirroring the `release-5.0` config with `promotion.disabled: true` on the branch-specific config
while `main.yaml` promotes images to both the `5.0` and `5.1` imagestream namespaces. This is the
expected "holding pattern" pattern before a freeze actually takes hold — useful as a template for
the next branch cut (e.g. 5.2).

## Security Finding / Embargo Breach Escalation Process

If a security fix branch or PR containing an embargoed finding is accidentally opened in a
**public** repo (even briefly, even if closed immediately), the diff is still fetchable via the
GitHub API/URL — closing or deleting the PR does not remove exposure. Only a GitHub Support
takedown request removes it, and that requires immediate ProdSec involvement. Treat this as an
active incident, not a cleanup task: report it to ProdSec right away rather than trying to fix it
via further git operations (force-push, history rewrite, etc. do not help once GitHub has served
the content).

**Severity gates the follow-up process, not the initial escalation:**

- Report the breach to ProdSec immediately regardless of severity — this step doesn't change.
- If no CVE has been filed yet for the finding, an **unembargoed** CVE gets created (since the
  exposure already broke any embargo, there's nothing left to protect), and you work it through
  the normal process with your ProdSec contact.
- **Critical-severity findings get an extra verification + reporting step:** double-check the
  severity is accurate, and once a CVE is created, proactively report the CVE ID and due date up
  the chain (not just to your direct ProdSec contact).
- **Important/Moderate/Low findings** follow the default path — work directly with your ProdSec
  contact, no extra up-the-chain due-date reporting required.

Don't assume every accidental exposure needs executive-level escalation — check the assigned
severity first before over- or under-reacting.

## Useful Links

- **Official docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index
- **GitHub repo:** https://github.com/stolostron/cluster-backup-operator
- **Setup blog:** https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes
- **Active/passive migration blog:** https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup
- **App data backup policies blog:** https://www.redhat.com/en/blog/back-up-and-restore-application-persistent-data-with-red-hat-advanced-cluster-management-for-kubernetes-policies
- **Move managed clusters tutorial:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

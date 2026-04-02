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

## Ownership Boundaries

| Component | Team | Slack Channel |
|-----------|------|---------------|
| BackupSchedule / Restore CRs, backup selection, collision detection, sync mode, cleanup, auto-import | **cluster-backup-operator** | #forum-acm-backupandrestore |
| DataProtectionApplication, BackupStorageLocation, Velero pod, Velero backup/restore execution | **OADP team** | #forum-oadp |
| MultiClusterHub, operator installation, cluster-backup chart deployment | **MCH/MCE team** | #forum-acm |
| ManagedServiceAccount, addon framework | **MCE/Foundation team** | #forum-acm |
| Managed cluster import/detach mechanics | **Foundation team** | #forum-acm |

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
- ACM 2.14+ has `ImportOnly` import strategy (default on new installs) — prevents the hub from re-importing clusters it already knows about
- For ACM < 2.14, there is no workaround for uncontrolled DR

**Strong recommendation:** Full active/passive with identical hubs is the supported, well-tested path.
**Cleanup is optional** — the doc says "you can choose to clean up."
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

### 11. "Primary hub still running, want to move clusters to new hub"
**Category:** Informational / procedure
**Steps:**
  1. On primary: ensure BackupSchedule is Enabled, latest backup is recent
  2. On primary: prepare the hub (follow "Prepare the primary hub" steps)
  3. On new hub: create Restore to move managed clusters
  4. Cleanup on primary is optional
**ACM 2.14+:** `ImportOnly` strategy eliminates the need for the prepare step in uncontrolled scenarios.
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

## Useful Links

- **Official docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index
- **GitHub repo:** https://github.com/stolostron/cluster-backup-operator
- **Setup blog:** https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes
- **Active/passive migration blog:** https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup
- **App data backup policies blog:** https://www.redhat.com/en/blog/back-up-and-restore-application-persistent-data-with-red-hat-advanced-cluster-management-for-kubernetes-policies
- **Move managed clusters tutorial:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

# ACM Backup & Restore - Triage Knowledge Base

This knowledge base is used by AI agents to triage customer issues related to the ACM cluster-backup-operator.

## Scope

The cluster-backup-operator handles **hub cluster disaster recovery only**. It does NOT handle:
- Application DR on managed clusters (use OADP/Velero policies instead)
- Managed cluster availability
- Velero internals (that's OADP team)

## Ownership Boundaries

| Component | Team | Slack Channel |
|-----------|------|---------------|
| BackupSchedule / Restore CRs, backup selection, collision detection, sync mode, cleanup, auto-import | **cluster-backup-operator (us)** | Our channel |
| DataProtectionApplication, BackupStorageLocation, Velero pod, Velero backup/restore execution | **OADP team** | #forum-oadp |
| MultiClusterHub, operator installation, cluster-backup chart deployment | **MCH/MCE team** | #forum-acm |
| ManagedServiceAccount, addon framework | **MCE/Foundation team** | #forum-acm |
| Managed cluster import/detach mechanics | **Foundation team** | #forum-acm |

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

## Restore Phases

| Phase | Meaning | Common Causes |
|-------|---------|---------------|
| **Started** | Cleanup or initial restore in progress | Normal early phase |
| **Running** | Velero restores executing | Normal during restore |
| **Finished** | All restores completed successfully | Healthy completion |
| **FinishedWithErrors** | Partial failures | Velero `PartiallyFailed`, concurrent Restore/BackupSchedule active, invalid cleanupBeforeRestore value |
| **Error** | Hard failure | BSL unavailable, Velero restore `Failed`/`FailedValidation`, initialization error |
| **Enabled** | Passive sync active | `syncRestoreWithNewBackups: true` with valid config, syncing periodically |
| **Unknown** | Velero restore status unclear | Velero pod issue |

## Common Customer Issues and Triage

### 1. "Restore stuck in Error after temporary BSL outage"
**Category:** Known limitation
**Symptoms:** syncRestoreWithNewBackups: true, BSL went down temporarily, now back but Restore stays in Error
**Root cause:** When BSL is unavailable, Velero restores fail with FailedValidation. The controller only syncs when phase is Enabled, but sets phase to Error on any Velero failure.
**Workaround:** Delete the failed Velero restore objects:
```
oc -n open-cluster-management-backup delete restore.velero.io <failed-restore-name>
```
After deletion, the controller will create new Velero restores and transition back to Enabled.
**Status:** Enhancement proposed (EnabledWithErrors phase).

### 2. "BackupSchedule in BackupCollision"
**Category:** Configuration issue
**Symptoms:** BackupSchedule shows BackupCollision phase
**Root cause:** Two scenarios:
  - Two hubs have active BackupSchedules writing to the same storage location
  - A passive hub ran a restore managed cluster activation while this hub's schedule was active
**Resolution:** 
  - Ensure only ONE hub has an active BackupSchedule per storage location
  - Delete the BackupSchedule on the wrong hub, create a new one on the correct hub
  - Check `status.lastMessage` for which cluster ID is conflicting

### 3. "BackupSchedule in FailedValidation"
**Category:** Configuration issue
**Check these in order:**
  1. Is the cron expression valid? (`spec.veleroSchedule`)
  2. Does a BackupStorageLocation exist? (`oc get bsl -n open-cluster-management-backup`)
  3. Is the BSL Available? (check BSL status phase)
  4. Is there an active Restore running? (schedule cannot run while restore is active unless paused)
  5. Is `useManagedServiceAccount: true` but MSA CRD not installed?

### 4. "Restore in FinishedWithErrors"
**Category:** Could be config or issue
**Check these:**
  1. Is another Restore or BackupSchedule active? (only one active Restore allowed)
  2. Is `cleanupBeforeRestore` valid? (must be `None`, `CleanupRestored`, or `CleanupAll`)
  3. Check `status.lastMessage` for Velero `PartiallyFailed` — some resources may fail to restore but overall restore works
  4. Velero PartiallyFailed is often normal for empty backup files (no resources matched the selector)

### 5. "Managed clusters not reconnecting after restore"
**Category:** Expected behavior / configuration
**Key points:**
  - Managed clusters reconnect at **activation time** (when `veleroManagedClustersBackupName` is set to `latest`)
  - Passive sync (`veleroManagedClustersBackupName: skip`) does NOT activate clusters
  - If using imported clusters (not Hive-created), auto-import requires ManagedServiceAccount to be enabled on the primary hub's BackupSchedule
  - Check `status.messages` on the Restore for import details per cluster
  - Clusters created via Hive (ClusterDeployment) reconnect automatically
  - Imported clusters need either MSA auto-import or manual reimport
**Docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component

### 6. "What gets backed up? My resource X is not restored"
**Category:** Informational
**Backed up by default (no label needed):**
  - Resources from these API groups: `*.open-cluster-management.io`, `*.hive.openshift.io`, `argoproj.io`, `app.k8s.io`
  - ManagedCluster, ClusterDeployment, MachinePool, KlusterletAddonConfig, ManagedClusterAddon, etc.
  - Secrets/ConfigMaps with Hive or ACM backup labels
  - Policies (root policies only, not child/propagated policies)
  - Placements, PlacementRules, PlacementBindings

**NOT backed up by default (needs label):**
  - Resources in excluded API groups (search, internal, work, admission, operator, etc.)
  - User-created ConfigMaps/Secrets without backup labels
  - Resources in the MCH namespace (unless labeled)
  - AddonDeploymentConfig (excluded by default)
  - Any custom resources not in the included API groups

**How to include:** Add label `cluster.open-cluster-management.io/backup: ""` (or `cluster-activation` for activation-only data)
**How to exclude:** Add label `velero.io/exclude-from-backup: "true"`

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
**Redirect to:** OADP team if Velero-specific tuning needed
**Docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index#velero-resource-requests

### 8. "How to set up active/passive hub clusters"
**Category:** Informational / setup guidance
**Steps:**
  1. Install ACM on both hubs, same version, same namespace
  2. Enable cluster-backup on both MCH
  3. Create DataProtectionApplication on both, pointing to same storage
  4. Create BackupSchedule on primary hub only
  5. Create passive sync Restore on secondary hub:
     ```yaml
     spec:
       syncRestoreWithNewBackups: true
       restoreSyncInterval: 10m
       veleroManagedClustersBackupName: skip
       veleroCredentialsBackupName: latest
       veleroResourcesBackupName: latest
     ```
  6. When disaster strikes, set `veleroManagedClustersBackupName: latest` on secondary to activate
**Blog:** https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes
**Blog:** https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup

### 9. "OADP version compatibility"
**Category:** Informational
**Key rule:** Use the OADP version that ships with your ACM version. Do not upgrade OADP independently.
**Override:** MCH annotation `mch-imageOverridesCM` can override OADP channel if needed.
**Redirect to:** OADP team for OADP-specific bugs

### 10. "Primary hub still running, want to move clusters to new hub"
**Category:** Informational / procedure
**This is NOT a disaster scenario.** Both hubs are running.
**Steps:**
  1. On primary: ensure BackupSchedule is Enabled, latest backup is recent
  2. On primary: pause or delete BackupSchedule
  3. On new hub: create Restore with `cleanupBeforeRestore: CleanupAll` (first time) or `CleanupRestored`
  4. Set `veleroManagedClustersBackupName: latest` to activate clusters on new hub
  5. Primary hub should NOT have active BackupSchedule while new hub activates
**Blog:** https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component
**Docs:** https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index#restore-primary-active

### 11. "Application data backup on managed clusters"
**Category:** Out of scope (informational)
**This operator does NOT backup application data on managed clusters.** It only backs up hub cluster configuration.
For application data DR, use OADP/Velero policies deployed via ACM policies to managed clusters.
**Blog:** https://www.redhat.com/en/blog/back-up-and-restore-application-persistent-data-with-red-hat-advanced-cluster-management-for-kubernetes-policies

### 12. "Restore validation webhook rejection"
**Category:** Expected behavior
**When `syncRestoreWithNewBackups: true`, the webhook enforces:**
  - All three backup names must be set
  - `veleroManagedClustersBackupName` must be `skip` or `latest` (not a specific backup name)
  - `veleroCredentialsBackupName` must be `latest`
  - `veleroResourcesBackupName` must be `latest`
  - On initial create, `veleroManagedClustersBackupName` must be `skip`
  - To activate, edit the existing Restore to change from `skip` to `latest`

## Cluster Role Assessment

Use the `assess-acm-backup-config` skill/script to determine the cluster's role and health. Source: https://github.com/birsanv/samples/blob/main/skills/assess-acm-backup-config/SKILL.md

### How to Determine Cluster Role

The primary indicator is the **heartbeat backup** (`acm-validation-policy-schedule`) — a short-lived backup with TTL ≈ cron interval. The `backup-cluster` label on the latest heartbeat proves which hub last ran the backup schedule.

| Role | How Detected |
|------|-------------|
| **ACTIVE HUB** | Latest heartbeat backup's `backup-cluster` label matches this cluster's ID |
| **ACTIVE HUB (paused)** | Heartbeat matches but BackupSchedule is paused |
| **ACTIVE HUB (collision)** | Heartbeat matches but another cluster also started writing |
| **PASSIVE HUB** | Has a Restore with `veleroManagedClustersBackupName: skip` |
| **PASSIVE HUB (sync)** | Passive + `syncRestoreWithNewBackups: true` |
| **COLLIDING** | BackupSchedule exists but another hub owns the latest backups |
| **FAILOVER / ACTIVATION** | Restore with `veleroManagedClustersBackupName` != skip |
| **NOT CONFIGURED** | No BackupSchedule or Restore found |

### Key Labels for Backup Ownership

| Label | Purpose |
|-------|---------|
| `cluster.open-cluster-management.io/backup-cluster` | Hub cluster ID that created the backup |
| `cluster.open-cluster-management.io/restore-cluster` | Hub that ran managed-clusters restore (failover) |
| `velero.io/schedule-name` | Velero schedule that created the backup |
| `cluster.open-cluster-management.io/backup-schedule-type` | Type: credentials, resources, managed-clusters |

### Velero Schedule Names

| Schedule | Contents |
|----------|----------|
| `acm-credentials-schedule` | Secrets, ConfigMaps (credentials) |
| `acm-resources-schedule` | Applications, policies, placements |
| `acm-resources-generic-schedule` | User-labeled generic resources |
| `acm-managed-clusters-schedule` | ManagedCluster activation data |
| `acm-validation-policy-schedule` | Cron heartbeat (short TTL) |

### Governance Policy Validation (`backup-restore-enabled`)

This policy is installed by the backup Helm chart. When NonCompliant, check these templates:

| Template | What it checks |
|----------|---------------|
| `oadp-operator-exists` | OADP operator installed in backup namespace |
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
| `oadp-channel-validation` | OADP version matches expected version |

**Note:** If hub self-management is disabled (`disableHubSelfManagement=true`), the policy won't be placed on the hub. Set `is-hub=true` label on the local ManagedCluster to enable it.

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
```

## Information to Collect for Bug Reports

When a customer issue looks like a potential bug, ask for:

1. **ACM version:** `oc get mch -n open-cluster-management -o jsonpath='{.items[0].status.currentVersion}'`
2. **OADP version:** `oc get csv -n open-cluster-management-backup | grep oadp`
3. **BackupSchedule or Restore status:** `oc get <resource> -n open-cluster-management-backup -o yaml`
4. **Velero backup/restore status:** `oc get backups.velero.io -n open-cluster-management-backup` or `oc get restores.velero.io -n open-cluster-management-backup`
5. **BSL status:** `oc get bsl -n open-cluster-management-backup`
6. **Operator pod logs:** `oc logs -n open-cluster-management-backup -l app=cluster-backup-chart-clusterbackup`
7. **Velero pod logs:** `oc logs -n open-cluster-management-backup -l app.kubernetes.io/name=velero`
8. **Events:** `oc get events -n open-cluster-management-backup --sort-by='.lastTimestamp'`

## Useful Doc Links

- Official docs: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index
- Setup blog: https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes
- Active/passive migration: https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup
- App data backup policies: https://www.redhat.com/en/blog/back-up-and-restore-application-persistent-data-with-red-hat-advanced-cluster-management-for-kubernetes-policies
- Move managed clusters tutorial: https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component
- GitHub repo: https://github.com/stolostron/cluster-backup-operator

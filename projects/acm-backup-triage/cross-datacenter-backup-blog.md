# Cross-Datacenter Disaster Recovery for Red Hat Advanced Cluster Management Hub Clusters

## What this guide covers

Red Hat Advanced Cluster Management (ACM) supports active-passive hub cluster disaster recovery, but the standard setup requires both hubs to share a single S3 bucket — making the storage a single point of failure. This guide shows how to extend the pattern across two data centers by adding S3 replication between independent storage locations, so each site can operate independently if the other goes down.

## Architecture

Each data center has its own ACM hub and S3 bucket. The active hub writes backups to its local S3, and a replication layer copies them to the passive site. The passive hub reads from its local replica. If the active site goes down, the passive hub already has the data locally.

```mermaid
flowchart TB
  subgraph DC1 ["Data Center 1 (Active)"]
    direction TB
    Hub1["ACM Hub - Active<br/><br/>BackupSchedule<br/>OADP / Velero"]
    S3_1[("S3 Bucket<br/>(Primary)")]
    Hub1 -- "write backups" --> S3_1
    MC_A["Managed Cluster A"]
    MC_B["Managed Cluster B"]
  end

  subgraph DC2 ["Data Center 2 (Passive)"]
    direction TB
    Hub2["ACM Hub - Passive<br/><br/>Restore (sync)<br/>OADP / Velero"]
    S3_2[("S3 Bucket<br/>(Replica)")]
    S3_2 -- "read backups" --> Hub2
    MC_C["Managed Cluster C"]
    MC_D["Managed Cluster D"]
  end

  S3_1 == "S3 Replication<br/>(one-way sync)" ==> S3_2

  Hub1 -. "manages" .-> MC_A
  Hub1 -. "manages" .-> MC_B
  Hub1 -. "manages" .-> MC_C
  Hub1 -. "manages" .-> MC_D
```

### Data flow during normal operation

```mermaid
sequenceDiagram
    participant Hub1 as Active Hub (DC1)
    participant S3_DC1 as S3 Bucket (DC1)
    participant S3_DC2 as S3 Bucket (DC2)
    participant Hub2 as Passive Hub (DC2)

    Hub1->>S3_DC1: 1. BackupSchedule runs on schedule
    S3_DC1->>S3_DC2: 2. S3 replication copies new backup objects
    S3_DC2->>Hub2: 3. Passive Restore detects new backups
    Note over Hub2: Has latest policies, apps,<br/>credentials (but NOT<br/>cluster activation data)
```

Key points:
- Each hub uses a **local** S3 bucket — no cross-site storage dependency
- S3 replication is **one-way** (active → passive), reversed on failover
- Both hubs run **identical** ACM versions, operators, and namespaces
- All managed clusters must be **network-reachable** from both sites

## Prerequisites

Before you begin, ensure both hub clusters have:

- [ ] Red Hat OpenShift Container Platform (same version on both)
- [ ] Red Hat Advanced Cluster Management operator (same version on both)
- [ ] `MultiClusterHub` in `Running` state with `cluster-backup` enabled
- [ ] All additional operators matching the primary hub (GitOps, Ansible, cert-manager, etc.)
- [ ] S3 replication configured between the two buckets ([see S3 replication options](#s3-replication-options))
- [ ] Network connectivity from all managed clusters to both hub API servers

## Step 1: Set up S3 replication

Configure one-way replication from the active hub's S3 bucket to the passive hub's bucket. Choose the option that matches your environment:

- **AWS**: [S3 Cross-Region Replication (CRR)](#aws-s3-cross-region-replication-crr) — async, < 15 min lag
- **On-premises / MinIO**: [MinIO bucket replication](#minio-bucket-replication) — near-real-time
- **OpenShift Data Foundation**: [Noobaa MCG mirror](#red-hat-openshift-data-foundation--noobaa-multi-cloud-gateway-mcg) — synchronous

Configuration details for each option are in the [S3 replication options](#s3-replication-options) section below.

## Step 2: Configure both hubs

On **each** hub, create the storage credentials and `DataProtectionApplication` pointing to the **local** S3 bucket:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: open-cluster-management-backup
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id=<LOCAL_ACCESS_KEY>
    aws_secret_access_key=<LOCAL_SECRET_KEY>
---
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-hub
  namespace: open-cluster-management-backup
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: acm-backup-dc1          # DC2 uses its own bucket name
          prefix: hub-backup              # must match on both hubs
        config:
          region: us-east-1
          s3ForcePathStyle: "true"        # required for MinIO/MCG; optional for AWS
          s3Url: https://s3-dc1.example.com  # DC2 uses its local endpoint; omit for AWS
        credential:
          name: cloud-credentials
          key: cloud
```

> **Important**: The `prefix` must match on both hubs so the passive hub can find the replicated backups.

Verify the `BackupStorageLocation` is `Available` on both hubs:

```bash
oc get backupstoragelocation -n open-cluster-management-backup
```

## Step 3: Configure the active hub (DC1)

Create the `BackupSchedule` on the active hub **only**:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "0 */2 * * *"
  veleroTtl: 120h
  useManagedServiceAccount: true
```

## Step 4: Configure the passive hub (DC2)

Create a `Restore` that continuously syncs passive data:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: open-cluster-management-backup
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

> **Critical**: `veleroManagedClustersBackupName` must be `skip` during passive operation. Setting it to `latest` would activate managed clusters, causing a split-brain.

> **Sync interval**: Set `restoreSyncInterval` to at least 2x the expected S3 replication lag to avoid restoring partially-replicated backups.

Your cross-datacenter active-passive configuration is now running. The passive hub continuously syncs data and is ready for failover.

## Failover: When DC1 goes down

```mermaid
sequenceDiagram
    participant DC1 as DC1 (down)
    participant Hub2 as DC2 Hub (activating)
    participant S3_DC2 as S3 Bucket (DC2)
    participant MC as Managed Clusters

    Note over DC1: DC1 goes down
    Hub2->>S3_DC2: 1. Verify S3 replica is current
    Hub2->>Hub2: 2. Activate: patch ManagedClusters to latest
    MC-->>Hub2: 3. Managed clusters reconnect
    Hub2->>S3_DC2: 4. Create BackupSchedule on DC2
```

**Step 1**: Confirm DC1 is truly unavailable. Check that the passive hub has recent restore data:

```bash
oc get restore -n open-cluster-management-backup
```

**Step 2**: Activate managed clusters by editing the existing Restore:

```bash
oc patch restore restore-acm-passive-sync -n open-cluster-management-backup \
  --type merge -p '{"spec":{"veleroManagedClustersBackupName":"latest"}}'
```

> Do not create a second Restore — the operator only allows one active Restore at a time. Edit the existing one (this is the two-step workflow enforced by the Restore validation webhook).

After activation, managed clusters begin reconnecting to DC2. Hive-provisioned clusters reconnect automatically. Imported clusters reconnect automatically if `useManagedServiceAccount` was enabled on the BackupSchedule; otherwise, they require manual reimport.

**Step 3**: Wait for the Restore to reach `Finished`, then create a BackupSchedule on DC2:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "0 */2 * * *"
  veleroTtl: 120h
  useManagedServiceAccount: true
```

**Step 4**: Delete the BackupSchedule on DC1 to prevent backup collision:

```bash
oc delete backupschedule schedule-acm -n open-cluster-management-backup
```

**Step 5**: Reverse S3 replication direction so DC2 → DC1. This prepares DC1 to become passive when it recovers.

**Step 6**: When DC1 comes back, do **not** create a BackupSchedule. Delete any existing one and create a passive sync Restore on DC1:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: open-cluster-management-backup
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

| Step | Action | Where |
|------|--------|-------|
| 1 | Confirm DC1 is down, verify S3 replica freshness | DC2 |
| 2 | Edit passive Restore: set `ManagedClusters: latest` | DC2 |
| 3 | Wait for Finished, create BackupSchedule | DC2 |
| 4 | Delete BackupSchedule on DC1 | DC1 |
| 5 | Reverse S3 replication direction | S3 layer |
| 6 | Recover DC1 as passive (Restore with sync, no BackupSchedule) | DC1 |

> **ACM 2.14+**: The default `ImportOnly` strategy prevents a recovered hub from reclaiming managed clusters. If you upgraded from an older version, verify this is set.

## Failback: Returning to DC1

1. Ensure BackupSchedule is running on DC2 with at least one successful backup.
2. Reverse S3 replication direction back to DC2 → DC1 so DC1 receives DC2's backups.
3. On DC1, create a Restore with `cleanupBeforeRestore: CleanupRestored` and all three backup names set to `latest`.
4. Wait for the Restore to reach `Finished`. Create and enable BackupSchedule on DC1.
5. On DC2, delete the BackupSchedule. Delete the old Restore and create a new passive sync Restore (`MC: skip`).
6. Reverse S3 replication back to the original direction (DC1 → DC2).
7. Verify DC2 passive Restore reaches `Enabled`.

For the full failback procedure, see [Restoring data to the initial hub cluster](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview#restoring-data-to-the-initial-hub-cluster).

## DR testing (non-destructive)

You can test failover without permanently losing control of managed clusters:

1. **Pause** the BackupSchedule on DC1.
2. **Tag existing resources** on DC1 so they can be properly cleaned up later by `CleanupRestored`. Create a one-time Restore on DC1:
   ```yaml
   apiVersion: cluster.open-cluster-management.io/v1beta1
   kind: Restore
   metadata:
     name: restore-tag-resources
     namespace: open-cluster-management-backup
   spec:
     cleanupBeforeRestore: None
     veleroManagedClustersBackupName: latest
     veleroCredentialsBackupName: latest
     veleroResourcesBackupName: latest
   ```
   Wait for it to finish, then delete it.
3. For ACM versions before 2.14, disable auto-import on managed clusters:
   ```bash
   for mc in $(oc get managedcluster -o name); do
     oc annotate $mc import.open-cluster-management.io/disable-auto-import='' --overwrite
   done
   ```
   ACM 2.14+ with `ImportOnly` does not require this step.
4. **Activate** the passive hub (DC2) using the failover steps above.
5. **Test**: Verify managed clusters are `Available`, policies apply, apps deploy.
6. **Return** to DC1 using the failback steps above.

> Monitor the `backup-restore-enabled` policy on both hubs. It validates that backups are running, BSL is available, and no collisions exist. If hub self-management is disabled, set the `is-hub=true` label on the local `ManagedCluster` to enable the policy.

---

## Deep-dive sections

The following sections provide additional detail for planning and troubleshooting.

### S3 replication options

#### AWS S3 Cross-Region Replication (CRR)

Best for AWS deployments across two regions. Requires versioning enabled on both buckets.

```json
{
  "Role": "arn:aws:iam::ACCOUNT-ID:role/replication-role",
  "Rules": [
    {
      "Status": "Enabled",
      "Priority": 1,
      "Filter": { "Prefix": "" },
      "Destination": {
        "Bucket": "arn:aws:s3:::acm-backup-dc2",
        "StorageClass": "STANDARD"
      },
      "DeleteMarkerReplication": { "Status": "Enabled" }
    }
  ]
}
```

```bash
aws s3api put-bucket-replication \
  --bucket acm-backup-dc1 \
  --replication-configuration file://replication.json
```

Replication is asynchronous (< 15 min typical). [Replication Time Control (RTC)](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-time-control.html) guarantees 99.99% within 15 minutes at additional cost. To reverse on failover, swap the CRR rules between buckets.

#### MinIO bucket replication

Best for on-premises deployments using MinIO.

```bash
mc alias set dc1 https://minio-dc1.example.com ACCESS_KEY SECRET_KEY
mc alias set dc2 https://minio-dc2.example.com ACCESS_KEY SECRET_KEY

mc version enable dc1/acm-backups
mc version enable dc2/acm-backups

mc replicate add dc1/acm-backups \
  --remote-bucket https://ACCESS_KEY:SECRET_KEY@minio-dc2.example.com/acm-backups \
  --replicate "delete,delete-marker,existing-objects"
```

Near-real-time replication. Use `mc replicate status` to monitor lag. Reverse by swapping replication rules.

#### Red Hat OpenShift Data Foundation — Noobaa Multi-Cloud Gateway (MCG)

Best for customers using ODF who want synchronous mirroring.

```yaml
apiVersion: noobaa.io/v1alpha1
kind: BucketClass
metadata:
  name: cross-dc-mirror
  namespace: openshift-storage
spec:
  placementPolicy:
    tiers:
      - backingStores:
          - local-dc1-store
          - remote-dc2-store
        placement: Mirror
```

MCG mirror writes to both stores simultaneously — no replication lag and no reversal needed on failover. Both hubs read from the same logical bucket via their local MCG S3 endpoint.

#### Comparison

| Feature | AWS S3 CRR | MinIO | Noobaa MCG |
|---|---|---|---|
| **Environment** | AWS | On-prem / any S3 | OpenShift (ODF) |
| **Replication** | Async (< 15 min) | Near-real-time | Synchronous |
| **Failover** | Swap CRR rules | Swap rules | Automatic |
| **Cost** | Per-object fee | Self-hosted | ODF license |

### Recovery point and recovery time

| Metric | Value | Depends On |
|--------|-------|------------|
| **RPO (data loss)** | Backup interval + replication lag | 2-hour schedule + 15-min lag = ~2h15m worst case |
| **RTO (recovery time)** | Activation + reconnection | ~15-30 min for moderate hubs |

To minimize RPO: increase backup frequency, use lower-lag replication, or use AWS S3 RTC.

### Backup collision prevention

The ACM operator detects when two hubs write to the same storage and sets the schedule to `BackupCollision`. With cross-datacenter replication, collision risk is low because each hub writes to its own local bucket and replication is one-way. Collision can only occur if the old primary resumes writing after failover.

**Prevention**: Only one hub should have an active BackupSchedule. Always delete or pause the schedule on the old primary before or after failover. Use one-way replication and reverse it only during failover.

**If `BackupCollision` is detected:**
1. Identify which hub is the legitimate active hub
2. Delete the `BackupSchedule` on the wrong hub
3. On the correct hub, delete the collided `BackupSchedule` and create a new one to resume backups

```bash
# Check for collision on any hub
oc get backupschedule -n open-cluster-management-backup
```

### Velero TTL and replication

Velero deletes expired backups based on `veleroTtl`. With async replication, these deletions may not propagate to the replica:

- **AWS**: Enable `DeleteMarkerReplication`. Apply a lifecycle policy on the replica to clean up old versions.
- **MinIO**: Configurable via `--replicate "delete,delete-marker"`.
- **MCG**: Deletions replicate automatically.

### Network requirements

**Managed cluster connectivity:**
- Both hubs need outbound access to all managed cluster API servers (port 6443)
- Managed clusters need outbound access to both hub API servers
- If managed clusters are split across DCs, cross-DC network links must support the management traffic
- Consider a Global Load Balancer or DNS-based failover for seamless cluster reconnection
- Alternatively, `useManagedServiceAccount: true` auto-reconnects imported clusters without DNS changes

**S3 replication network:**

| Replication Method | Network Requirement |
|---|---|
| AWS S3 CRR | No user-managed network (AWS handles it internally) |
| MinIO | HTTPS connectivity between MinIO clusters |
| Noobaa MCG | Network path between MCG instances or shared cloud store access |

Ensure S3 replication traffic is encrypted in transit (TLS) and bandwidth between DCs is sufficient for the backup data volume.

### Bandwidth estimation

| Hub Size | Backup Size per Cycle |
|----------|----------------------|
| ~100 managed clusters | 100 MB — 1 GB |
| ~2000 managed clusters | Several GB |

### Observability

Use separate Observability S3 buckets per data center. On failover, preserve the tenant ID by backing up and restoring the `observatorium` resource. See [Backing up and restoring Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview#backup-restore-observability).

### Notes

- Settings for the `local-cluster` managed cluster resource are not restored on new hubs. Apply any `local-cluster` customizations manually after restore.
- Bucket names can differ between sites — only the `prefix` must match.
- A completed Restore (`Finished` phase) does not block creating a new BackupSchedule.

---

## FAQ

**Can I use bidirectional S3 replication?**
Technically possible, but both hubs would see each other's backups, which can trigger `BackupCollision`. Use one-way replication and reverse it on failover.

**What if S3 replication lags behind?**
The passive hub restores from a slightly older backup. Minimize risk by running backups more frequently and monitoring replication lag.

**Can managed clusters in DC2 connect to the hub in DC1?**
Yes, as long as network connectivity is in place. Managed clusters use outbound connections to the hub API server. The physical location of the managed cluster does not matter — it can be in either data center as long as it can reach the active hub.

**How do I validate the setup before a real disaster?**
Use the non-destructive DR testing procedure described above. Additionally, regularly check the `backup-restore-enabled` policy on both hubs for violations, verify S3 replication status with your storage provider's monitoring tools, and periodically test restoring a backup on the passive hub to confirm data integrity.

**What about Hosted Control Planes?**
The backup covers management configuration. Hosted control planes need a [separate backup strategy](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/business-cont-overview#backup-and-restore-for-hosted-control-plane-overview).

**Is Noobaa MCG recommended?**
It's a good choice if you already use ODF. For AWS, S3 CRR is simpler. For on-prem without ODF, MinIO is lightweight and proven.

## References

- [ACM 2.16 Business Continuity Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index)
- [Backup and Restore Hub Clusters with ACM](https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes)
- [How to Move from Standalone RHACM to Active/Passive](https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup)
- [Move Managed Clusters Using ACM 2.12 Backup Component](https://developers.redhat.com/learn/openshift/move-managed-clusters-using-acm-212-backup-component)
- [AWS S3 Cross-Region Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
- [MinIO Bucket Replication](https://min.io/docs/minio/linux/administration/bucket-replication.html)
- [Red Hat OpenShift Data Foundation — Noobaa MCG](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation)

---

## Appendix: Verification Test Summary

This architecture was verified end-to-end on live OpenShift clusters with a full failover → failback cycle.

### Test Environment

| | Cluster 1 (DC1 - Active) | Cluster 2 (DC2 - Passive) |
|---|---|---|
| **Cluster** | app-prow-small-aws-421-west2-pthps | app-prow-small-aws-421-west2-mnq28 |
| **OCP** | 4.21.0 | 4.21.0 |
| **ACM** | 2.17.0-77 | 2.17.0-150 |
| **OADP** | 1.5.5 | 1.5.5 |
| **Region** | us-west-2 | us-west-2 |
| **S3 Storage** | MinIO (local, in-cluster, 20Gi PVC) | MinIO (local, in-cluster, 20Gi PVC) |
| **Bucket** | acm-backups (prefix: hub-backup) | acm-backups (prefix: hub-backup) |

### Environment Setup

**MinIO deployment (each cluster):**
- MinIO deployed as a single-replica Deployment in the `minio` namespace with a 20Gi PVC
- Exposed via OpenShift Routes (TLS edge termination) for cross-cluster access
- Bucket `acm-backups` created with versioning enabled on both instances
- Credentials: `minioadmin` / `minioadmin123`

**S3 replication:**
- Single-node MinIO does not support server-side bucket replication (requires distributed mode)
- Used `mc mirror --watch --overwrite --remove` as a Deployment on the active hub's cluster
- Mirrors from local MinIO (`http://minio.minio.svc:9000`) to remote MinIO via the external route
- Replication verified with a test file — appeared on DC2 within seconds
- Replication direction reversed by deleting and recreating the mirror Deployment with swapped source/target

**ACM configuration (each cluster):**
- `cluster-backup` enabled on MultiClusterHub
- Storage credentials (`cloud-credentials` Secret) created in `open-cluster-management-backup`
- DataProtectionApplication (`dpa-hub`) pointing to local MinIO with `s3ForcePathStyle: true` and matching `hub-backup` prefix
- BackupStorageLocation confirmed `Available` on both hubs before proceeding
- BackupSchedule used `*/10 * * * *` (every 10 minutes) and `veleroTtl: 24h` for faster test cycles

### Verified Steps

| Phase | Action | Result |
|-------|--------|--------|
| **Setup** | DPA + BSL on both hubs pointing to local MinIO | BSL Available on both |
| **Backup** | BackupSchedule on DC1 (10-min interval) | Enabled, 5 Velero backups completed |
| **Replication** | mc mirror DC1 → DC2 | All backup files synced to DC2's MinIO in near-real-time |
| **Discovery** | DC2 Velero discovers replicated backups from its local storage | All 5 backups visible with Completed status |
| **Passive sync** | Restore on DC2 with MC=skip, sync=true, CleanupRestored | Reached **Enabled** — "restore will continue to sync with new backups" |
| **Failover activation** | `oc patch restore ... veleroManagedClustersBackupName: latest` | Webhook accepted, phase: Enabled → Running → **Finished** |
| **Velero restores created** | 9 Velero restores including `-active` suffix for activation data | All Completed |
| **DC2 becomes active** | Create BackupSchedule on DC2 | **Enabled**, producing backups |
| **DC1 cleanup** | Delete BackupSchedule on DC1 | Deleted, no collision |
| **Reverse replication** | Recreate mc mirror as DC2 → DC1 | DC2 backups synced to DC1's MinIO |
| **DC1 discovers DC2 backups** | DC1 Velero discovers backups from reversed replication | All DC2 backups visible |
| **Failback restore** | Restore on DC1 with CleanupRestored, all three `latest` | **Finished** — "All Velero restores have run successfully" |
| **DC1 active again** | Create BackupSchedule on DC1 | **Enabled** |
| **DC2 back to passive** | Delete BackupSchedule + old Restore on DC2, create new passive sync Restore | Passive Restore reached **Enabled** |
| **Original state restored** | Recreate mc mirror as DC1 → DC2 | Full cycle complete, original configuration restored |

### Key Findings

- Each hub successfully uses its own independent S3 storage with matching prefix — the core cross-datacenter pattern works
- Velero on the passive hub correctly discovers and restores backups that arrived via replication (not written by local Velero)
- The two-step activation workflow (create with `skip`, patch to `latest`) works as documented — webhook accepts the update when phase is Enabled
- A completed Restore (`Finished` phase) does not block creating a new BackupSchedule — no need to delete the Restore first
- One-way replication structurally prevents backup collision — no collision detected throughout the entire cycle
- Replication reversal is the only manual storage-layer step during failover/failback
- No ACM code changes required — this pattern works with existing backup/restore operator capabilities

### Limitations of This Test

The following aspects were not verified due to the test environment setup and should be tested separately in a production-like environment:

- **Managed cluster reconnection**: No managed clusters were attached to either hub during the test. Hive auto-reconnect and ManagedServiceAccount auto-import for imported clusters were not tested. These are standard active/passive behaviors documented in the [official docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index).
- **ImportOnly strategy**: Not tested since no managed clusters were present. The `ImportOnly` behavior for uncontrolled failover scenarios is documented in [Customizing the automatic import strategy](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/clusters/cluster_mce_overview#auto-import-strategy).
- **S3 replication lag**: The `mc mirror` approach provided near-instant replication. The behavior when the passive hub tries to restore a partially-replicated backup was not stress-tested. The `restoreSyncInterval` ≥ 2x replication lag guidance was not validated under load.
- **Server-side S3 replication**: The test used client-side mirroring (`mc mirror`), not server-side replication (AWS CRR, MinIO distributed mode, or Noobaa MCG). The ACM behavior is identical regardless of replication method since replication is transparent to the backup operator.
- **DR testing procedure**: The "tag resources" step (one-time Restore with `cleanupBeforeRestore: None`) from the non-destructive DR testing section was not tested.
- **Observability failover**: Thanos compactor shutdown and `observatorium` resource preservation were not tested.
- **Large-scale performance**: The test used minimal hub data. For hubs managing 1000+ clusters, Velero resource limits may need tuning and backup/restore times will be longer.

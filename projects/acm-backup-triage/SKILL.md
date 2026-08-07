---
name: acm-backup-triage
description: >-
  Triage and troubleshoot Red Hat Advanced Cluster Management (ACM)
  cluster-backup-operator issues: BackupSchedule/Restore phase errors,
  disaster recovery (active/passive, controlled failover, failback)
  procedures, ManagedServiceAccount auto-import failures, backup content
  selection (what gets backed up vs. needs a label), and the
  embargoed-security-fix verification/backport process for this component.
  Use when diagnosing a customer-reported ACM backup or restore problem,
  planning or reviewing a DR runbook, answering "why wasn't X restored",
  assessing a cluster's active/passive role, or verifying a
  cluster-backup-operator security fix before it ships.
---

# ACM Backup & Restore Triage

Companion knowledge base for the `cluster-backup-operator` (ACM hub disaster recovery). Built from
real customer cases, code-verified root-cause investigations, and this component's release/CVE
process — not just documentation. Full detail lives in [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md);
this file is the fast-path entry point.

**Repo:** https://github.com/stolostron/cluster-backup-operator | **Docs:**
https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index

## Ownership routing — check this before investigating

| Symptom area | Owning team | Slack |
|---|---|---|
| BackupSchedule/Restore CRs, backup selection, collision, sync, cleanup, auto-import | **cluster-backup-operator** (this KB) | #forum-acm-backupandrestore |
| DataProtectionApplication, BackupStorageLocation, Velero pod/execution | OADP team | #forum-oadp |
| MultiClusterHub, operator install, chart deployment | MCH/MCE team | #forum-acm |
| ManagedServiceAccount, addon framework, cluster import/detach | MCE/Foundation team | #forum-acm |
| InfraEnv, AgentClusterInstall, assisted-service admission webhooks | Infrastructure Operator (MGMT) | #forum-agent-install |
| ClusterInstance, SiteConfig, ZTP Day-1 rendering | SiteConfig/ZTP team | (verify channel) |

## CRITICAL RULES — never violate these

1. **NEVER recommend deleting ManagedClusters from any hub before or during a restore.** Restore
   handles reconciliation; deletion while `Available` destroys spoke workloads. Use
   `disable-auto-import` (or `ImportOnly` strategy) instead — it prevents split-brain without
   deleting anything.
2. **When reviewing a customer DR playbook**, diff every step against the official documented
   procedure. Flag any deviation, especially deletions/detachments not in the docs.
3. Only delete ManagedClusters from the old hub if: restore is fully complete on the new hub,
   clusters show `Unknown` on the old hub, and you don't plan to fail back to it.
4. Docs explicitly say: "If you want to restore the data to the backup after your recovery test
   completes, skip cleaning the resources."
5. **`cleanupBeforeRestore` defaults to the safest option.** Partial/incremental migrations or
   "move managed clusters" → always `None`. Never recommend `CleanupAll` without extreme
   justification.
6. For repeated "move managed clusters" operations, re-running the cheap/safe policies+apps+creds
   step (`cleanupBeforeRestore: None`) is low-risk; skipping it risks missing new policies.
7. Recommend excluding `open-cluster-management-agent`/`-agent-addon` namespaces from
   cross-hub restores as a safeguard, even though their secrets typically lack backup labels.

## Quick lookup

**BackupSchedule phases:** New → Enabled (healthy) | FailedValidation (bad config) | Failed
(internal error) | BackupCollision (another hub owns latest backups) | Paused

**Restore phases:** Started → Running → Finished (done) | FinishedWithErrors (partial failure) |
Error (hard failure) | Enabled (passive sync active, `syncRestoreWithNewBackups`)

**`cleanupBeforeRestore`:** `None` (additive, safe default for migrations) | `CleanupRestored`
(removes prior-restore leftovers, standard active/passive) | `CleanupAll` (removes everything
matching backup criteria — use with extreme caution)

**A non-paused BackupSchedule and an active Restore cannot coexist.** Only one active Restore at a
time (active = any phase except Finished/FinishedWithErrors).

Full tables, `restoreStatus`/label reference, OADP version matrix, and the ImportOnly strategy →
[KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#backupschedule-phases).

## Issue index — jump straight to the fix

Each maps to a numbered entry in [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) with full root cause,
diagnostics, and resolution steps.

| # | Symptom |
|---|---|
| 1 | Restore stuck in `Error` after a temporary BSL outage — doesn't auto-recover |
| 2 | BackupSchedule in `BackupCollision` |
| 3 | BackupSchedule in `FailedValidation` |
| 4 | Restore in `FinishedWithErrors` |
| 5 | Managed clusters not reconnecting after restore — **includes the full MSA/auto-import-secret failback failure analysis** (SA-UID invalidation, ownerRef bug, 2.14 vs 2.15+ code differences) |
| 6 | "What gets backed up? My resource X is not restored" |
| 7 | Velero pod OOM / restore taking too long — scale tuning |
| 8 | How to set up active/passive hub clusters |
| 9 | OADP version compatibility |
| 10 | Moving managed clusters between two non-identical hubs (NOT a standard restore) |
| 10b | Incremental/repeated single-cluster migration |
| 11 | Primary hub still running, want to move clusters to a new hub |
| 12 | Application data backup on managed clusters — **out of scope**, use OADP/Velero policies |
| 13 | Restore validation webhook rejection (sync mode rules) |
| 14 | Cross-datacenter DR with separate S3 buckets per site |
| 15 | `local-cluster` settings not restored — expected |
| 15b | `certificateBundles`/Hive-referenced secrets and InfraEnv webhook rejection during incremental migration (ACM-38831/38832) |
| 16 | BareMetal / ClusterInstance clusters and DR, BMH backup requirements |
| 17 | `oadp-hdr-app-install` community policy — out of scope, different from hub backup |
| 18 | ArgoCD managing ManagedCluster CRs causes split-brain during DR cleanup |
| 19 | Hive ClusterDeployments stuck `Deleting` after DR — stale cloud credentials |
| 20 | DR at scale — guidance for large fleets (70-137+ clusters) |
| 21 | BareMetalHost stuck in `Inspecting` after DR — ClusterInstance not activation-gated (ACM-39330) |
| 22 | Third-party backup tools (e.g. Kasten) instead of OADP/Velero — **not supported** |

**Not in the index above?** Check [Cluster Role Assessment](KNOWLEDGE_BASE.md#cluster-role-assessment)
for diagnosing active/passive/collision state from scratch, or the governance policy template table
if a `backup-restore-enabled` policy is `NonCompliant`.

## Process references (not customer triage, but same domain)

- [Security Fix Verification Methodology](KNOWLEDGE_BASE.md#security-fix-verification-methodology) —
  how to independently verify a security fix (loud vs. silent failure-mode classification) before
  it ships.
- [Standard CVE Fix Workflow](KNOWLEDGE_BASE.md#standard-cve-fix-workflow-business-continuity--sustaining-admins) —
  private-mirror staging → main → sustaining-admin handoff process.
- [Backport Branch Selection Policy](KNOWLEDGE_BASE.md#backport-branch-selection-policy-which-release-branches-to-target) —
  which release branches actually need a given fix (current+2 vs. EUS vs. OCP support matrix).
- [CI / Prow Infrastructure Notes](KNOWLEDGE_BASE.md#ci--prow-infrastructure-notes-openshiftrelease) —
  known `openshift/release` config gotchas for this repo (Sonar coverage, fast-forwarding).

## Deep-dive incident writeups

For full command-by-command investigations behind the summarized findings above, see
[incidents/](incidents/). Each is a standalone record (cluster access may no longer be available)
covering root cause, live diagnostics, and the exact reasoning trail — useful when a similar case
recurs and the summary in KNOWLEDGE_BASE.md isn't detailed enough.

## When collecting info for a new/unclear issue

Before triaging anything not covered above, gather: ACM version, OCP version, OADP version,
BackupSchedule/Restore YAML + status, Velero backup/restore status, BSL status, operator + Velero
pod logs, recent events, and `backup-restore-enabled` policy status. Commands for each →
[Information to Collect for Bug Reports](KNOWLEDGE_BASE.md#information-to-collect-for-bug-reports).

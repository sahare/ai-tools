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
  assessing a cluster's active/passive role, verifying a
  cluster-backup-operator security fix before it ships, or implementing
  code changes to this operator.
---

# ACM Backup & Restore Triage

Companion knowledge base for the `cluster-backup-operator` (ACM hub disaster recovery). Built from
real customer cases, code-verified root-cause investigations, and this component's release/CVE
process — not just documentation. Full detail lives in the linked files below; this file is the
fast-path entry point.

**Repo:** https://github.com/stolostron/cluster-backup-operator | **Docs:**
https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index

## Progressive Disclosure — Read Only What You Need

This skill uses a **layered approach** to minimize token consumption. Start here, then read only
the specific deep-dive file needed for your task:

| Task Type | Read This File | Token Cost |
|-----------|---------------|------------|
| **Quick ownership/routing check** | This file (below) | ~500 tokens |
| **Customer issue diagnosis** | [INVESTIGATION_PLAYBOOKS.md](INVESTIGATION_PLAYBOOKS.md) | ~2k tokens |
| **Deep issue details / root cause** | [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) (specific section) | ~1-3k tokens per section |
| **Code change / bug fix** | [CODE_MAP.md](CODE_MAP.md) | ~3k tokens |
| **Full incident reconstruction** | [incidents/](incidents/) (specific file) | ~2-5k tokens |

**Rule:** Never read KNOWLEDGE_BASE.md end-to-end. Use the issue index below to jump to the
specific section, or use INVESTIGATION_PLAYBOOKS.md to identify which section you need.

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

1. **NEVER recommend deleting ManagedClusters from any hub before or during a restore.**
2. **When reviewing a customer DR playbook**, diff every step against the official documented procedure.
3. **`cleanupBeforeRestore` defaults to the safest option.** Use `None` for migrations.
4. **Never recommend `CleanupAll` without extreme justification.**

## Quick lookup

**BackupSchedule phases:** New → Enabled (healthy) | FailedValidation | Failed | BackupCollision | Paused

**Restore phases:** Started → Running → Finished | FinishedWithErrors | Error | Enabled (passive sync)

**`cleanupBeforeRestore`:** `None` (safe) | `CleanupRestored` (standard) | `CleanupAll` (dangerous)

## Issue index — jump straight to the fix

Each maps to a section in [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md):

| # | Symptom |
|---|---|
| 1 | Restore stuck in Error after BSL outage |
| 2 | BackupSchedule in BackupCollision |
| 3 | BackupSchedule in FailedValidation |
| 4 | Restore in FinishedWithErrors |
| 5 | Managed clusters not reconnecting (MSA/auto-import, failback SA-UID invalidation) |
| 6 | "What gets backed up? My resource X is not restored" |
| 7 | Velero pod OOM / restore too long |
| 8 | Active/passive setup guide |
| 9 | OADP version compatibility |
| 10 | Moving managed clusters between non-identical hubs |
| 10b | Incremental/repeated single-cluster migration |
| 11 | Primary hub still running, want to move clusters |
| 12 | Application data backup on managed clusters (out of scope) |
| 13 | Restore webhook rejection (sync mode rules) |
| 14 | Cross-datacenter DR with separate S3 |
| 15 | local-cluster settings not restored (expected) |
| 15b | certificateBundles/InfraEnv webhook rejection (ACM-38831/38832) |
| 16 | BareMetal / ClusterInstance clusters and DR |
| 17 | oadp-hdr-app-install community policy (out of scope) |
| 18 | ArgoCD managing ManagedCluster CRs causes split-brain |
| 19 | Hive ClusterDeployments stuck Deleting (stale cloud creds) |
| 20 | DR at scale (70-137+ clusters) |
| 21 | BareMetalHost stuck Inspecting after DR (ACM-39330) |
| 22 | Third-party backup tools (e.g. Kasten) — NOT supported |

## Process references

- [Security Fix Verification](KNOWLEDGE_BASE.md#security-fix-verification-methodology)
- [CVE Fix Workflow](KNOWLEDGE_BASE.md#standard-cve-fix-workflow-business-continuity--sustaining-admins)
- [Backport Branch Selection](KNOWLEDGE_BASE.md#backport-branch-selection-policy-which-release-branches-to-target)
- [CI / Prow Notes](KNOWLEDGE_BASE.md#ci--prow-infrastructure-notes-openshiftrelease)

## Deep-dive incident writeups

[incidents/](incidents/) — standalone records with command-by-command investigation trails.

## Information to collect for new/unclear issues

Before triaging, gather: ACM version, OCP version, OADP version, BackupSchedule/Restore YAML +
status, Velero backup/restore status, BSL status, operator + Velero pod logs, recent events,
policy status. Full command list → [INVESTIGATION_PLAYBOOKS.md](INVESTIGATION_PLAYBOOKS.md#information-collection-template).

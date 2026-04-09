# AI Context — cluster-backup-operator

This file captures the accumulated knowledge, decisions, and work history from AI-assisted development sessions on this project. Feed this file to any AI coding assistant to resume work with full context.

Last updated: March 2026

## Project Overview

The **cluster-backup-operator** provides disaster recovery for Red Hat Advanced Cluster Management (ACM) hub clusters. It runs on the hub and uses OADP/Velero to back up and restore hub configuration — managed clusters, policies, applications, credentials, and other hub resources.

- **Repo:** https://github.com/stolostron/cluster-backup-operator
- **Language:** Go 1.25
- **Framework:** controller-runtime (Operator SDK / Kubebuilder)
- **Namespace:** `open-cluster-management-backup`
- **CRDs:** `BackupSchedule` and `Restore` under `cluster.open-cluster-management.io/v1beta1`

## Codebase Structure

```
main.go                     — Entrypoint: scheme registration, manager setup, TLS config, CRD gate
api/v1beta1/                — CRD types (BackupSchedule, Restore), webhook validation
controllers/
  schedule_controller.go    — BackupScheduleReconciler
  schedule.go               — Schedule helpers, collision detection, phase logic
  backup.go                 — Backup content selection (API groups, labels, exclusions)
  restore_controller.go     — RestoreReconciler
  restore.go                — Restore planning, phase logic, sync detection
  restore_post.go           — Post-restore cleanup, auto-import, delta cleanup
  pre_backup.go             — MSA addon/token lifecycle, Hive secret prep
  utils.go                  — Shared helpers (sorting, hub ID, BSL check, CRD presence)
  create_helper.go          — Test-only constructors for fake objects
pkg/tlsconfig/
  tlsconfig.go              — TLS configuration (BuildTLSConfig, GetTLSProfileType)
  tlsconfig_test.go         — TLS unit tests
config/                     — Kustomize: CRDs, RBAC, deployment, samples
hack/crds/                  — Extra CRDs for envtest (Velero, OCM, Hive, etc.)
.tekton/                    — Konflux/Pipelines-as-Code for CI
Dockerfile                  — OpenShift CI build
Dockerfile.rhtap            — RHTAP/Konflux build (FIPS, multi-arch)
```

## Key Architectural Concepts

### Two Reconcilers
- **BackupScheduleReconciler:** Creates 5 Velero schedules (credentials, resources, resources-generic, managed-clusters, validation). Handles collision detection, cron validation, MSA setup.
- **RestoreReconciler:** Creates Velero restores in order. Handles passive sync, activation, cleanup, post-restore auto-import.

### Backup Categories
- **Passive data:** Credentials, resources, policies, apps — restoring these does NOT activate managed clusters
- **Activation data:** ManagedCluster, ClusterDeployment, etc. — restoring these makes clusters connect to the new hub

### 5 Velero Schedules
| Schedule | Contents |
|----------|----------|
| `acm-credentials-schedule` | Secrets/ConfigMaps with backup labels |
| `acm-resources-schedule` | ACM resources (policies, apps, placements) |
| `acm-resources-generic-schedule` | User-labeled resources |
| `acm-managed-clusters-schedule` | Managed cluster activation data |
| `acm-validation-policy-schedule` | Heartbeat (short TTL) for cron validation |

### Phase State Machines
**BackupSchedule:** New → Enabled (healthy) | FailedValidation | Failed | BackupCollision | Unknown | Paused
**Restore:** Started → Running → Finished | FinishedWithErrors | Error | Enabled (passive sync) | Unknown

### Key Behavioral Rules (verified against code and unit tests)
- Only one active Restore allowed (anything except Finished/FinishedWithErrors counts as "active")
- A non-paused BackupSchedule cannot coexist with an active Restore (gets FailedValidation)
- A paused BackupSchedule CAN coexist with an active Restore
- A completed Restore (Finished/FinishedWithErrors) does NOT block a BackupSchedule
- Passive sync (Enabled phase) only runs when `syncRestoreWithNewBackups=true`, MC=`skip`, creds+resources=`latest`
- Patching MC from `skip` to `latest` triggers activation: Enabled → Started → Running → Finished (sync stops)
- Webhook enforces two-step workflow: create with `skip`, then update to `latest` when Enabled
- Collision detection compares `backup-cluster` label on latest `acm-resources-schedule` backup vs this hub's cluster ID

## Work Completed

### TLS Profile Consistency (Epic ACM-26882)

**What:** Refactored the operator to dynamically inherit TLS settings from the OpenShift APIServer configuration instead of relying on Go defaults.

**Files changed:**
- `main.go` — Added TLS profile fetch, webhook TLS options, HTTP/2 disable (CVE-2023-44487), SecurityProfileWatcher for live TLS profile changes
- `pkg/tlsconfig/tlsconfig.go` — New package: `BuildTLSConfig()`, `GetTLSProfileType()`, `profilesMatch()`
- `pkg/tlsconfig/tlsconfig_test.go` — Comprehensive unit tests
- `Dockerfile` and `Dockerfile.rhtap` — Added `COPY pkg/ pkg/`, changed to `CGO_ENABLED=0`
- `Makefile` — Updated test target to include `./pkg/...`
- `go.mod` — Added `github.com/openshift/controller-runtime-common`

**Key decisions:**
- Uses `openshifttls.FetchAPIServerTLSProfile()` directly (removed our wrapper — it was just pass-through)
- Fail-fast on TLS fetch error (exit, don't fall back to default)
- HTTP/2 disabled by default due to CVE-2023-44487
- `disableHTTP2` applied AFTER profile config to ensure it takes precedence
- SecurityProfileWatcher triggers graceful shutdown on TLS profile change (pod restarts with new config)
- RBAC for `apiservers.config.openshift.io` already covered by Helm chart's wildcard ClusterRole
- Removed unused `GetDefaultTLSProfile()`, `ApplyTLSOptions()` (moved to test), `FetchTLSProfile()` wrapper, `UnsupportedCiphers` field

**Verified:** tls-scanner on live cluster confirmed TLSv1.3 only, ML-KEM (PQC) supported, API MinVersion compliance true.

### Code Quality Fixes

1. **Global slice mutation (concurrency safety)** — `processResourcesToBackup` in `backup.go` now works with a local copy of `backupManagedClusterResources`
2. **`deleteBackup` error handling** — Now logs and returns error instead of silently swallowing Create failures
3. **`sortCompare` mutation** — Now sorts copies instead of mutating caller's slices
4. **`kubeClient` nil handling** — Now logs error and exits instead of continuing with nil client
5. **Typos fixed** — "finsihed" → "finished", "avaialable" → "available", "Prerequiste" → "Prerequisite"

### Restore Validation Webhook

Added webhook documentation to README covering:
- Sync mode validation rules
- Two-step managed cluster activation workflow
- Validation error examples

### Restore Controller Fix (cherry-pick 115e5472)

Applied fixes for activation label handling and sync mode behavior. Resolved merge conflicts adapting `metav1.Duration` vs `v1.Duration`.

### CI/CD

- Resolved `funlen` linter failure by splitting `TestProfilesMatch` into 7 distinct tests
- Identified Konflux Enterprise Contract warnings as shared pipeline issue in `stolostron/konflux-build-catalog`
- Identified SonarCloud Quality Gate failures on PR #1580
- Removed Gemini code review GitHub Action (`.github/workflows/gemini-pr-review.yml`)

## AI Tools Repository

Created https://github.com/sahare/ai-tools with 3 projects:

### 1. acm-cluster-setup
- `scripts/install-acm.sh` — Automated ACM dev build installation from quay.io/acm-d (7 steps, progress monitoring, timeout handling, uninstall mode)
- `scripts/diagnose.sh` — AI-powered cluster diagnostics (9 areas: nodes, pull secrets, ICSP, CatalogSources, operator, MCH, pods, events, console)

### 2. acm-release-cut
- `acm-cut-release.py` — Automates CI config changes when cutting new ACM release branches in openshift/release

### 3. acm-backup-triage
- `KNOWLEDGE_BASE.md` — Comprehensive triage knowledge base built from codebase, unit tests, official docs, and blogs. Covers 15 common issue categories with root causes and resolutions, verified against controller code.
- Opted into Red Hat Slack RAG initiative for #forum-acm-backupandrestore

### Agent Integration
- `AGENT.md` — AI agent skills (triage, assess backup config, install, diagnose, release cut)
- `CLAUDE.md` — Claude Code pointer
- `.cursorrules` — Cursor pointer
- All reference `AGENT.md` as single source of truth, compatible with any AI tool

## Cross-Datacenter DR Blog

Created `/Users/sahare/workspace/cross-datacenter-backup-blog.md` — comprehensive guide for active/passive hub DR across two data centers with independent S3 storage.

**Content:** Architecture with diagrams, 3 S3 replication strategies (AWS CRR, MinIO, Noobaa MCG), hub configuration, failover/failback procedures, DR testing, collision prevention, RPO/RTO analysis, FAQ.

**Review rounds completed:**
1. Knowledge base review — verified against triage knowledge
2. Unit test review — validated 8 claims against test suite (7 confirmed, 1 corrected)
3. README review — cross-referenced all technical details
4. Controller code review — validated phase transitions, webhook rules, cleanup behavior, collision detection

**Key corrections made during review:**
- Activation must edit existing Restore (not create second one)
- Completed Restore doesn't block BackupSchedule (corrected from "must delete")
- Added ImportOnly strategy for ACM 2.14+ uncontrolled failover
- Added Velero TTL + replication interaction
- Added replication lag guidance (sync interval ≥ 2x lag)

**Status:** Draft ready, shared with product management in Google Doc for review. Awaiting decision on publication format (blog vs docs vs developers.redhat.com learning path).

## Cluster Environment

### se-hub-a (app-prow-small-aws-421-west2-pthps)
- **OCP:** 4.21.0
- **ACM:** 2.17.0-76 (MCH currently Paused from TLS testing)
- **Purpose:** Primary test cluster for TLS verification and cross-datacenter DR testing
- **Fix applied:** Added `hibernate: "true"` label to ClusterDeployment (was missing, causing cluster to stay running)

## Jira Tasks Tracked

- **ACM-26882:** TLS Profile Consistency (completed, PR open)
- **Cross-datacenter S3 replication docs:** Draft ready, awaiting product management review
- **Agentic context files:** Jira created for adding AGENTS.md, docs/architecture.md, .coderabbit.yaml, and updating CONTRIBUTING.md

## Key Technical Knowledge

### What gets backed up
- API groups: `*.open-cluster-management.io`, `*.hive.openshift.io`, `argoproj.io`, `app.k8s.io`, `core.observatorium.io`
- Excluded groups: `internal`, `operator`, `work`, `search`, `admission.hive`, `proxy`, `action`, `view`, `clusterview`, `velero.io`
- Secrets/ConfigMaps need labels: `cluster.open-cluster-management.io/type`, `hive.openshift.io/secret-type`, or `cluster.open-cluster-management.io/backup`
- GitOps-created ClusterDeployment secrets need manual backup label
- Only root policies backed up (not child/propagated)
- `local-cluster` namespace excluded

### OADP version mapping
| ACM | OADP |
|-----|------|
| 2.13+ | 1.4 or stable channel |
| 2.12 | 1.4 |
| 2.11 | 1.4 |
| 2.10 | 1.3 |

### Cleanup behavior (CleanupRestored)
- Secrets/ConfigMaps: requires `velero.io/backup-name` label present AND pointing to different backup
- Dynamic resources: label selectors matching backup's included resource kinds
- Never cleans: `velero.io/exclude-from-backup: true`, local-cluster namespace, MCH namespace

### Governance policy (`backup-restore-enabled`)
- Installed by backup Helm chart on both hubs
- Key templates: `velero-pod-running`, `backup-storage-location-available`, `acm-backup-clusters-collision-report`, `backup-schedule-cron-enabled`
- Won't be placed if `disableHubSelfManagement=true` — set `is-hub=true` label to enable
- Auto-enabled on global hub managed hubs

### ImportOnly (ACM 2.14+)
- Default import strategy on new installs
- Prevents hub from re-importing clusters it already knows about
- Critical for uncontrolled failover (hub dies without preparation)
- Older ACM versions have no workaround for this

## How to Resume Work

When starting a new AI session on this project:

1. **Read this file** — gives full project context
2. **Read the knowledge base** — `projects/acm-backup-triage/KNOWLEDGE_BASE.md` in the ai-tools repo
3. **Read the README** — comprehensive design doc in the operator repo
4. **Check git log** — see what's changed since this file was last updated
5. **Check Jira** — for current task priorities

Key files to read for any code change:
- `main.go` (entrypoint, TLS, manager setup)
- `controllers/restore_controller.go` + `restore.go` (restore logic)
- `controllers/schedule_controller.go` + `schedule.go` (schedule logic)
- `controllers/backup.go` (what gets backed up)
- `api/v1beta1/restore_types.go` + `schedule_types.go` (phase definitions)

# Investigation Playbooks — cluster-backup-operator

Decision trees for diagnosing customer issues. Follow the tree top-to-bottom; stop at the first
match. Each leaf links to the relevant KNOWLEDGE_BASE.md section or gives the exact answer.

---

## Playbook 1: "Something is wrong with my backup/restore"

```
Customer reports a problem
├── Is it about BACKUP (BackupSchedule)?
│   ├── What phase is the BackupSchedule in?
│   │   ├── FailedValidation → KB #3 (check cron, BSL, active Restore, MSA CRD)
│   │   ├── BackupCollision → KB #2 (another hub writing to same storage)
│   │   ├── Failed → Internal error creating Velero schedules (check operator logs)
│   │   ├── Unknown → Velero pod not running or OADP misconfigured
│   │   ├── Paused → User set spec.paused=true (expected if intentional)
│   │   └── Enabled → Healthy. If customer still sees issues, check Velero backup status:
│   │       ├── Velero backups PartiallyFailed → Often normal (empty backup files). KB #4.
│   │       ├── Velero backups Failed → Check BSL availability, Velero pod logs
│   │       └── Velero pod OOM → KB #7 (increase resource limits in DPA)
│   └── "My resource X is not in the backup" → KB #6 (check label requirements)
│
├── Is it about RESTORE?
│   ├── What phase is the Restore in?
│   │   ├── FinishedWithErrors → KB #4 (check for concurrent Restore/Schedule, cleanup value)
│   │   ├── Error → KB #1 (BSL outage? check Velero restore status)
│   │   ├── Enabled → Healthy passive sync. If customer expected activation, they need to
│   │   │   edit veleroManagedClustersBackupName from skip to latest.
│   │   ├── Started/Running → Still in progress (normal)
│   │   └── Finished → Completed. If clusters not reconnecting → next tree below.
│   ├── "Webhook rejected my Restore" → KB #13 (sync mode rules)
│   │   Quick check: is syncRestoreWithNewBackups=true?
│   │   ├── Yes → MC must be skip initially, creds/resources must be latest
│   │   └── No → Webhook shouldn't reject. Check exact error message.
│   ├── "Managed clusters not reconnecting" → Playbook 2 below
│   └── "Resource X was not restored" → KB #6, check:
│       1. Was it in the backup? (oc get backups.velero.io ... -o yaml, check includedResources)
│       2. Was it excluded? (check excludedResources, excludedNamespaces)
│       3. Is it an activation resource? (only restored when MC=latest, not skip)
│       4. Did a webhook reject it? (check Velero restore logs for webhook errors)
│
├── Is it about INFRASTRUCTURE / PLATFORM?
│   ├── OADP/Velero issue → Route to OADP team (#forum-oadp). KB #9 for version compat.
│   ├── MCH install issue → Route to MCH/MCE team (#forum-acm)
│   ├── InfraEnv webhook rejection → KB #15b (ACM-38832, needs assisted-service fix)
│   ├── BareMetalHost stuck Inspecting → KB #21 (ACM-39330, ClusterInstance activation gating)
│   └── ClusterInstance not restored → Check: is it activation-gated? (Yes on main/2.17+)
│
└── Is it about DR PROCEDURE / ARCHITECTURE?
    ├── Active/passive setup → KB #8
    ├── Controlled failover → KB Controlled Failover section
    ├── Move managed clusters between hubs → KB #10
    ├── Incremental/repeated migration → KB #10b
    ├── Cross-datacenter with separate S3 → KB #14
    ├── ArgoCD managing ManagedClusters → KB #18
    ├── Third-party backup tool (Kasten etc.) → KB #22 (NOT supported)
    └── App data on managed clusters → KB #12 (out of scope, use OADP policies)
```

---

## Playbook 2: "Managed clusters not reconnecting after restore"

```
Clusters not reconnecting
├── Was veleroManagedClustersBackupName set to "latest" (not "skip")?
│   ├── No (still "skip") → Activation hasn't happened yet. Edit Restore to set latest.
│   └── Yes → Continue
│
├── Is this a Hive-created cluster (ClusterDeployment exists)?
│   ├── Yes → Should reconnect automatically via kubeconfig in backup.
│   │   ├── Check: does ClusterDeployment exist on the new hub?
│   │   ├── Check: are cloud credentials valid? (KB #19 for stale creds)
│   │   └── Check: work-agent race condition? (ACM-34619, ~5-6% failure rate)
│   │       Symptom: cluster shows Available on OLD hub despite disable-auto-import.
│   │       Fix: ACM 2.17+ has PR #1109. Pre-fix: shut down old hub first.
│   └── No → Imported cluster, needs MSA or manual auto-import-secret.
│
├── Is useManagedServiceAccount=true on the BackupSchedule?
│   ├── No → Manual auto-import-secret needed per cluster namespace. KB #5.
│   └── Yes → Continue MSA diagnosis.
│
├── Is this the FIRST failover (never failed back before)?
│   ├── Yes → MSA should work. Check:
│   │   ├── MSA token expired? → Check managedServiceAccountTTL vs veleroTtl. KCS 7039710.
│   │   ├── BSL had issues during backup? → Token may not have been captured.
│   │   └── Check Restore status.messages for per-cluster details.
│   └── No (this is a FAILBACK / round-trip) → SA-UID invalidation is expected. KB #5.
│       MSA auto-import WILL fail for imported clusters after round-trip.
│       Reason: spoke recreated ServiceAccount with new UID during failover,
│       old token references old UID → Kubernetes rejects with Unauthorized.
│       ├── NOT fixable by increasing TTL (identity mismatch, not time expiry)
│       ├── NOT fixable by GitOps cluster registration (doesn't create auto-import-secret)
│       └── Fix: manual reimport with fresh spoke credentials, or script batch reimport.
│
├── ACM version check:
│   ├── ACM 2.14 → Different MSA selection code (findValidMSAToken), stricter.
│   │   May skip creating auto-import-secret entirely if annotation shows expired.
│   │   Error message: "Skip MSA access token for secret (%s:%s) no loger valid!" [sic]
│   └── ACM 2.15+ → Lenient MSA selection (selectValidMSASecret), always returns a candidate.
│
└── ownerReferences bug (ACM-38215)?
    Check: oc get secret auto-import-account -n <cluster-ns> -o jsonpath='{.metadata.ownerReferences}'
    ├── Empty ownerReferences → Bug confirmed. managed-serviceaccount controller can't refresh.
    │   Check ManagedServiceAccount conditions: TokenReported=False, reason=TokenReportFailed.
    │   This is a Foundation/MCE team bug, not cluster-backup-operator.
    └── Populated → ownerRef bug is not the issue, continue other diagnosis.
```

---

## Playbook 3: "Can I do X with DR?" (architecture questions)

```
Customer asks about a DR scenario
├── "Can I use active/passive with non-identical hubs?"
│   → KB #10. NOT standard restore. Use "move managed clusters" procedure.
│     Full restore would overwrite hub2's own resources.
│
├── "Can I move clusters one at a time?"
│   → KB #10b. Possible but NOT officially tested. Steps 1+2 are cluster-specific,
│     Step 0 is not. Always re-run Step 0 to catch policy/app changes.
│
├── "Can I fail back to the original primary?"
│   → KB Controlled Failover section. Yes, with caveats:
│     - Imported clusters will need manual reimport (SA-UID invalidation)
│     - Set ImportOnly strategy on secondary before failback
│     - Create fresh BackupSchedule on secondary first, wait for backup
│
├── "Can I keep both hubs running during DR testing?"
│   → Yes, with ImportOnly (ACM 2.14+) or disable-auto-import annotation.
│     Pause BackupSchedule on primary before activating on secondary.
│
├── "Can I use Kasten/third-party backup instead of OADP?"
│   → KB #22. NOT supported. Deep Velero CRD integration, no abstraction layer.
│
├── "Do I need to back up MCE PVs (postgres, assisted-service)?"
│   → KB #16. No. CRs are restored, assisted-service auto-syncs from CRs.
│
├── "What about a managed cluster as the passive hub?"
│   → KB #16. NOT officially supported.
│
└── "What version of OADP should I use?"
    → KB #9. Use what ships with your ACM version. Override annotation available.
```

---

## Playbook 4: "My code change broke CI"

```
CI failure after a code change
├── Which check failed?
│   ├── unit-tests → Read the test failure output.
│   │   ├── schedule_controller_test.go line ~1387 → Known flaky test. /retest-required.
│   │   ├── "no loger valid" / MSA-related → Check if test depends on MSA secret ordering.
│   │   └── Other → Likely a real regression. Run `make test` locally to reproduce.
│   │
│   ├── crd-and-gen-files-check → Generated files are stale.
│   │   Fix: `make manifests generate`, commit the regenerated files.
│   │   Common trigger: any change to api/v1beta1/*.go (types, comments, markers).
│   │
│   ├── sonar → Check SonarCloud dashboard.
│   │   ├── 0% coverage on new code → Stale Go cache. See KB CI section.
│   │   ├── Cognitive complexity → Decompose function or add //nolint comment.
│   │   └── Conditional operators > 5 → Only flagged for code in controllers/, not api/.
│   │
│   ├── images → Docker build failure.
│   │   ├── Added new top-level package? → Add COPY to BOTH Dockerfiles.
│   │   └── Build error → Run `make build` locally.
│   │
│   ├── Konflux enterprise-contract → Shared infra issue (MANIFEST_UNKNOWN).
│   │   Usually a transient Tekton bundle resolution failure. Wait and retry.
│   │   Not related to code changes.
│   │
│   └── DCO → Missing Signed-off-by trailer. Amend commit with --signoff.
│
├── Lint failures?
│   ├── funlen → Function too long (>60 statements). Decompose.
│   ├── lll → Line too long (>120 chars). Break into multi-line.
│   ├── goimports → Run `goimports -w <file>`.
│   ├── errcheck → Handle the error return.
│   └── misspell → Fix the typo.
│
└── Cherry-pick/backport specific?
    ├── Merge conflict → Resolve manually, test with `make test`.
    ├── Different function signature on older branch → Check Branch Differences Matrix
    │   in CODE_MAP.md (e.g., setOptionalProperties returns error on older branches).
    ├── controller-gen crash on 2.11 → Known: v0.4.1 crashes on Go 1.24+.
    │   Skip `make manifests`, test with `make build && make vet && make test`.
    └── acknowledge-security-fixes-only label needed → Create it if missing, apply to PR.
```

---

## Information Collection Template

When triaging an unclear issue, collect these before investigating. Copy-paste to Slack/Jira:

```
Please provide the following diagnostic information:

1. ACM version:
   oc get mch -n open-cluster-management -o jsonpath='{.items[0].status.currentVersion}'

2. OCP version:
   oc get clusterversion version -o jsonpath='{.status.desired.version}'

3. OADP version:
   oc get csv -n open-cluster-management-backup | grep oadp

4. BackupSchedule status (if applicable):
   oc get backupschedule -n open-cluster-management-backup -o yaml

5. Restore status (if applicable):
   oc get restore.cluster.open-cluster-management.io -n open-cluster-management-backup -o yaml

6. Velero backup/restore status:
   oc get backups.velero.io -n open-cluster-management-backup
   oc get restores.velero.io -n open-cluster-management-backup

7. BSL status:
   oc get bsl -n open-cluster-management-backup -o yaml

8. Operator logs (last 200 lines):
   oc logs -n open-cluster-management-backup -l app=cluster-backup-chart-clusterbackup --tail=200

9. Recent events:
   oc get events -n open-cluster-management-backup --sort-by='.lastTimestamp' | tail -30

10. Policy status:
    oc get policy backup-restore-enabled -n open-cluster-management-backup -o yaml
```

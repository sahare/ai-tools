# Code Map — cluster-backup-operator

Pre-computed reference for AI agents. Use this instead of exploring files.
**Last updated:** 2026-08-14 from `main` branch.

---

## File Index (sorted by change frequency)

| File | Lines | Purpose |
|------|-------|---------|
| `controllers/restore.go` | ~1066 | Core restore logic: phase state machine, backup selection, Velero restore creation, optional properties, finalizers |
| `controllers/pre_backup.go` | ~1061 | Pre-backup prep: MSA addon/token lifecycle, Hive secret auto-labeling, AI/metal secret labeling |
| `controllers/restore_controller.go` | ~900 | RestoreReconciler: main reconcile loop, cleanup, orphan management, PVC init, finalizer watches |
| `controllers/restore_post.go` | ~864 | Post-restore: CleanupRestored/CleanupAll delta logic, auto-import-secret creation, activation |
| `controllers/schedule.go` | ~662 | Schedule helpers: phase computation, collision detection, cron parsing, spec-change detection |
| `controllers/utils.go` | ~633 | Shared helpers: MSA secret selection, hub ID, BSL check, local-cluster detection, label helpers |
| `controllers/backup.go` | ~606 | Backup content selection: API group filtering, resource categorization, schedule info |
| `controllers/schedule_controller.go` | ~492 | BackupScheduleReconciler: main reconcile loop, validation, schedule init |
| `main.go` | ~312 | Entrypoint: scheme registration, manager setup, TLS config, Velero CRD gate |
| `api/v1beta1/restore_types.go` | ~262 | Restore CRD type definitions, phase constants, CleanupType enum |
| `api/v1beta1/restore_webhook.go` | ~140 | Restore admission webhook: sync-mode validation, namespace-mapping protection |
| `api/v1beta1/schedule_types.go` | ~164 | BackupSchedule CRD type definitions, phase constants |
| `api/v1beta1/groupversion_info.go` | ~36 | GroupVersion registration (uses apimachinery SchemeBuilder, not controller-runtime) |
| `pkg/tlsconfig/tlsconfig.go` | ~98 | TLS configuration from APIServer profile |

### Test Files

| File | Lines | What it tests |
|------|-------|---------------|
| `controllers/restore_test.go` | ~5235 | restore.go functions (largest test file) |
| `controllers/restore_post_test.go` | ~3191 | Post-restore cleanup and activation |
| `controllers/restore_controller_test.go` | ~3069 | RestoreReconciler integration tests (Ginkgo/envtest) |
| `controllers/pre_backup_test.go` | ~2992 | Pre-backup MSA and Hive secret labeling |
| `controllers/schedule_test.go` | ~2083 | Schedule helpers |
| `controllers/schedule_controller_test.go` | ~2055 | BackupScheduleReconciler integration tests |
| `controllers/utils_test.go` | ~2040 | Utility function tests |
| `controllers/create_helper_test.go` | ~1409 | Test-only constructors (builder pattern) |
| `controllers/suite_test.go` | ~675 | Ginkgo suite setup, envtest bootstrap |
| `controllers/backup_test.go` | ~650 | Backup content selection tests |
| `api/v1beta1/restore_webhook_test.go` | ~192 | Webhook validation tests |
| `pkg/tlsconfig/tlsconfig_test.go` | ~408 | TLS config tests |

---

## Key Constants and Variables

### backup.go — What Gets Backed Up

```
Label keys:
  BackupScheduleNameLabel     = "cluster.open-cluster-management.io/backup-schedule-name"
  BackupScheduleTypeLabel     = "cluster.open-cluster-management.io/backup-schedule-type"
  BackupScheduleClusterLabel  = "cluster.open-cluster-management.io/backup-cluster"
  BackupScheduleActivationLabel = "cluster.open-cluster-management.io/backup-activation-restore"
  BackupVeleroLabel           = "velero.io/schedule-name"
  BackupNameVeleroLabel       = "velero.io/backup-name"
  ClusterActivationLabel      = "cluster-activation"
  ExcludeBackupLabel          = "velero.io/exclude-from-backup"

API group inclusion (suffix match):
  ".open-cluster-management.io", ".hive.openshift.io"

API group inclusion (exact match):
  "argoproj.io", "app.k8s.io", "core.observatorium.io"

Activation API groups (routed to managed-clusters schedule):
  "agent-install.openshift.io", "siteconfig.open-cluster-management.io"

Excluded API groups:
  "internal.open-cluster-management.io", "operator.open-cluster-management.io",
  "work.open-cluster-management.io", "search.open-cluster-management.io",
  "admission.hive.openshift.io", "proxy.open-cluster-management.io",
  "action.open-cluster-management.io", "view.open-cluster-management.io",
  "clusterview.open-cluster-management.io", "velero.io"

Excluded CRDs:
  "clustermanagementaddon.addon.open-cluster-management.io",
  "backupschedule.cluster.open-cluster-management.io",
  "restore.cluster.open-cluster-management.io",
  "clusterclaim.cluster.open-cluster-management.io",
  "discoveredcluster.discovery.open-cluster-management.io"

Managed cluster activation resources (hardcoded list):
  "clusterdeployment.hive.openshift.io", "machinepool.hive.openshift.io",
  "managedcluster.cluster.open-cluster-management.io",
  "klusterletaddonconfig.agent.open-cluster-management.io",
  "managedclusteraddon.addon.open-cluster-management.io",
  "clusterpool.hive.openshift.io", "clusterclaim.hive.openshift.io",
  "clustercurator.cluster.open-cluster-management.io",
  "bmceventsubscription.metal3.io", "hostfirmwaresettings.metal3.io",
  "clustersync.hiveinternal.openshift.io", "clusterimageset.hive.openshift.io",
  "multiclusterobservability.observability.open-cluster-management.io"

Credential labels (secrets/configmaps included via these):
  backupCredsUserLabel    = "cluster.open-cluster-management.io/type"
  backupCredsHiveLabel    = "hive.openshift.io/secret-type"
  backupCredsClusterLabel = "cluster.open-cluster-management.io/backup"

Velero schedule name mapping:
  Credentials      → "acm-credentials-schedule"
  Resources        → "acm-resources-schedule"
  ResourcesGeneric → "acm-resources-generic-schedule"
  ManagedClusters  → "acm-managed-clusters-schedule"
  ValidationSchedule → "acm-validation-policy-schedule"
```

### restore_controller.go — Restore Constants

```
skipRestoreStr      = "skip"
latestBackupStr     = "latest"
restoreSyncInterval = 30 minutes
pvcWaitInterval     = 10 seconds
acmRestoreFinalizer = "restores.cluster.open-cluster-management.io/finalizer"
backupPVCLabel      = "cluster.open-cluster-management.io/backup-pvc"
```

### restore_post.go — Post-Restore Constants

```
RestoreClusterLabel = "cluster.open-cluster-management.io/restore-cluster"
activateLabel       = "cluster.open-cluster-management.io/restore-auto-import-secret"
obs_addon_ns        = "open-cluster-management-addon-observability"
```

### schedule_controller.go — Schedule Types

```
ResourceType enum: ManagedClusters, Credentials, CredentialsActive,
  ResourcesGenericActive, Resources, ValidationSchedule, ResourcesGeneric

SecretType enum: HiveSecret ("hive"), ClusterSecret ("cluster"), UserSecret ("user")

failureInterval          = 60 seconds
collisionControlInterval = 5 minutes
```

---

## Function Map — Where to Edit for Common Tasks

### Adding a resource/API group to backup

**File:** `controllers/backup.go`
- To include by suffix: add to `includedAPIGroupsSuffix` (line ~59)
- To include by exact name: add to `includedAPIGroupsByName` (line ~63)
- To route to activation tier: add to `includedActivationAPIGroupsByName` (line ~68)
- To exclude an API group: add to `excludedAPIGroups` (line ~77)
- To exclude a specific CRD: add to `excludedCRDs` (line ~92)
- To add to hardcoded activation resources: add to `backupManagedClusterResources` (line ~101)
- **Key function:** `processResourcesToBackup()` (line ~440) — dynamically discovers resources
  and categorizes them. Uses a LOCAL copy of `backupManagedClusterResources` to avoid mutating
  package-level state.
- **Key function:** `shouldBackupAPIGroup()` (line ~499) — decides if an API group is included

### Adding a validation to the Restore webhook

**File:** `api/v1beta1/restore_webhook.go`
- `validateRestore()` (line ~80) — entry point, calls sub-validators
- `validateSyncMode()` (line ~94) — sync-mode specific rules
- For namespace-mapping validation: `isProtectedNamespaceMappingTarget()` and
  `validateNamespaceMapping()` — on `main`/2.17/2.16 these are in this file; on 2.15/2.14/2.13
  they are in `controllers/restore.go` (no webhook on those branches)

### Modifying restore behavior

**File:** `controllers/restore.go`
- `setRestorePhase()` (line ~261) — phase state machine, CRITICAL function
- `setOptionalProperties()` (line ~842) — sets Velero restore properties (ExcludedResources,
  ExistingResourcePolicy, hooks, filters, namespace mapping)
- `setUserRestoreFilters()` (line ~884) — applies user-provided label/resource filters
- `getVeleroBackupName()` (line ~585) — resolves "latest"/"skip"/specific backup name
- `isValidSyncOptions()` (line ~105) — validates sync mode configuration
- `isValidCleanupOption()` in `restore_post.go` (line ~741) — validates CleanupAll annotation

### Modifying post-restore activation / cleanup

**File:** `controllers/restore_post.go`
- `executePostRestoreTasks()` (line ~52) — orchestrates all post-restore work
- `postRestoreActivation()` (line ~591) — creates auto-import-secrets for managed clusters
- `createAutoImportSecret()` (line ~712) — plain Create (not upsert!), fails silently on
  AlreadyExists
- `cleanupDeltaResources()` (line ~229) — dispatches CleanupRestored/CleanupAll
- `cleanupDeltaForResourcesBackup()` (line ~402) — resource cleanup logic
- `cleanupDeltaForCredentials()` (line ~273) — credential cleanup logic
- `isValidCleanupOption()` (line ~741) — checks CleanupAll annotation requirement

### Modifying pre-backup preparation

**File:** `controllers/pre_backup.go`
- `prepareForBackup()` (line ~189) — entry point, called from BackupScheduleReconciler
- `updateHiveResources()` (line ~880) — labels Hive secrets for backup, includes local-cluster
  exclusion for both ClusterDeployment AND ClusterPool loops
- `updateSecretsLabels()` (line ~992) — labels secrets matching ClusterPool/ClusterDeployment names
- `updateAISecrets()` (line ~940) — labels agent-install secrets
- `updateMetalSecrets()` (line ~964) — labels BareMetalHost secrets
- `processMSAResources()` (line ~140) — manages MSA addon/token lifecycle
- `createMSA()` (line ~487) — creates ManagedServiceAccount resources

### Modifying schedule behavior

**File:** `controllers/schedule_controller.go`
- `Reconcile()` (line ~114) — main reconcile loop
- `isValidateConfiguration()` (line ~270) — validates BSL, restore conflicts, MSA CRDs
- `initVeleroSchedules()` (line ~332) — creates/updates Velero Schedule objects

**File:** `controllers/schedule.go`
- `setSchedulePhase()` (line ~95) — phase state machine
- `scheduleOwnsLatestStorageBackups()` (line ~283) — collision detection
- `parseCronSchedule()` (line ~235) — cron validation
- `isScheduleSpecUpdated()` (line ~135) — detects spec changes requiring schedule update

### Adding/modifying utility functions

**File:** `controllers/utils.go`
- `selectValidMSASecret()` (line ~292) — MSA secret selection (2.15+ behavior)
- `getHubIdentification()` (line ~246) — returns this hub's cluster ID
- `isValidStorageLocationDefined()` (line ~157) — BSL availability check
- `isHiveCreatedCluster()` (line ~265) — checks if cluster has ClusterDeployment
- `managedClusterShouldReimport()` (line ~333) — determines if cluster needs reimport
- `VeleroCRDsPresent()` (line ~377) — checks if Velero CRDs are installed
- `appendUnique()` (line ~75) — dedup append to string slice

---

## Branch Differences Matrix

Key structural differences across release branches that affect backports:

| Feature | main/2.17/2.16 | 2.15/2.14/2.13 | 2.11 |
|---------|----------------|----------------|------|
| Namespace-mapping validation | `api/v1beta1/restore_webhook.go` | `controllers/restore.go` (no webhook) | N/A (feature doesn't exist) |
| Event recorder type | `record.EventRecorder` (k8s.io/client-go) | `record.EventRecorder` | `record.EventRecorder` |
| Event recorder name | `"restore-controller"` (DNS-safe) | `"Restore controller"` (has space, silently drops events) | `"Restore controller"` |
| Event assertion in tests | `eventsv1.EventList` (events.k8s.io/v1) | `corev1.EventList` | `corev1.EventList` |
| `setOptionalProperties` returns | `error` (errcheck-safe) | no return value | no return value |
| `controller-gen` version | v0.16+ | varies | v0.4.1 (crashes on Go 1.24+) |
| Go version | 1.25/1.26 | 1.25/1.26 | 1.22 (toolchain) |
| Sonar exclusions | `api/v1beta1/**` excluded | `api/v1beta1/**` excluded | varies |
| `siteconfig.open-cluster-management.io` in activation | Yes (PR #1685) | No (needs backport) | No |
| golangci-lint config | `.golangci.yml` present | `.golangci.yml` present | Missing |

---

## Test Infrastructure Reference

### Test Framework
- **Ginkgo v2 + Gomega** for integration tests (controller tests in `suite_test.go`)
- **Standard Go `testing`** for unit tests (most `*_test.go` files)
- **envtest** for integration tests (real API server, no real cluster)

### Test Helpers (create_helper_test.go)

Builder-pattern constructors — use these, don't create raw objects:

```go
// Velero objects
createBackup("name", "ns").phase(veleroapi.BackupPhaseCompleted).labels(map[string]string{...}).object
createSchedule("name", "ns").schedule("0 */6 * * *").phase(veleroapi.SchedulePhaseEnabled).object
createRestore("name", "ns").backupName("backup-1").phase(veleroapi.RestorePhaseCompleted).object

// ACM objects
createACMRestore("name", "ns").
  veleroManagedClustersBackupName("latest").
  veleroCredentialsBackupName("latest").
  veleroResourcesBackupName("latest").
  cleanupBeforeRestore(v1beta1.CleanupTypeRestored).
  object

createBackupSchedule("name", "ns").schedule("0 */6 * * *").object
createStorageLocation("name", "ns").phase(veleroapi.BackupStorageLocationPhaseAvailable).object
createManagedCluster("cluster1", false).object  // false = not local-cluster
createSecret("name", "ns", nil, nil, nil)        // (name, ns, data, labels, annotations)
createConfigMap("name", "ns", nil, nil)           // (name, ns, data, labels)

// Waiting helpers (for Ginkgo integration tests)
waitForRestorePhase(ctx, k8sClient, lookupKey, expectedPhase, timeout, interval)
waitForVeleroRestoreCount(ctx, k8sClient, ns, expectedCount, timeout, interval)
```

### CI Linting Rules (common failures)

| Linter | Rule | Limit | Fix |
|--------|------|-------|-----|
| `funlen` | Function length | 60 statements | Decompose into helper functions |
| `lll` | Line length | 120 chars | Break long lines, use multi-line struct literals |
| `goimports` | Import formatting | Strict | Run `goimports -w <file>` |
| `errcheck` | Unchecked errors | All returns | Handle or explicitly ignore with `//nolint:errcheck` |
| `misspell` | Spelling | US English | Fix typos |
| `unparam` | Unused params | All | Remove unused function parameters |

### Sonar Coverage

- `api/v1beta1/**` and `main.go` are **excluded** from Sonar analysis
- If Sonar reports 0% on new code: check if `go clean -cache -modcache` is in the CI config
  (see KNOWLEDGE_BASE.md CI section)
- Tests in `controllers/` are analyzed; tests in `api/` are not

### Writing New Tests — Patterns That Pass CI

**Unit test (standard Go, most functions):**
```go
func Test_myFunction(t *testing.T) {
    t.Parallel()
    tests := []struct {
        name     string
        args     /* ... */
        expected /* ... */
    }{
        {name: "happy path", args: /* ... */, expected: /* ... */},
        {name: "error case", args: /* ... */, expected: /* ... */},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := myFunction(tt.args)
            if result != tt.expected {
                t.Errorf("got %v, want %v", result, tt.expected)
            }
        })
    }
}
```

**Integration test (Ginkgo, controller tests — used in suite_test.go):**
```go
It("should do something", func() {
    // Create test objects using builder helpers
    restore := createACMRestore("test-restore", veleroNamespace.Name).
        veleroManagedClustersBackupName("latest").
        veleroCredentialsBackupName("latest").
        veleroResourcesBackupName("latest").
        cleanupBeforeRestore(v1beta1.CleanupTypeRestored).
        object
    Expect(k8sClient.Create(ctx, restore)).Should(Succeed())

    // Wait for expected state
    waitForRestorePhase(ctx, k8sClient, lookupKey, "Finished", timeout, interval)
})
```

**Test with fake client (for unit testing controller logic):**
```go
func Test_myControllerFunction(t *testing.T) {
    scheme := createScheduleTestScheme()  // or createUtilsTestScheme(true, true, true)
    client := fake.NewClientBuilder().
        WithScheme(scheme).
        WithObjects(
            createSecret("my-secret", "ns", nil, map[string]string{"key": "val"}, nil),
            createManagedCluster("cluster1", false).object,
        ).
        Build()

    ctx := context.Background()
    // ... call function, assert results
}
```

**Critical rules for tests:**
1. Each test function must be ≤ 60 statements (funlen). Decompose into helpers.
2. Each line ≤ 120 chars (lll). Use multi-line struct literals for long test cases.
3. Run `goimports -w` on test files after editing.
4. Handle all error returns (errcheck).
5. Use `//nolint:funlen` on the package declaration if the ENTIRE file needs it (e.g., `pre_backup_test.go`).

---

## Common Operations Quick Reference

### Cherry-pick to release branch

```bash
# From repo root
git fetch upstream
git checkout -b fix/my-fix-rhacm-2.17 upstream/release-2.17
git cherry-pick <commit-sha>
# If conflicts: resolve, then git cherry-pick --continue
make build && make vet && make lint && make test
git push <fork> fix/my-fix-rhacm-2.17
gh pr create --base release-2.17 --title "fix: ..." --body-file /tmp/pr_body.md
```

### Build and test locally

```bash
make build          # build binary
make test           # full test suite (includes manifests, generate, fmt, vet)
make lint           # golangci-lint
make manifests generate  # regenerate CRDs and deepcopy
```

### Deploy custom image to a cluster

```bash
# Build and push
make docker-build IMG=quay.io/<user>/cluster-backup-operator:test
docker push quay.io/<user>/cluster-backup-operator:test

# Scale down stock operator, deploy custom
oc scale deployment cluster-backup-chart-clusterbackup \
  -n open-cluster-management-backup --replicas=0
oc set image deployment/cluster-backup-chart-clusterbackup \
  cluster-backup=quay.io/<user>/cluster-backup-operator:test \
  -n open-cluster-management-backup
oc scale deployment cluster-backup-chart-clusterbackup \
  -n open-cluster-management-backup --replicas=1

# If stuck on leader election:
oc delete lease 58497677.cluster.management.io -n open-cluster-management-backup
```

### Common Jira operations

```bash
# Search for tickets
# Use Jira MCP: jira_search with JQL
# Example JQL: project = ACM AND component = "cluster-backup" AND status != Closed

# Transition ticket
# Use Jira MCP: jira_transition_issue

# Common transitions: New→In Progress, In Progress→Review, Review→Closed
```

---

## Gotchas and Traps (things that waste tokens if rediscovered)

1. **`docs/ARCHITECTURE.md` vs `docs/architecture.md` case collision** — both exist as separate
   tracked blobs on `main`. On case-insensitive filesystems (macOS), git shows phantom diffs.
   Workaround: use `git worktree add` from an existing clone, or work in `/tmp`.

2. **Container name is `cluster-backup`, not `manager`** — the MCH Helm chart names the container
   `cluster-backup`, not `manager` as kubebuilder defaults suggest.

3. **`createAutoImportSecret()` is a plain `Create`, not upsert** — if a secret already exists
   (even a stale one from a previous restore), the create silently fails and the old secret stays.

4. **Package-level slices in backup.go** — always copy before mutating.
   `processResourcesToBackup()` uses a local slice for this reason.

5. **`PartiallyFailed` Velero restores are often normal** — empty backup files cause this.
   Don't treat as hard errors.

6. **`local-cluster` exclusion must be checked in EVERY loop** — when adding `local-cluster`
   guards to a function with multiple loops (e.g., ClusterDeployment loop AND ClusterPool loop),
   audit all loops, not just the one you're touching.

7. **DCO sign-off required** — all commits need `Signed-off-by:` trailer. Use `--signoff` flag.

8. **`acknowledge-security-fixes-only` label** — needed for PRs targeting frozen z-stream branches.
   Create the label in the repo if it doesn't exist.

9. **`openshift-cherrypick-robot` stops at first failure** — when requesting multi-branch
   cherry-picks, if one fails, the rest are never attempted.

10. **Sonar's "conditional operators" rule** — only triggers for code in `controllers/`, not
    `api/v1beta1/` (excluded). If a function moves between these dirs across branches, Sonar
    behavior differs.

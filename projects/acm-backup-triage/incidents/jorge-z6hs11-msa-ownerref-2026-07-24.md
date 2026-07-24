# Incident: MSA token refresh permanently broken after restore (ownerRef error)

**Date investigated:** 2026-07-24 (night of 2026-07-23 US Eastern)
**Customer/reporter:** Jorge Lasquinha, #forum-acm-backupandrestore
**Investigator:** sahare, via live `oc` access to both hubs (customer granted temporary access)
**Status:** New finding, not yet filed as a Jira. Clusters may be torn down — this doc is the full evidence record.

## Environment

- ACM version (both hubs): **2.14.3** (`oc get mch -o jsonpath='{.status.currentVersion}'`)
- Failback (currently active/original) hub API: `https://api.zmrmhj4li872d14c4a.eastus.aroapp.io:6443`
- DR (currently passive) hub API: `https://api.umrpdhfyxd6dc0a91e.eastus.aroapp.io:6443`
- Managed clusters in question: `z6hs10` (ARO, imported/non-Hive), `z6hs11` (AKS, imported/non-Hive)
- BackupSchedule spec (both hubs, `schedule-acm` in `open-cluster-management-backup`):
  ```json
  {"managedServiceAccountTTL":"504h","paused":false/true,"useManagedServiceAccount":true,"veleroSchedule":"0 */2 * * *","veleroTtl":"336h"}
  ```
- Import strategy on failback hub: `autoImportStrategy: ImportOnly` (`import-controller-config` configmap, `multicluster-engine` ns)
- Restore history on failback hub (all `Finished`): `restore-acm-failback` (2026-07-21T13:15:37Z), `-teste-volta` (07-23T18:17:17Z), `-tonemaivaicurintia` (07-23T19:16:13Z), `-valida` (07-23T20:17:32Z), `-ultimo` (07-23T20:26:57Z), `-last` (07-24T01:46:47Z) — confirms multiple repeated failover/failback test cycles.
- Restore history on DR hub (all `Finished`): `restore-acm`, `-activate`, `-failback`, `-failback-2`, `-failback-night`, `-failback-tarde`, `-failbacka`, `-failbackteste`.

## Summary of finding

`ManagedServiceAccount` objects `auto-import-account` and `auto-import-account-pair` (created/managed by `cluster-backup-operator`'s `createMSA()` for imported clusters) get their **token Secret's `ownerReferences` stripped** across a Velero backup/restore cycle. The `managed-serviceaccount` addon controller can then never again update/refresh that secret, failing with:

```
TokenReported=False reason=TokenReportFailed
msg=failed to update the token secret: secrets "auto-import-account" is forbidden: cannot set an ownerRef on a resource you can't delete: , <nil>
```

This is a **live, reproducing-right-now** bug, confirmed identically on **both** hubs, for **both** managed clusters. It is NOT the "SA-UID mismatch" mechanism previously assumed (Cristian Ungureanu's case, KCS 7039710) — it's a distinct, more fundamental breakage: the token simply **stops refreshing at all** after any restore.

## Raw evidence

### Failback hub — auto-import-secret state

```
$ oc get secret auto-import-secret -n z6hs10 -o yaml
metadata:
  annotations:
    managedcluster-import-controller.open-cluster-management.io/keeping-auto-import-secret: ""
  creationTimestamp: "2026-07-24T01:48:32Z"
  labels:
    cluster.open-cluster-management.io/restore-auto-import-secret: "true"
  name: auto-import-secret
  namespace: z6hs10
  uid: e09002c7-c128-4d10-898f-f82798866466
type: Opaque

$ oc get secret auto-import-secret -n z6hs11
Error from server (NotFound): secrets "auto-import-secret" not found
```
(z6hs11's was already cleaned up — Jorge had manually created+applied a working `auto-import-secret` earlier from a live AKS kubeconfig, which is why the cluster is Joined/Available despite the MSA path being broken. See "current cluster status" below.)

### Failback hub — restore-acm-failback-last status messages (most recent cycle, 2026-07-24T01:46:47Z)

```json
["Skip MSA access token for secret (z6hs11:auto-import-account) no loger valid!",
 "Skip MSA access token for secret (z6hs11:auto-import-account-pair) no loger valid!",
 "Created auto-import-secret for (z6hs10)"]
```

### Failback hub — current cluster status (checked 2026-07-24T02:32:58Z)

```
z6hs10   JOINED=True   AVAILABLE=True
z6hs11   JOINED=True   AVAILABLE=True   (reconnected via Jorge's manual auto-import-secret, not via MSA)
```

### Failback hub — MSA token secrets (label `authentication.open-cluster-management.io/is-managed-serviceaccount`)

Current time at check: `2026-07-24T02:32:58Z`

| Namespace | Secret | Created | expirationTimestamp | lastRefreshTimestamp | Status |
|---|---|---|---|---|---|
| z6hs10 | auto-import-account | 2026-07-24T01:47:44Z | **2026-07-28T23:07:33Z** | 2026-07-18T23:07:33Z | Valid (~4.5 days left) |
| z6hs11 | auto-import-account | 2026-07-24T01:47:44Z | **2026-07-21T13:11:49Z** | 2026-07-20T13:11:49Z | **Expired 3 days ago** |
| z6hs11 | auto-import-account-pair | 2026-07-24T01:47:44Z | **2026-07-22T01:15:24Z** | 2026-07-21T01:15:24Z | **Expired 2 days ago** |

Note both z6hs10's and z6hs11's actual token durations (240h and 24h respectively, measured lastRefresh→expiry) do **not** match the current `BackupSchedule.spec.managedServiceAccountTTL: 504h` — both are stale generations minted under earlier/different settings, frozen since because refresh is broken (see below). This is consistent with the tokens never having been able to refresh forward to the current TTL setting since the bug started.

### Failback hub — ManagedServiceAccount CR spec (both show correct 504h, but broken status)

```
z6hs10 auto-import-account:        spec.rotation.validity: 504h0m0s
z6hs11 auto-import-account:        spec.rotation.validity: 504h0m0s
z6hs11 auto-import-account-pair:   spec.rotation.validity: 504h0m0s
```

### Failback hub — MSA CR status conditions (the actual bug)

```
$ oc get managedserviceaccount auto-import-account -n z6hs11 -o jsonpath='...'
TokenReported=False reason=TokenReportFailed
  msg=failed to update the token secret: secrets "auto-import-account" is forbidden: cannot set an ownerRef on a resource you can't delete: , <nil>

$ oc get managedserviceaccount auto-import-account -n z6hs10 -o jsonpath='...'
TokenReported=False reason=TokenReportFailed
  msg=failed to update the token secret: secrets "auto-import-account" is forbidden: cannot set an ownerRef on a resource you can't delete: , <nil>
```

Both clusters are **currently broken identically** — z6hs10 just hasn't run out of runway yet (valid until 2026-07-28).

### Failback hub — ownerReferences on the token secrets (empty — the actual defect)

```
z6hs10 auto-import-account:      ownerRefs=  (empty)
z6hs11 auto-import-account:      ownerRefs=  (empty)
z6hs11 auto-import-account-pair: ownerRefs=  (empty)
```
Both secrets carry Velero restore-provenance labels:
```
authentication.open-cluster-management.io/is-managed-serviceaccount: "true"
cluster.open-cluster-management.io/backup: "msa"
velero.io/backup-name: acm-credentials-schedule-20260724014128
velero.io/restore-name: restore-acm-failback-last-acm-credentials-schedule-2026072c01f0
```

### Failback hub — managed-serviceaccount addon health (addon itself is fine — this is not an addon-availability issue)

```
Both z6hs10 and z6hs11:
Progressing=False, Configured=True, RegistrationApplied=True,
ClusterCertificateRotated=True, ManifestApplied=True, Available=True
```

### DR hub — cross-check: identical bug reproduces there too

MSA `TokenReported` status across all managed clusters on the DR hub:

```
local-cluster application-manager           TokenReported=True
local-cluster klusterlet-addon-workmgr-log  TokenReported=True
z6hs10        application-manager           TokenReported=True
z6hs10        auto-import-account           TokenReported=False  (same ownerRef error)
z6hs10        klusterlet-addon-workmgr-log  TokenReported=True
z6hs11        application-manager           TokenReported=True
z6hs11        auto-import-account           TokenReported=False  (same ownerRef error)
z6hs11        auto-import-account-pair      TokenReported=False  (same ownerRef error)
z6hs11        klusterlet-addon-workmgr-log  TokenReported=True
```

**Key isolation:** on the exact same clusters, `application-manager` and `klusterlet-addon-workmgr-log` MSA secrets have healthy, populated `ownerReferences` and refresh fine. Only `auto-import-account`/`-pair` — the ones created by `cluster-backup-operator` — are broken. This rules out a hub-wide RBAC problem or general Velero ownerRef-stripping behavior; it's specific to these two objects/how they're created or backed up.

`lastTransitionTime` on the `TokenReportFailed` condition on the DR hub matches its own restore/activation timestamps (z6hs10: 2026-07-24T00:48:35Z, z6hs11: 2026-07-24T00:58:21Z) and has **not moved since** — confirms this is a permanently stuck state, not an intermittent/retrying failure.

DR hub's own `ManagedCluster` status for both clusters: `JOINED=true, AVAILABLE=Unknown` (expected — they're currently connected to the failback hub instead).

## Root cause hypothesis (not yet confirmed at code level — needs Foundation/MCE team)

Velero restores `auto-import-account`/`-pair` `ManagedServiceAccount` CRs and their token Secrets (both are included in ACM backups: MSA CR via `authentication.open-cluster-management.io` API group, token secret via `cluster.open-cluster-management.io/backup: msa` label). On restore, the token Secret's `ownerReferences` do not get correctly re-linked to the (possibly newly-recreated-with-different-UID) `ManagedServiceAccount` CR. When the `managed-serviceaccount` addon controller later tries to update that secret and (re-)establish the owner reference, the Kubernetes API server's `OwnerReferencesPermissionEnforcement` admission check rejects it — this specific error text is a known K8s admission message meaning the calling identity lacks `delete` permission on the object it's trying to reference as owner (or the reference is otherwise invalid post-restore).

This is a plausible bug in either:
1. `managed-serviceaccount` addon-framework (Foundation/MCE team) — doesn't handle re-establishing ownership after its CR/secret are restored by Velero, **or**
2. `cluster-backup-operator`'s own backup/restore labeling of these two specific objects — worth double-checking our own `createMSA()`/`updateMSAResources()` restore-item-action behavior doesn't itself interfere with ownerRef preservation (this is our own code, should self-audit before assuming it's 100% Foundation's bug).

## Ruled out — related but distinct Jira tickets (checked via Atlassian MCP tonight)

| Ticket | Status | Mechanism | Why it's not this bug |
|---|---|---|---|
| [ACM-31624](https://redhat.atlassian.net/browse/ACM-31624) | Closed, unreproduced | import-controller skips reimport when `ImportOnly` + stale `ManagedClusterImportSucceeded=True`, without checking `auto-import-secret`'s restore label first | Precondition requires an `auto-import-secret` with our restore label to already exist — never created for z6hs11 in the latest test, so this code path is never reached |
| [ACM-34619](https://redhat.atlassian.net/browse/ACM-34619) | Testing, fixed in main/release-5.0 (PR #1109) | work-agent's 4-min ManifestWork reconcile can overwrite `bootstrap-hub-kubeconfig` (on the **spoke**) back to the old hub before registration-agent restarts | Different resource (`bootstrap-hub-kubeconfig` on spoke vs. `auto-import-account` token on hub), different controller (work-agent vs. managed-serviceaccount), different failure signature (silent overwrite vs. explicit ownerRef rejection) |
| [ACM-38012](https://redhat.atlassian.net/browse/ACM-38012) | Testing, fixed this week (PR #1158) | Follow-on/incomplete-fix-fix for ACM-34619 — same mechanism, work-agent not matching resource kind correctly | Same reasoning as ACM-34619 — not the same bug class |

**Conclusion: tonight's finding is not documented anywhere in Jira currently.** It's a new, distinct, reproducible bug.

## What's needed if/when filing a Jira (have this ready before clusters are torn down)

- [x] Exact error message and condition (`TokenReportFailed`, captured above)
- [x] Confirmed on 2 independent hubs, 2 independent clusters — not a one-off
- [x] Isolated to `auto-import-account`/`-pair` specifically, not other MSA secrets on the same clusters
- [x] `ownerReferences` empty on affected secrets, populated on unaffected ones
- [x] `lastTransitionTime` proves it's stuck, not retrying
- [ ] **Not yet captured:** exact controller pod/logs producing this condition message (could not locate the specific pod in the 6h log window checked — `managed-serviceaccount-addon-agent` in `open-cluster-management-agent-addon` and `cluster-manager-addon-manager-controller` in `open-cluster-management-hub` were checked, no matches found; may need broader log search or a different component)
- [ ] **Not yet captured:** a full `oc get managedserviceaccount auto-import-account -n z6hs11 -o yaml` (complete object, not just conditions) for full spec/status/metadata history
- [ ] **Not yet captured:** whether this also affects other ACM versions (only confirmed on 2.14.3 so far)
- [ ] **Recommended before filing:** get a live capture of the actual K8s audit log / apiserver response for the failing update call, if audit logging is enabled, for definitive proof of which identity/RBAC is being denied

## Suggested customer-facing summary (for Jorge)

See separate response — short version: this is a genuine, newly-identified bug (not the previously-suspected SA-UID-mismatch or Hive-vs-imported theories), confirmed with direct evidence on both of his hubs, currently silently breaking MSA token refresh for imported clusters after any restore. z6hs10 is coasting on a token valid until July 28; it will hit the identical failure then unless fixed. Not yet in Jira — recommend filing given clusters may be torn down soon.

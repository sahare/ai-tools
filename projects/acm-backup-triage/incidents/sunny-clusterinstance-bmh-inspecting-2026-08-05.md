# Sunny — ClusterInstance premature restore drives BareMetalHost back into Inspecting (ACM-39330)

**Reporter:** Sunny, ~Aug 5-6 2026. ZTP/bare-metal fleet, active/passive DR with passive-sync
(`syncRestoreWithNewBackups: true`) enabled on the DR hub.

**Symptom:** After a DR failover (or even just routine passive-sync cycles, before any real
failover), `BareMetalHost` objects for ZTP-provisioned clusters flip back into `Inspecting` state —
as if the hardware were being re-discovered from scratch on already-installed clusters.

## Sunny's initial hypothesis (red herring) — singular vs. plural resource name

Sunny noticed `BareMetalHost` was listed in **singular** form under
`Restore.spec.restoreStatus.includedResources` and hypothesized this was the bug (Velero not
matching the resource because of a case/plurality mismatch).

**Why this is not the cause:**
- Velero's resource matching goes through the Kubernetes RESTMapper, which resolves resource names
  by matching singular *or* plural forms case-insensitively against the discovered API resources.
  `BareMetalHost` (singular) and `baremetalhosts` (plural) both resolve to the same GVR.
- `restoreStatus.includedResources` only controls whether a resource's **`.status` subresource**
  gets restored — it has zero effect on whether the object itself is created/updated during a
  restore. This field can't be the reason a *new* BMH shows up in `Inspecting`.
- Confirmed by code reading `controllers/restore.go`/`restore_post.go` — no singular/plural
  special-casing exists anywhere in this repo's resource-name handling; it's delegated entirely to
  Velero/RESTMapper.

**Verdict: red herring.** Don't spend more time chasing resource-name casing for this class of bug.

## Actual root cause — two separate exposures

`ClusterInstance` (`siteconfig.open-cluster-management.io/v1alpha1`) is the CR that drives Day-1
manifest rendering for ZTP/bare-metal managed clusters. Its controller **re-renders Day-1 manifests
on every reconcile** — including `BareMetalHost`, setting fields like `spec.externallyProvisioned`
and the `inspect.metal3.io` annotation back to their Day-1 defaults.

Before this fix, `ClusterInstance` (like `AgentClusterInstall` and other
`agent-install.openshift.io`/generic resources) was restored **unconditionally** via
`acm-resources-schedule` — it was NOT in the activation-gated set
(`includedActivationAPIGroupsByName`, `controllers/backup.go`). That produces two distinct exposures:

1. **Passive-sync exposure:** on a passive hub running `syncRestoreWithNewBackups: true` with
   `veleroManagedClustersBackupName: skip`, `ClusterInstance` still gets restored/updated on every
   sync cycle (it's not gated by the managed-clusters skip/latest logic at all). The SiteConfig
   controller reconciles the restored `ClusterInstance`, re-renders Day-1 manifests, and drives an
   already-installed cluster's `BareMetalHost` back into `Inspecting` — with **no actual failover
   having happened**.
2. **Failover-ordering exposure:** even during a real failover (`latest`), `ClusterInstance` has no
   explicit priority in `ResourceTypePriority` (`controllers/restore.go`) and its restored object
   doesn't carry `.status` (Velero doesn't restore status by default), so the SiteConfig controller
   sees what looks like a fresh/incomplete `ClusterInstance` and can race ahead of `BareMetalHost`
   restoration, re-triggering Day-1 rendering before the hub's view of hardware state catches up.

## Fix delivered (Exposure #1 only)

Added `"siteconfig.open-cluster-management.io"` to `includedActivationAPIGroupsByName` in
`controllers/backup.go` — this routes `ClusterInstance` into the **managed-clusters activation
tier**, same as `agent-install.openshift.io` resources. Effect:
- Passive sync (`skip`) no longer touches `ClusterInstance` at all — it's excluded exactly like
  other activation-gated resources.
- Only an actual failover (`veleroManagedClustersBackupName: latest`) restores/updates it.

**PR:** [stolostron/cluster-backup-operator#1685](https://github.com/stolostron/cluster-backup-operator/pull/1685)
(merged to `main`), cherry-picked to `release-2.17` as
[#1687](https://github.com/stolostron/cluster-backup-operator/pull/1687) (merged).

**Exposure #2 (failover-ordering / status restoration) is NOT fixed by this PR** — it needs
SiteConfig/ZTP team input on whether `ClusterInstance.status` should be included in the backup, or
whether the SiteConfig controller itself should tolerate re-reconciling an already-installed
cluster gracefully. Flagged on the Jira, tagging the SiteConfig team; response still pending as of
Aug 6 2026.

**Full unit test coverage added:** `Test_processResourcesToBackup_routesClusterInstanceToActivationResources`
in `controllers/backup_test.go`. Also live end-to-end tested (not just unit tests) on a fresh
OCP 4.21 / ACM 5.0.0-186 hub — built a combined operator image with both PR #1684 and #1685's
changes, deployed it, and walked through: ClusterInstance NOT restored during skip-mode sync,
ClusterInstance IS restored on latest-mode activation, BareMetalHost activation-label workaround
still round-trips normally. All passed. One environmental `hostedclusters.hypershift.openshift.io`
Velero error was found and ruled out as unrelated (pre-existing test-cluster HyperShift CRD issue,
neither PR touches HostedCluster or Velero discovery).

**Jira:** [ACM-39330](https://redhat.atlassian.net/browse/ACM-39330)

## Sunny's proposed manual workaround — evaluated, use with caution

While waiting for a real fix, Sunny proposed patching around the SiteConfig re-render directly:

```bash
# Prevent SiteConfig controller from re-rendering BareMetalHost manifests
oc patch clusterinstance <name> -n <ns> --type merge \
  -p '{"spec":{"suppressedManifests":["BareMetalHost"]}}'

# Mark the BMH as externally provisioned so metal3 stops trying to (re-)provision it
oc patch bmh <name> -n <ns> --type merge \
  -p '{"spec":{"externallyProvisioned":true}}'
```

**Both commands are technically legitimate, real fields** (`ClusterInstance.spec.suppressedManifests`,
`BareMetalHost.spec.externallyProvisioned`) — not made up. But two important caveats surfaced when
evaluating them for production use:

1. **`externallyProvisioned: true` is NOT reversible today.** Confirmed against upstream metal3
   documentation and an open upstream issue — once set, there is no supported path back to
   metal3-managed provisioning for that host. This makes it a one-way door: fine as a last resort
   if impact is severe, but not something to apply routinely or "just in case." Recommended Sunny
   wait for the real fix unless actively blocked by customer impact.
2. **Order matters and existing values should be checked first** — patch `suppressedManifests`
   *before* `externallyProvisioned` (stop the controller from fighting the change first), and check
   whether either field already has a non-default value before overwriting it wholesale (merge
   patches replace list fields entirely, not additively).

## `spec.image` question for ZTP hosts (Sunny's follow-up, unresolved)

Sunny also asked whether `BareMetalHost.spec.image` needs to be explicitly set/preserved for
already-installed ZTP hosts (relevant if going the `externallyProvisioned` route, since some metal3
codepaths reference `spec.image` even for externally-provisioned hosts as future-proofing).
**No confirmed answer for ZTP-specific hosts** — advised Sunny to check whether the field already
has a populated value on the live BMH before touching it, and treat empty/absent as a separate,
lower-confidence question to raise with the SiteConfig/metal3 owners rather than guessing.

## Process/tooling notes from working this ticket

- **`openshift-cherrypick-robot` stops at the first failing branch in a multi-branch request.**
  Commenting `/cherry-pick release-2.16 release-2.15 release-2.14` on #1685 only produced ONE bot
  reply — a failure for `release-2.16` (conflict in `controllers/backup_test.go`) — and it never
  attempted `release-2.15`/`release-2.14` at all. Contrast with requesting a single branch
  (`/cherry-pick release-2.17`), which succeeded cleanly and opened #1687 automatically. **Lesson:**
  when a multi-branch cherry-pick request fails, don't assume the other branches also failed or
  succeeded — the bot silently never tried them. Either request branches one at a time, or check
  for a bot comment per branch and manually cherry-pick any that are missing a response.
- **Backport branch selection reasoning for this fix:** the fully-supported window is "current
  release + 2 previous" (at the time of writing: 2.17 current, so 2.15/2.16/2.17 fully supported,
  no special justification needed for a normal bug backport). 2.13 is an EUS release — backports
  there need the same urgent-priority justification process used for other EUS backport requests
  (see release-management conversation), not a routine cherry-pick. 2.11 is also EUS but is the
  *older* EUS term and doesn't cover the OCP versions relevant to bare-metal/ZTP customers on this
  bug — not worth targeting. 2.12/2.14 have ambiguous support-phase status (older, non-EUS,
  possibly Maintenance-only) — low-cost to attempt but not guaranteed to be accepted by OWNERS.
- **Why "fix merged to main + cherry-picked to release-2.17" doesn't automatically help every
  customer:** always cross-check the *customer's actual OCP version* against that release's
  OCP/ACM support matrix before assuming a backport is done. In this case ACM 2.17 does not support
  OCP 4.18 at all, so a customer on OCP 4.18 needs the fix in 2.14 or 2.15, not 2.17 — the version
  of ACM that "sounds newest" isn't always the one the customer can actually run.

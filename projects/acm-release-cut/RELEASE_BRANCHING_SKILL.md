# ACM Release Branch Cut — Operator Repo Tekton & CI Changes

This skill documents all the steps needed when cutting a new ACM release branch for the cluster-backup-operator (and volsync-addon-controller). It covers tekton file changes, prow configuration, and coordination with the new automated fast-forwarding system.

**Last updated:** April 2026 (ACM 5.0 release process — reflects new automated branch creation and fast-forwarding)

## When This Skill Is Needed

When ACM cuts a new release (e.g., 2.17 → 5.0). Branch day is the day after feature freeze.

## What Changed for ACM 5.0

Starting with ACM 5.0, the process has changed significantly:

- **Branches are created automatically** by a new periodic cron job (every 2 hours) — teams no longer create release branches manually
- The cron job fast-forwards from main to release-5.0 (and release-5.1)
- **Teams are responsible for:** porting tekton files, stopping old fast-forwarding, cleaning up branches
- **ART transition (future):** Eventually the ART (OpenShift build) team will take over Dockerfiles, tekton pipelines, and fast-forwarding entirely
- **Do NOT merge** auto-generated Konflux PRs — they are not compatible with our common pipelines

Source: Konflux Lunch and Learn (April 21, 2026), PR https://github.com/openshift/release/pull/78109

## Terminology

| Term | Meaning |
|------|---------|
| **NEW_VERSION** | The new release being cut (e.g., `5.0`) |
| **PREV_VERSION** | The previous release (e.g., `2.17`) |
| **Tekton push file** | Triggers Konflux build on merge to a branch |
| **Tekton PR file** | Triggers Konflux build on pull requests |
| **CEL expression** | `on-cel-expression` in tekton files that controls which branch triggers the pipeline |
| **Fast-forward** | Auto-merge from main → release branch (now handled by cron job for 5.0+) |
| **ART** | OpenShift build team that will eventually own Dockerfiles and tekton pipelines |

## File Naming Convention

Tekton files follow this pattern:
```
.tekton/cluster-backup-operator-acm-{VERSION}-push.yaml
.tekton/cluster-backup-operator-acm-{VERSION}-pull-request.yaml
```

Version examples: `217` for 2.17, `50` for 5.0, `216` for 2.16.

## Pre-Branch-Day State

On **main** (fast-forwarding to both release-2.17 via Prow and release-5.0 via new cron):
```
.tekton/
  cluster-backup-operator-acm-{PREV_VERSION}-push.yaml          # push targets: release-{PREV_VERSION}
  cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml   # PR targets: main || release-{PREV_VERSION}
  cluster-backup-operator-acm-{NEW_VERSION}-push.yaml            # push targets: main
  cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml    # PR targets: main || release-{NEW_VERSION}
```

The **release-{PREV_VERSION}** branch is identical to main (via Prow fast-forward), including the NEW_VERSION tekton files that shouldn't be there.

## Branch Day Checklist (Thursday — Feature Freeze + 1)

### Step 1: Verify NEW_VERSION tekton files are on main

The NEW_VERSION tekton files should already be merged to main (created by Konflux and ported earlier). Verify:

```bash
ls .tekton/cluster-backup-operator-acm-{NEW_VERSION}-*.yaml
```

If not present, port them from the PREV_VERSION files:
- Copy PREV_VERSION tekton files, rename to NEW_VERSION
- Update: application name, component name, ACM_VERSION build arg, output-image, service account name
- Push file: set `target_branch == "main"`
- PR file: set `target_branch == "main" || target_branch == "release-{NEW_VERSION}"`

**For ACM 5.0:** Already done via PR #1581 (cluster-backup-operator) and PR #1302 (volsync-addon-controller).

### Step 2: Verify versioning is updated

Check these files for version references:
```bash
cat COMPONENT_VERSION
grep ACM_VERSION Dockerfile.rhtap
```

Update if needed to reflect the new version.

### Step 3: Do NOT merge auto-generated Konflux PRs

Konflux will auto-generate PRs for the new branch. **Close them without merging** — they are not compatible with our common pipelines from `stolostron/konflux-build-catalog`.

### Step 4: Stop Prow fast-forward to PREV_VERSION

On branch day or soon after, disable the Prow fast-forward from main → release-{PREV_VERSION}.

In `openshift/release` repo, the main CI config has:
```yaml
- as: fast-forward
  postsubmit: true
  steps:
    env:
      DESTINATION_BRANCH: release-{PREV_VERSION}
    workflow: ocm-ci-fastforward
```

Either remove this job or update it. The new cron job handles fast-forwarding to NEW_VERSION, so the Prow fast-forward is only needed for PREV_VERSION during the transition.

**Note:** Validate that the new cron job is actually running and fast-forwarding to release-{NEW_VERSION} before disabling the Prow fast-forward.

### Step 5: Clean up release-{PREV_VERSION} branch

After fast-forwarding to PREV_VERSION is stopped, remove the NEW_VERSION tekton files that were accidentally fast-forwarded:

```bash
git checkout release-{PREV_VERSION}
git pull upstream release-{PREV_VERSION}
git rm .tekton/cluster-backup-operator-acm-{NEW_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml
```

Update PREV_VERSION PR file — remove `main` from CEL (since main no longer fast-forwards here):
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-{PREV_VERSION}")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-{PREV_VERSION}"
```

Keep PREV_VERSION push file as-is — already targets `release-{PREV_VERSION}`.

```bash
git add .tekton/
git commit -s -m "Clean up release-{PREV_VERSION}: remove {NEW_VERSION} tekton files, narrow PR CEL to release branch only"
git push upstream release-{PREV_VERSION}
```

### Step 6: Update tekton files on release-{NEW_VERSION} branch

Once the new cron job has created and fast-forwarded to release-{NEW_VERSION}, update the tekton files on that branch:

**Update NEW_VERSION push file** — change target from `main` to `release-{NEW_VERSION}`:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "main"

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "release-{NEW_VERSION}"
```

**Update NEW_VERSION PR file** — remove `main` from CEL:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-{NEW_VERSION}")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-{NEW_VERSION}"
```

**Remove PREV_VERSION tekton files** from the new branch:
```bash
git checkout release-{NEW_VERSION}
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml
git add .tekton/
git commit -s -m "Update tekton files for release-{NEW_VERSION} branch"
git push upstream release-{NEW_VERSION}
```

**Important (from Tesshu):** This step must be done after the real branching and after fast-forwarding from main to release-{NEW_VERSION} is configured. Otherwise the cron job will overwrite your changes with main's version.

### Step 7: Clean up main branch (after fast-forward to PREV_VERSION stops)

Remove PREV_VERSION tekton files from main:
```bash
git checkout main
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml
git commit -s -m "Remove {PREV_VERSION} tekton files from main"
git push upstream main
```

Keep NEW_VERSION files on main as-is — they're correct for ongoing development:
- Push targets `main` (correct — cron job fast-forwards to release-{NEW_VERSION})
- PR targets `main || release-{NEW_VERSION}` (correct)

### Step 8: Prow configuration for release-{NEW_VERSION} (openshift/release repo)

Create prow configuration for the new branch if ready to deliver content. This includes:

**CI config** (`ci-operator/config/stolostron/cluster-backup-operator/`):
- Create `stolostron-cluster-backup-operator-release-{NEW_VERSION}.yaml`
- Configure: build, unit-tests, sonar, crd-and-gen-files-check, image mirror

**Branch protection** (`core-services/prow/02_config/stolostron/cluster-backup-operator/_prowconfig.yaml`):
- Add `release-{NEW_VERSION}` entry with required status checks and PR review requirements

**Update main CI config:**
- Update fast-forward destination if still using Prow fast-forward
- Update promotion version

Use `acm-cut-release.py` for automation of these steps, or do manually.

```bash
cd /path/to/openshift/release
make update
```

## Post-Cut State (What It Should Look Like After)

### main branch
```
.tekton/
  cluster-backup-operator-acm-{NEW_VERSION}-push.yaml          # push targets: main
  cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml   # PR targets: main || release-{NEW_VERSION}
```

### release-{NEW_VERSION} branch
```
.tekton/
  cluster-backup-operator-acm-{NEW_VERSION}-push.yaml          # push targets: release-{NEW_VERSION}
  cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml   # PR targets: release-{NEW_VERSION}
```

### release-{PREV_VERSION} branch
```
.tekton/
  cluster-backup-operator-acm-{PREV_VERSION}-push.yaml          # push targets: release-{PREV_VERSION}
  cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml   # PR targets: release-{PREV_VERSION}
```

## Summary Checklist

| # | When | Branch | Action |
|---|------|--------|--------|
| 1 | Branch day | main | Verify NEW_VERSION tekton files exist |
| 2 | Branch day | main | Verify versioning updated (COMPONENT_VERSION, Dockerfile.rhtap) |
| 3 | Branch day | — | Do NOT merge auto-generated Konflux PRs |
| 4 | Branch day or soon after | openshift/release | Stop Prow fast-forward to PREV_VERSION |
| 5 | After ff stops | release-{PREV_VERSION} | Remove NEW_VERSION tekton files + narrow PREV_VERSION PR CEL |
| 6 | After ff configured | release-{NEW_VERSION} | Update NEW_VERSION push/PR CEL + remove PREV_VERSION tekton files |
| 7 | After ff stops | main | Remove PREV_VERSION tekton files |
| 8 | When ready | openshift/release | Create prow CI config + branch protection for release-{NEW_VERSION} |

## Timing Notes

- **Step 1-3:** Do on branch day (Thursday)
- **Step 4:** Do on branch day or very soon after — validate new cron job is working first
- **Step 5:** Do after Prow fast-forward to PREV_VERSION is confirmed stopped
- **Step 6:** Do after new cron job is fast-forwarding to release-{NEW_VERSION} — be careful not to do this while cron is still overwriting the branch with main content
- **Step 7:** Do after Step 4 — otherwise PREV_VERSION files on main would be fast-forwarded back to release-{PREV_VERSION}
- **Step 8:** Can be done in parallel once branch exists

## Future: ART Transition

The ART (OpenShift build) team will eventually take over:
- Dockerfiles
- Tekton pipelines
- Fast-forwarding

Once this happens, Branch Day will be significantly simpler for development teams. Timeline TBD — follow up in the ART sync calls or ACM Konflux initiative channel.

## Applies To

- `stolostron/cluster-backup-operator`
- `stolostron/volsync-addon-controller` (same pattern, different file names)

## Historical Reference

| Release | Key Commits / PRs |
|---------|------------------|
| 2.15 → 2.16 | `e26adc44` (add 216 tekton), `fa0bba2e` (remove 215 from main/2.16), `0ade7e07` (update 215 branch) |
| 2.16 → 2.17 | `8bb1b961` (add 217 tekton), `d79b3ebc` (narrow 216 PR to release-2.16 only) |
| 2.17 → 5.0 | PR #1581 (add 50 tekton to main), new automated cron job for fast-forwarding |

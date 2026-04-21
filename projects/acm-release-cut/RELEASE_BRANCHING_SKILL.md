# ACM Release Branch Cut — Operator Repo Tekton & CI Changes

This skill documents all the steps needed when cutting a new ACM release branch for the cluster-backup-operator (and volsync-addon-controller). It covers both the operator repo tekton file changes and the openshift/release CI changes.

## When This Skill Is Needed

When ACM cuts a new release (e.g., 2.17 → 5.0), the following must happen:
1. A new release branch is created in the operator repo
2. Tekton files are updated across three branches (new release, main, previous release)
3. CI configuration is updated in the openshift/release repo

## Terminology

| Term | Meaning |
|------|---------|
| **NEW_VERSION** | The new release being cut (e.g., `5.0`) |
| **PREV_VERSION** | The previous release (e.g., `2.17`) |
| **Tekton push file** | Triggers Konflux build on merge to a branch |
| **Tekton PR file** | Triggers Konflux build on pull requests |
| **CEL expression** | `on-cel-expression` in tekton files that controls which branch triggers the pipeline |
| **Fast-forward** | Post-submit job that auto-merges main → release branch |

## File Naming Convention

Tekton files follow this pattern:
```
.tekton/cluster-backup-operator-acm-{VERSION}-push.yaml
.tekton/cluster-backup-operator-acm-{VERSION}-pull-request.yaml
```

Version examples: `217` for 2.17, `50` for 5.0, `216` for 2.16.

## Pre-Cut State (What It Looks Like Before Branching)

On **main** (which fast-forwards to PREV_VERSION branch):
```
.tekton/
  cluster-backup-operator-acm-{PREV_VERSION}-push.yaml        # push targets: release-{PREV_VERSION}
  cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml # PR targets: main || release-{PREV_VERSION}
  cluster-backup-operator-acm-{NEW_VERSION}-push.yaml          # push targets: main
  cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml   # PR targets: main || release-{NEW_VERSION}
```

The PREV_VERSION branch is identical to main (via fast-forward).

## Step-by-Step: Operator Repo Changes

### Step 1: Create the new release branch

```bash
git fetch upstream main
git checkout -b release-{NEW_VERSION} upstream/main
git push upstream release-{NEW_VERSION}
```

### Step 2: Update tekton files on `release-{NEW_VERSION}` branch

**Remove PREV_VERSION tekton files** (they don't belong on the new branch):
```bash
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml
```

**Update NEW_VERSION push file** — change target from `main` to `release-{NEW_VERSION}`:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "main"

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "release-{NEW_VERSION}"
```

**Update NEW_VERSION PR file** — remove `main` from the CEL expression:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-{NEW_VERSION}")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-{NEW_VERSION}"
```

```bash
git add .tekton/
git commit -s -m "Update tekton files for release-{NEW_VERSION} branch"
git push upstream release-{NEW_VERSION}
```

### Step 3: Update tekton files on `main` branch (after fast-forward to PREV_VERSION stops)

**Remove PREV_VERSION tekton files** from main:
```bash
git checkout main
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{PREV_VERSION}-pull-request.yaml
git commit -s -m "Remove {PREV_VERSION} tekton files from main"
```

**Keep NEW_VERSION files as-is** on main — they already have:
- Push targeting `main` (correct for ongoing development)
- PR targeting `main || release-{NEW_VERSION}` (correct)

### Step 4: Update tekton files on `release-{PREV_VERSION}` branch

**Remove NEW_VERSION tekton files** (they don't belong on the old branch):
```bash
git checkout release-{PREV_VERSION}
git rm .tekton/cluster-backup-operator-acm-{NEW_VERSION}-push.yaml
git rm .tekton/cluster-backup-operator-acm-{NEW_VERSION}-pull-request.yaml
```

**Update PREV_VERSION PR file** — remove `main` from CEL (since main no longer fast-forwards here):
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-{PREV_VERSION}")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-{PREV_VERSION}"
```

**Keep PREV_VERSION push file as-is** — already targets `release-{PREV_VERSION}`.

```bash
git add .tekton/
git commit -s -m "Update tekton files for release-{PREV_VERSION} branch only"
git push upstream release-{PREV_VERSION}
```

## Step-by-Step: openshift/release Repo Changes

Use the `acm-cut-release.py` automation script or do manually:

### Step 5: Update main CI config

In `ci-operator/config/stolostron/cluster-backup-operator/stolostron-cluster-backup-operator-main.yaml`:
- Update promotion: `name: "{PREV_VERSION}"` → `name: "{NEW_VERSION}"`
- Update fast-forward: `DESTINATION_BRANCH: release-{PREV_VERSION}` → `DESTINATION_BRANCH: release-{NEW_VERSION}`

### Step 6: Enable PREV_VERSION promotion

In `stolostron-cluster-backup-operator-release-{PREV_VERSION}.yaml`:
- Remove `disabled: true` from the promotion section

### Step 7: Create NEW_VERSION release config

Copy PREV_VERSION config and update:
- Branch reference: `release-{PREV_VERSION}` → `release-{NEW_VERSION}`
- Add `disabled: true` to promotion (until release is GA)
- Update version references

### Step 8: Add branch protection for release-{NEW_VERSION}

In `core-services/prow/02_config/stolostron/cluster-backup-operator/_prowconfig.yaml`:
- Add `release-{NEW_VERSION}` branch protection entry with:
  - `protect: true`
  - `required_pull_request_reviews: dismiss_stale_reviews: true, required_approving_review_count: 1`
  - Required status checks (images, pr-image-mirror, sonar, unit-tests, crd-and-gen-files-check, Konflux checks)

### Step 9: Run `make update` in the release repo

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

| # | Branch | Action | Files |
|---|--------|--------|-------|
| 1 | — | Create `release-{NEW_VERSION}` branch from main | — |
| 2 | `release-{NEW_VERSION}` | Remove PREV_VERSION tekton files | Delete 2 files |
| 3 | `release-{NEW_VERSION}` | Update NEW_VERSION push: `main` → `release-{NEW_VERSION}` | Edit 1 file |
| 4 | `release-{NEW_VERSION}` | Update NEW_VERSION PR: remove `main` from CEL | Edit 1 file |
| 5 | `main` | Remove PREV_VERSION tekton files | Delete 2 files |
| 6 | `release-{PREV_VERSION}` | Remove NEW_VERSION tekton files | Delete 2 files |
| 7 | `release-{PREV_VERSION}` | Update PREV_VERSION PR: remove `main` from CEL | Edit 1 file |
| 8 | openshift/release | Update main CI (promotion + fast-forward destination) | Edit 1 file |
| 9 | openshift/release | Enable PREV_VERSION promotion | Edit 1 file |
| 10 | openshift/release | Create NEW_VERSION release config | New 1 file |
| 11 | openshift/release | Add NEW_VERSION branch protection | Edit 1 file |
| 12 | openshift/release | Run `make update` | — |

## Timing Notes

- Steps 2-4 (release-{NEW_VERSION} branch) can be done immediately after branch creation
- Step 5 (main cleanup) should happen after fast-forward from PREV_VERSION to main is stopped
- Steps 6-7 (release-{PREV_VERSION} cleanup) should happen after fast-forward stops
- Steps 8-12 (openshift/release) can be done in parallel using `acm-cut-release.py`

## Applies To

- `stolostron/cluster-backup-operator`
- `stolostron/volsync-addon-controller` (same pattern, different file names)

## Historical Reference

| Release | Key Commits |
|---------|------------|
| 2.16 → 2.17 | `8bb1b961` (add 217 tekton), `d79b3ebc` (narrow 216 PR to release-2.16 only) |
| 2.15 → 2.16 | `e26adc44` (add 216 tekton), `fa0bba2e` (remove 215 from main/release-2.16), `0ade7e07` (update 215 branch) |
| 2.17 → 5.0 | `bc505be2` (add 50 tekton to main) — pending: branch cut and updates |

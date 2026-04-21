# Branch Day Runbook — ACM 5.0

**Date:** Thursday (April 24, 2026)
**Previous release:** 2.17
**New release:** 5.0
**Repos:** cluster-backup-operator, volsync-addon-controller

## Current State (as of April 22, 2026)

### cluster-backup-operator main branch
| File | CEL Target |
|------|-----------|
| `acm-217-push` | `release-2.17` |
| `acm-217-pull-request` | `main \|\| release-2.17` |
| `acm-50-push` | `main` |
| `acm-50-pull-request` | `main \|\| release-5.0` |

- `COMPONENT_VERSION`: `2.6.0`
- `Dockerfile.rhtap ACM_VERSION`: passed as build arg (set in tekton file: `ACM_VERSION=5.0`)
- `release-5.0` branch: **does not exist yet** (cron job will create it Thursday)
- `release-2.17` branch: has both `acm-217` and `acm-50` tekton files (from fast-forward)

### openshift/release repo
- Prow fast-forward: `DESTINATION_BRANCH: release-2.17` (still active)
- No `release-5.0` CI config exists yet
- No `release-5.0` branch protection exists yet

---

## Thursday: Branch Day Steps

### Step 1: Verify acm-50 tekton files on main ✅ ALREADY DONE

PR #1581 already merged. Files exist:
- `.tekton/cluster-backup-operator-acm-50-push.yaml` (targets `main`)
- `.tekton/cluster-backup-operator-acm-50-pull-request.yaml` (targets `main || release-5.0`)

**No action needed.**

### Step 2: Verify versioning

```bash
# On cluster-backup-operator main
cat COMPONENT_VERSION
# Currently 2.6.0 — check if this needs updating for 5.0

grep "ACM_VERSION" .tekton/cluster-backup-operator-acm-50-push.yaml
# Should show: ACM_VERSION=5.0 ✅
```

**Action:** Check with team if `COMPONENT_VERSION` needs updating.

### Step 3: Do NOT merge auto-generated Konflux PRs

Watch for PRs from `red-hat-konflux[bot]` — close them without merging.

### Step 4: Verify release-5.0 branch is created by cron job

```bash
git fetch upstream
git branch -r | grep release-5.0
```

The cron job should create `release-5.0` automatically on Thursday. Verify it exists before proceeding to later steps.

---

## Soon After Branch Day (Friday or next week)

### Step 5: Stop Prow fast-forward to release-2.17

In the `openshift/release` repo, update the main CI config:

File: `ci-operator/config/stolostron/cluster-backup-operator/stolostron-cluster-backup-operator-main.yaml`

Either remove the fast-forward job or update it:
```yaml
# REMOVE or COMMENT OUT:
- as: fast-forward
  postsubmit: true
  steps:
    env:
      DESTINATION_BRANCH: release-2.17
    workflow: ocm-ci-fastforward
```

**Note:** Verify the new cron job is successfully fast-forwarding to release-5.0 before disabling this.

Do the same for volsync-addon-controller if applicable.

### Step 6: Clean up release-2.17 branch

```bash
git fetch upstream
git checkout -b cleanup-2.17 upstream/release-2.17

# Remove acm-50 tekton files (shouldn't be on 2.17)
git rm .tekton/cluster-backup-operator-acm-50-push.yaml
git rm .tekton/cluster-backup-operator-acm-50-pull-request.yaml
```

Update `acm-217-pull-request.yaml` — narrow CEL to release-2.17 only:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-2.17")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-2.17"
```

```bash
git add .tekton/
git commit -s -m "Clean up release-2.17: remove acm-50 tekton files, narrow acm-217 PR CEL"
# Push to fork, create PR against upstream/release-2.17
git push origin cleanup-2.17
```

### Step 7: Update release-5.0 branch

**Wait until:** The cron job has created and populated release-5.0 with main's content.

```bash
git fetch upstream
git checkout -b update-5.0 upstream/release-5.0

# Remove acm-217 tekton files (shouldn't be on 5.0)
git rm .tekton/cluster-backup-operator-acm-217-push.yaml
git rm .tekton/cluster-backup-operator-acm-217-pull-request.yaml
```

Update `acm-50-push.yaml` — change target from `main` to `release-5.0`:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "main"

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "push" && target_branch == "release-5.0"
```

Update `acm-50-pull-request.yaml` — narrow CEL to release-5.0 only:
```yaml
# BEFORE:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-5.0")

# AFTER:
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-5.0"
```

```bash
git add .tekton/
git commit -s -m "Update tekton files for release-5.0 branch"
# Push to fork, create PR against upstream/release-5.0
git push origin update-5.0
```

**⚠️ Important (from Tesshu):** The cron job fast-forwards main → release-5.0 every 2 hours. If you push this change to release-5.0 and the cron runs before your PR is merged, it will overwrite your changes with main's version. Coordinate timing — either:
- Merge this quickly after a cron cycle, OR
- Wait until the cron is configured to stop fast-forwarding to 5.0 for this repo

### Step 8: Clean up main branch

After Prow fast-forward to release-2.17 is confirmed stopped:

```bash
git checkout main
git pull upstream main

# Remove acm-217 tekton files
git rm .tekton/cluster-backup-operator-acm-217-push.yaml
git rm .tekton/cluster-backup-operator-acm-217-pull-request.yaml

git commit -s -m "Remove acm-217 tekton files from main"
# Push to fork, create PR against upstream/main
git push origin cleanup-main
```

### Step 9: Create prow config for release-5.0 (openshift/release)

Use `acm-cut-release.py` or manually:

```bash
python3 projects/acm-release-cut/acm-cut-release.py \
  --new-version 5.0 \
  --repos cluster-backup-operator volsync-addon-controller \
  --release-repo /path/to/openshift/release \
  --dry-run
```

This creates:
- `stolostron-cluster-backup-operator-release-5.0.yaml` CI config
- Branch protection entry in `_prowconfig.yaml`
- Updates main CI promotion version
- Enables release-2.17 promotion

Then:
```bash
cd /path/to/openshift/release
make update
```

---

## Verification Checklist

After all steps are complete, verify:

| Branch | Tekton Files | Push Targets | PR Targets |
|--------|-------------|-------------|------------|
| **main** | `acm-50-*` only | `main` | `main \|\| release-5.0` |
| **release-5.0** | `acm-50-*` only | `release-5.0` | `release-5.0` |
| **release-2.17** | `acm-217-*` only | `release-2.17` | `release-2.17` |

```bash
# Verify main
git show upstream/main:.tekton/

# Verify release-5.0
git show upstream/release-5.0:.tekton/

# Verify release-2.17
git show upstream/release-2.17:.tekton/
```

---

## Repeat for volsync-addon-controller

Same steps, different file names:
- `volsync-addon-controller-acm-50-push.yaml`
- `volsync-addon-controller-acm-50-pull-request.yaml`
- `volsync-addon-controller-acm-217-push.yaml`
- `volsync-addon-controller-acm-217-pull-request.yaml`

PR #1302 already merged the acm-50 files to main.

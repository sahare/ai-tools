# ACM Release Branch Cut — Operator Repo Tekton & CI Changes

This skill documents all the steps needed when cutting a new ACM release branch for operator repos (cluster-backup-operator, volsync-addon-controller, and similar). It covers tekton file changes and openshift/release CI configuration.

**Last updated:** April 25, 2026 (ACM 5.0 release — verified process)

## How the New Process Works (ACM 5.0+)

1. A **cron job** (every 2 hours) automatically creates release branches and fast-forwards main → release branches
2. The cron reads from `stolostron/acm-config/blob/main/product/component-registry.yaml` to determine which repos to process
3. For **protected branches**, the cron creates PRs instead of direct pushes — these need to be reviewed/merged
4. An **`acm-cicd-prow-bot`** creates a PR titled "Add Tekton files for versions: X.X X.X" with slim tekton files using the common pipeline
5. **Konflux** (`red-hat-konflux[bot]`) also auto-generates PRs with full pipeline definitions — these must be **closed, not merged** (or updated to use common pipeline format)
6. **ART transition (future):** The ART team will eventually take over Dockerfiles, tekton pipelines, and fast-forwarding

Source: Konflux Lunch and Learn (April 21, 2026), openshift/release PR #78109

## Key Principle: All Tekton Files Live on Main

All tekton files for all active releases are checked into **main**. The cron job fast-forwards them to the release branches. The **CEL expression** in each file controls which branch actually triggers the build:

- **Push files** target a specific release branch: `target_branch == "release-5.0"` — only triggers when code is pushed to that branch
- **PR files** target `main` (or `main || release-X`) — triggers on PRs to those branches

This means release branches will have tekton files for OTHER versions (from fast-forward), but they won't trigger because the CEL doesn't match. It's **harmless but best practice to clean up**.

## File Naming Convention

```
.tekton/{repo-name}-acm-{VERSION}-push.yaml
.tekton/{repo-name}-acm-{VERSION}-pull-request.yaml
```

Examples: `cluster-backup-operator-acm-50`, `volsync-addon-controller-acm-51`

## Branch Day Checklist (Feature Freeze + 1)

### Step 1: Review and fix the bot PR

The `acm-cicd-prow-bot` creates a PR adding tekton files for the new versions. **Check for these common issues:**

- **`ACM_VERSION` not updated** — bot copies from previous release but may leave the old version. Fix: update `ACM_VERSION=X.X` in build-args for all new files
- **Push CEL targeting `main`** — should target the specific release branch (e.g., `release-5.0`). Fix: change `target_branch == "main"` → `target_branch == "release-X.X"` in push files
- **Missing repo-specific params** — compare with previous release files. Some repos have extra build-args (e.g., volsync has `commitFromGit_arg={{revision}}`), different Dockerfiles, different pipeline refs (`common.yaml` vs `common-base.yaml`), or pathChanged filters in CEL

**How to fix:** Fetch the bot PR branch, make changes, push back:
```bash
git fetch upstream add-tekton-files-5.0-5.1
git checkout -b fix-bot-pr upstream/add-tekton-files-5.0-5.1

# Make fixes...

git add .tekton/
git commit -s --amend --no-edit
git push upstream HEAD:add-tekton-files-5.0-5.1 --force-with-lease
```

### Step 2: Close Konflux auto-generated PRs

PRs from `red-hat-konflux[bot]` contain full pipeline definitions (~550 lines each) that are **not compatible** with our common pipeline approach. Close them.

### Step 3: Verify versioning

```bash
cat COMPONENT_VERSION
grep ACM_VERSION Dockerfile.rhtap
grep ACM_VERSION .tekton/*-push.yaml
```

### Step 4: Merge the bot PR after CI passes

## After Branch Day

### Step 5: Stop Prow fast-forward to previous release

Your colleague or the CI team updates `openshift/release` to remove or change the fast-forward destination:

File: `ci-operator/config/stolostron/{repo}/{repo}-main.yaml`
```yaml
# Remove or update:
- as: fast-forward
  postsubmit: true
  steps:
    env:
      DESTINATION_BRANCH: release-{PREV_VERSION}
    workflow: ocm-ci-fastforward
```

### Step 6: Clean up previous release branch

After fast-forward to the previous release is stopped, clean up that branch. Create a PR against `release-{PREV_VERSION}`:

**Delete** all new version tekton files (they got there via fast-forward):
```bash
git fetch upstream release-{PREV_VERSION}
git checkout -b cleanup-prev upstream/release-{PREV_VERSION}
git rm .tekton/*-acm-{NEW_VERSION}-*
git rm .tekton/*-acm-{NEXT_VERSION}-*
```

**Narrow** the previous version PR file CEL — remove `main`:
```yaml
# BEFORE:
on-cel-expression: event == "pull_request" &&
  (target_branch == "main" || target_branch == "release-{PREV_VERSION}")

# AFTER:
on-cel-expression: event == "pull_request" && target_branch == "release-{PREV_VERSION}"
```

```bash
git add .tekton/
git commit -s -m "Clean up release-{PREV_VERSION}: remove new version tekton files, narrow PR CEL"
git push origin cleanup-prev
# Create PR against upstream/release-{PREV_VERSION}
```

**Note:** If upstream has changed since you branched (e.g., more files were fast-forwarded), you may need to `git rebase upstream/release-{PREV_VERSION}` and resolve conflicts (just `git rm` the conflicting files).

### Step 7: Clean up main

Remove previous release tekton files from main (since main no longer fast-forwards there):

```bash
git checkout main
git pull upstream main
git rm .tekton/*-acm-{PREV_VERSION}-*
git commit -s -m "Remove {PREV_VERSION} tekton files from main"
# Create PR against upstream/main
```

### Step 8: Create prow config for new release (openshift/release)

Use `acm-cut-release.py` or manually create:
- CI config: `stolostron-{repo}-release-{NEW_VERSION}.yaml`
- Branch protection in `_prowconfig.yaml`
- Enable previous release promotion
- Update main CI promotion version

```bash
python3 projects/acm-release-cut/acm-cut-release.py \
  --new-version {NEW_VERSION} \
  --repos cluster-backup-operator volsync-addon-controller \
  --release-repo /path/to/openshift/release \
  --dry-run
```

## Expected End State

### main
Only current + next release tekton files:
```
.tekton/
  {repo}-acm-{NEW_VERSION}-push.yaml          # push: release-{NEW_VERSION}
  {repo}-acm-{NEW_VERSION}-pull-request.yaml   # PR: main || release-{NEW_VERSION}
  {repo}-acm-{NEXT_VERSION}-push.yaml          # push: release-{NEXT_VERSION}
  {repo}-acm-{NEXT_VERSION}-pull-request.yaml  # PR: main || release-{NEXT_VERSION}
```

### release-{NEW_VERSION}
Same as main (via fast-forward). Only {NEW_VERSION} files trigger (CEL match).

### release-{PREV_VERSION}
Only previous release files:
```
.tekton/
  {repo}-acm-{PREV_VERSION}-push.yaml          # push: release-{PREV_VERSION}
  {repo}-acm-{PREV_VERSION}-pull-request.yaml   # PR: release-{PREV_VERSION}
```

## Summary Checklist

| # | When | Action |
|---|------|--------|
| 1 | Branch day | Review + fix bot PR (ACM_VERSION, push CEL, repo-specific params) |
| 2 | Branch day | Close Konflux auto-generated PRs |
| 3 | Branch day | Verify versioning |
| 4 | Branch day | Merge bot PR after CI passes |
| 5 | After branch day | Stop Prow fast-forward to previous release (openshift/release) |
| 6 | After ffwd stops | Clean up previous release branch (delete new files, narrow CEL) |
| 7 | After ffwd stops | Clean up main (remove previous release tekton files) |
| 8 | When ready | Create prow config for new release (openshift/release) |

## Common Bot PR Issues (Learned from ACM 5.0)

| Issue | Description | Fix |
|-------|-------------|-----|
| `ACM_VERSION` not updated | Bot copies from previous release, leaves old version | Change `ACM_VERSION=X.X` to correct version |
| Push CEL targets `main` | Should target release branch for safety | Change to `target_branch == "release-X.X"` |
| Missing build-args | Some repos have extra args (e.g., `commitFromGit_arg`) | Compare with previous release template |
| Different pipeline ref | Some repos use `common-base.yaml` not `common.yaml` | Verify against previous release |
| Different namespace | Repos may be in different Konflux tenants | Verify against previous release |
| pathChanged filters | Some repos have complex CEL with file path filters | Bot usually handles this correctly |

## Multi-Component Repos

Some repos have multiple components (e.g., `multicluster-global-hub` has agent, manager, operator). These get multiple tekton files per version (push + PR per component). The same process applies — just more files to check.

## Applies To

- `stolostron/cluster-backup-operator` (1 component)
- `stolostron/volsync-addon-controller` (1 component)
- `stolostron/multicluster-global-hub` (3 components: agent, manager, operator)
- Any other stolostron repo using Konflux with common pipeline

## Historical Reference

| Release | Key Events |
|---------|-----------|
| 2.15 → 2.16 | Manual process: `e26adc44`, `fa0bba2e`, `0ade7e07` |
| 2.16 → 2.17 | Manual process: `8bb1b961`, `d79b3ebc` |
| 2.17 → 5.0 | New automated process. Bot PRs had `ACM_VERSION` bug and push CEL targeting `main`. Fixed in PR review. Cron job creates branches automatically. Also creates 5.1 as frozen release. |

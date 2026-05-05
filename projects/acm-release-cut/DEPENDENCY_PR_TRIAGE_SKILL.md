# Dependency PR Triage — Daily Task

This skill documents how to triage and approve dependency update PRs on cluster-backup-operator and volsync-addon-controller.

## PR Sources

| Bot | What it updates | CI auto-runs? |
|-----|----------------|---------------|
| `red-hat-konflux[bot]` | Tekton task bundle SHA references in `.tekton/` files | Yes |
| `app/renovate` | Go module updates (main branch only, indirect deps disabled) | Yes (`ok-to-test` label auto-added) |
| `app/dependabot` | Weekly Go module updates | No — needs `/ok-to-test` comment first |
| `konflux/mintmaker` | Go module updates from Konflux | Varies |

## Konflux Tekton Reference Updates (from `red-hat-konflux[bot]`)

**Always safe to approve** if:
- Only `.tekton/` files are changed (push + pull-request yamls)
- No other files modified
- CI checks are green
- No warnings in PR body

These PRs update Tekton task bundle SHA references to newer versions. They don't change any application code.

**Action:** Comment `/lgtm` and `/approve` (or `gh pr review --approve`)

## Go Dependency Updates (Renovate / Dependabot / Mintmaker)

### Safe to approve (minor/patch updates, CI green):

| Dependency | Notes |
|-----------|-------|
| `go-logr/logr` | Logging library |
| `onsi/ginkgo`, `onsi/gomega` | Test framework — won't affect production |
| `pkg/errors` | Archived but stable |
| `robfig/cron` | Cron parser |
| `go.uber.org/zap` | Logging |
| `gopkg.in/yaml.v3` | YAML parsing |
| `open-cluster-management.io/api` | Usually safe patches |
| `open-cluster-management.io/multicloud-operators-channel` | Usually safe |
| `openshift/controller-runtime-common` | Usually safe patches |
| Minor patch versions of anything above | e.g., v1.4.2 → v1.4.3 |

### DO NOT auto-approve (needs team discussion):

| Dependency | Why |
|-----------|-----|
| `vmware-tanzu/velero` | Must align with OADP version. Only upgrade when OADP team upgrades. |
| `openshift/hive/apis` | Must align with Hive version shipped with MCE |
| `k8s.io/*` (api, apimachinery, client-go) | Major version bumps could break compatibility. Minor patches usually safe. |
| `sigs.k8s.io/controller-runtime` | Major bumps could break controller code. Minor patches usually safe. |
| Go version (in Dockerfile/builder image) | Needs downstream builder image for the new version to exist first |
| Any PR that changes non-dependency files | May include breaking changes |

### Edge cases:
- **k8s.io patch updates** (e.g., v0.35.3 → v0.35.4): Usually safe — check CI
- **controller-runtime patch** (e.g., v0.22.4 → v0.22.5): Usually safe — check CI
- **Multiple deps bumped together**: Check each one against the rules above

## Workflow

### For Dependabot PRs:
1. Check the dependency being updated against the rules above
2. If safe: comment `/ok-to-test` to trigger CI
3. Wait for CI to pass
4. If green: approve and merge

### For Renovate PRs:
1. CI runs automatically (`ok-to-test` label pre-added)
2. Check the dependency against the rules above
3. If safe + CI green: approve and merge

### For Konflux tekton updates:
1. Verify only `.tekton/` files changed
2. CI green
3. Approve and merge

## Script Reference

A colleague has a script that automates Konflux tekton PR approval:
- Lists PRs from `red-hat-konflux[bot]`
- Validates only tekton files changed
- Checks CI status
- Auto-approves if all checks pass
- Handles DCO signoff override

Key `gh` commands:
```bash
# List Konflux PRs
gh pr --repo stolostron/cluster-backup-operator list --author 'app/red-hat-konflux'

# Check PR status
gh pr view <PR_NUMBER> --json "reviewDecision,labels,statusCheckRollup"

# Approve
gh pr review <PR_NUMBER> --approve

# Trigger CI on Dependabot PRs
gh pr comment <PR_NUMBER> --body "/ok-to-test"
```

## Applies To

- `stolostron/cluster-backup-operator`
- `stolostron/volsync-addon-controller`

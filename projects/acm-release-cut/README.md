# acm-release-cut

Automates CI configuration changes when cutting a new ACM release branch for stolostron repos in the `openshift/release` repository.

## What it does

For each repo, the script performs 4 steps:

1. **Updates main CI config** - bumps promotion version + fastforward destination branch
2. **Enables previous release promotion** - removes `disabled: true` from the previous release config
3. **Creates new release config** - copies previous release config with disabled promotion + updated versions
4. **Adds branch protection** - adds prow branch protection rules for the previous release branch

## Usage

```bash
# Dry run first:
python3 projects/acm-release-cut/acm-cut-release.py \
    --new-version 2.18 \
    --repos cluster-backup-operator volsync-addon-controller \
    --release-repo ~/workspace/src/github.com/sahare/release \
    --dry-run

# Apply changes:
python3 projects/acm-release-cut/acm-cut-release.py \
    --new-version 2.18 \
    --repos cluster-backup-operator volsync-addon-controller \
    --release-repo ~/workspace/src/github.com/sahare/release

# Then in the release repo:
cd ~/workspace/src/github.com/sahare/release
make update
```

## Options

| Flag | Required | Description |
|------|----------|-------------|
| `--new-version` | Yes | New release version (e.g., `2.18`) |
| `--repos` | Yes | One or more repo names (e.g., `cluster-backup-operator`) |
| `--release-repo` | Yes | Path to local `openshift/release` checkout |
| `--org` | No | GitHub org (default: `stolostron`) |
| `--dry-run` | No | Preview changes without writing files |

## Requirements

- Python 3.6+
- No external dependencies (stdlib only)

# ai-tools

Personal collection of AI scripts and skills for automating CI/CD workflows.

## Scripts

### `scripts/acm-cut-release.py`

Automates CI configuration changes when cutting a new ACM release branch for stolostron repos in the `openshift/release` repository.

**Usage:**

```bash
# Dry run:
python3 scripts/acm-cut-release.py --new-version 2.18 \
    --repos cluster-backup-operator volsync-addon-controller --dry-run

# Apply changes:
python3 scripts/acm-cut-release.py --new-version 2.18 \
    --repos cluster-backup-operator volsync-addon-controller

# Then in the release repo:
make update
```

**What it does for each repo:**
1. Updates the main CI config (promotion version + fastforward destination)
2. Enables promotion on the previous release config
3. Creates the new release config (with disabled promotion)
4. Adds branch protection rules in the prow config

## Requirements

- Python 3.6+
- PyYAML (`pip install pyyaml`)

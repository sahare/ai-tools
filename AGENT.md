# AI Agent Instructions

This file teaches AI coding assistants how to use the automation tools in this repository.
It is compatible with any AI agent that can read project files and execute shell commands.

**Supported by:** Cursor (`.cursorrules`), GitHub Copilot (`AGENT.md`), Claude (`CLAUDE.md`), Windsurf, Cody, or any AI that reads project context.

## Available Skills

### Skill: Install ACM on a Cluster

**Triggers:** "install ACM", "set up ACM", "deploy ACM dev build", "set up a cluster with ACM"

**Required info** (ask the user if not provided):
- Cluster API URL (e.g., `https://api.mycluster.com:6443`)
- Cluster credentials: either a login token (`sha256~...`) or kubeadmin password
- Quay.io username and CLI password (for `acm-d` access)
- ACM version (default: `2.17`)

**Steps:**
1. Run the install script:
   ```bash
   ./projects/acm-cluster-setup/scripts/install-acm.sh \
     --server=<api-url> --token=<token> \
     --quay-user=<user> --quay-password=<password> \
     --version=<version>
   ```
   Or with kubeadmin:
   ```bash
   ./projects/acm-cluster-setup/scripts/install-acm.sh \
     --server=<api-url> --kubeadmin-password=<password> \
     --quay-user=<user> --quay-password=<password> \
     --version=<version>
   ```

2. Monitor until completion (takes ~15-20 minutes).

3. If it fails, automatically run the diagnose skill (see below).

### Skill: Uninstall ACM from a Cluster

**Triggers:** "uninstall ACM", "remove ACM", "clean up ACM"

```bash
./projects/acm-cluster-setup/scripts/install-acm.sh \
  --server=<api-url> --token=<token> --uninstall
```

### Skill: Diagnose ACM Installation Issues

**Triggers:** "why is ACM failing", "diagnose", "what's wrong with my cluster", "ACM is stuck"

**Steps:**
1. Run the diagnostic script:
   ```bash
   ./projects/acm-cluster-setup/scripts/diagnose.sh \
     --server=<api-url> --token=<token>
   ```
2. The script checks 9 areas: cluster health, pull secret, ICSP, CatalogSources, operator status, MCH status, pod health, recent events, and console access.
3. Look for lines with ❌ or ⚠️ in the output — these are the issues.
4. Provide the user with:
   - Root cause analysis
   - Specific fix commands
   - Offer to apply the fix

**Common issues and fixes:**
- `❌ quay.io:443 credentials NOT found` → Re-run install with correct quay credentials
- `❌ No image mirroring configured` → Script can create ICSP automatically
- `❌ CatalogSource not READY` → Check pod logs: `oc logs -n openshift-marketplace -l olm.catalogSource=acm-dev-catalog`
- `⚠️ MCH not Running` → Check MCH conditions in the diagnostic output for the specific blocker

### Skill: Check Cluster Health

**Triggers:** "is my cluster healthy", "check cluster status", "cluster health"

```bash
./projects/acm-cluster-setup/scripts/diagnose.sh \
  --server=<api-url> --token=<token> --health-only
```

### Skill: Cut a New ACM Release Branch

**Triggers:** "cut release", "new release branch", "prepare release 2.XX"

**Required info:**
- New version number (e.g., `2.18`)
- Repository names (e.g., `cluster-backup-operator`)
- Path to local `openshift/release` repo checkout

**Steps:**
1. Always dry-run first:
   ```bash
   python3 projects/acm-release-cut/acm-cut-release.py \
     --new-version <version> \
     --repos <repo1> <repo2> \
     --release-repo <path> \
     --dry-run
   ```

2. Show the user what will change. Only proceed if they confirm.

3. Apply:
   ```bash
   python3 projects/acm-release-cut/acm-cut-release.py \
     --new-version <version> \
     --repos <repo1> <repo2> \
     --release-repo <path>
   ```

4. Remind the user to run `make update` in the release repo and create a PR.

### Skill: Triage Customer Backup/Restore Issue

**Triggers:** "triage this", "customer issue", "customer says", "help with this support question"

**Steps:**
1. Read the customer's message/description
2. Refer to `projects/acm-backup-triage/KNOWLEDGE_BASE.md` for known issues, phases, and ownership
3. Categorize the issue:
   - **Config/setup mistake** → provide correct configuration and doc links
   - **Known limitation** → explain the behavior, provide workaround
   - **OADP/Velero issue** → redirect to OADP team with context
   - **Potential bug** → list what info to collect from the customer
   - **Informational** → answer the question with doc links
4. Draft a response for the team member to review before posting
5. Always include relevant doc/blog links from the knowledge base

**Important:**
- Always check the knowledge base first before searching code
- If unsure, recommend collecting more info rather than guessing
- Never share internal code details with customers — reference docs and expected behaviors
- If it matches a known issue in the knowledge base, say so explicitly

### Skill: Assess ACM Backup Configuration on a Cluster

**Triggers:** "check backup config", "which hub is active", "assess backup status", "is this hub active or passive", "backup health"

Use this when connected to a cluster (via `oc`) and you need to determine its backup/restore role and health.

**Steps:**
1. Determine the cluster's identity:
   ```bash
   oc get clusterversion version -o jsonpath='{.spec.clusterID}'
   ```

2. Check OADP and storage:
   ```bash
   oc get DataProtectionApplication -n open-cluster-management-backup
   oc get backupstoragelocation -n open-cluster-management-backup
   ```

3. Check BackupSchedule and Restore:
   ```bash
   oc get backupschedule -n open-cluster-management-backup -o yaml
   oc get restore.cluster.open-cluster-management.io -n open-cluster-management-backup -o yaml
   ```

4. Determine cluster role by checking backup ownership — compare the `backup-cluster` label on the latest heartbeat backup against this cluster's ID:
   ```bash
   oc get backups.velero.io -n open-cluster-management-backup \
     -l velero.io/schedule-name=acm-validation-policy-schedule \
     --sort-by=.status.startTimestamp \
     -o custom-columns='NAME:.metadata.name,HUB:.metadata.labels.cluster\.open-cluster-management\.io/backup-cluster'
   ```

5. Check for failover history (managed-clusters restore):
   ```bash
   oc get backups.velero.io -n open-cluster-management-backup \
     -o custom-columns='NAME:.metadata.name,RESTORE-HUB:.metadata.labels.cluster\.open-cluster-management\.io/restore-cluster' \
     | grep -v '<none>'
   ```

6. Check governance policy compliance:
   ```bash
   oc get policy backup-restore-enabled -n open-cluster-management-backup -o yaml
   ```

**Interpret the role using this table:**

| Condition | Role |
|-----------|------|
| Latest heartbeat's `backup-cluster` matches this cluster | **ACTIVE HUB** |
| Has Restore with `ManagedClusters: skip` | **PASSIVE HUB** |
| Passive + `syncRestoreWithNewBackups: true` | **PASSIVE HUB (sync)** |
| BackupSchedule exists but another hub owns latest backups | **COLLIDING** — only one hub should write |
| Restore with `ManagedClusters` != skip | **FAILOVER / ACTIVATION in progress** |
| No BackupSchedule or Restore | **NOT CONFIGURED** |

**Common issues to flag:**
- This cluster ran failover but has no BackupSchedule → should create one
- This cluster has a BackupSchedule but another hub owns latest backups → collision
- Passive cluster but no backups in storage → active hub may not be running
- Passive cluster but no heartbeat backups → active hub's cron may have stopped
- `backup-restore-enabled` policy NonCompliant → check per-template violations

## Behavior Guidelines

- **Ask before destructive operations** — always confirm before uninstall or delete
- **Never guess credentials** — always ask the user for tokens, passwords, usernames
- **Auto-diagnose on failure** — if any script fails, run `diagnose.sh` and analyze the output
- **Dry-run first** — for release cuts, always run dry-run before applying
- **Monitor long operations** — install takes ~15-20 min; check progress and report status
- **Be specific with fixes** — don't just say "check logs"; give the exact command and what to look for

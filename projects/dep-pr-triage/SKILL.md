---
name: dep-pr-triage
description: >-
  Triage open dependency-bump PRs (Dependabot/Renovate) for a given repo:
  verify CI is green, the PR is mergeable, the diff is scoped to
  dependency-manifest files only, and the version bump is not a risky major
  version. Approve safe PRs directly (as the agent, via gh pr review), and
  leave a clear explanatory comment on anything held for human review. Use
  only when explicitly asked to triage/review dependency PRs for a repo -
  this performs real GitHub actions (approvals, comments), so do not
  auto-invoke ambiently.
disable-model-invocation: true
---

# Dependency PR Triage

One-word workflow: given a repo, find dependency-bump PRs, decide safe-vs-risky per PR using the
checklist below, and act — approve the safe ones yourself, hold the risky ones with an explanation.
This is a consequential-action skill (it approves PRs under your own `gh` identity) — always follow
the checklist in full before approving, and when in doubt, hold rather than approve.

## Workflow

```
Task progress (copy and track per repo):
- [ ] Step 1: List candidate PRs
- [ ] Step 2: Check this repo's approval mechanism (once per repo, not per PR)
- [ ] Step 3: Per PR — gather status
- [ ] Step 4: Per PR — classify the bump
- [ ] Step 5: Per PR — decide: approve or hold
- [ ] Step 6: Report a summary table
```

### Step 1 — List candidates

```bash
scripts/list-candidates.sh <owner/repo>
```
Returns open, non-draft PRs from Dependabot/Renovate (by author, `dependencies` label, or a
`fix(deps):`/`chore(deps):`/`build(deps):`/`bump `/`update ` title prefix). If a PR isn't in this
list but you suspect it's a dependency bump, check it manually — don't force it through this
skill's fast path if the automated match is ambiguous.

### Step 2 — Check this repo's approval mechanism (once per repo)

```bash
scripts/check-approval-mechanism.sh <owner/repo>
```
This tells you which of these applies, so Step 5 does the right thing:
- **Native GitHub review is sufficient** — the last merged PR's `[APPROVALNOTIFIER]`-style bot
  comment (or plain branch protection with no bot at all) shows approval coming from a GitHub PR
  review link. `gh pr review --approve` alone unblocks the merge.
- **Prow slash commands required** — the repo expects `/lgtm` and/or `/approve` comments in
  addition to (or instead of) a native review. Pass `--also-lgtm` to `approve.sh` in Step 5.
- **You are not an OWNERS/CODEOWNERS approver for this repo/path** — your approval will be
  recorded but won't unblock merge automation. Still approve if the PR is safe (it's a genuine,
  useful signal and unblocks *your* portion of a multi-approver requirement), but say so explicitly
  in your summary so the user knows a human approver is still needed.

### Step 3 — Per PR: gather status

```bash
scripts/pr-status.sh <owner/repo> <pr-number>
```
Read the output for:
- `mergeStateStatus` — must be `CLEAN`. `BEHIND` → don't approve yet, it may resolve on its own
  (dependabot/renovate self-rebase) or need a manual rebase; re-check later rather than approving
  now. `DIRTY`/`BLOCKED` → hold.
- Checks — **every** check must be a pass. Any failure → hold. Any still-`pending`/`in_progress` →
  don't approve yet, this isn't a "no" but it isn't a "yes" either; re-check later.
- Changed files — must be limited to dependency manifest/lock files: `go.mod`, `go.sum`,
  `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements*.txt`,
  `Pipfile.lock`, `vendor/**`, `Gopkg.lock`, or CI/build config files the bot conventionally
  touches alongside a bump (e.g. a Renovate-managed Dockerfile pin). **Any change to actual
  application source code is a hold, not an approve** — a pure bump shouldn't need source changes;
  if it does, something (an API break, a codemod) needs a human to actually read the diff.

### Step 4 — Per PR: classify the version bump

Parse the "from X to Y" (or "to vY") version(s) out of the PR title/body:
- **Major version bump (X.y.z → (X+1).0.0)** → always hold for human review, regardless of CI/diff
  scope. This is the single biggest signal of a potential breaking change.
- **Go modules specifically:** a bump that changes the import path's major-version suffix (e.g.
  `/v2` → `/v3`) is a major bump by definition (Go's semantic import versioning) — treat the same
  as above even if the PR bot doesn't call it out explicitly.
- **Pre-1.0 packages (`v0.x.y`)** — treat conservatively. `0.4.1 → 0.4.2` (patch-only) is fine to
  auto-approve like any patch bump; `0.4.x → 0.5.x` is not guaranteed backward-compatible under
  semver's own rules pre-1.0 — hold it like a major bump.
- **Grouped/batched updates** (Renovate can bundle several deps in one PR) — if *any* dependency in
  the group is major/risky by the rules above, hold the whole PR.
- Minor and patch bumps of already-1.0+ packages, with everything else in Step 3 passing → safe to
  approve.

### Step 5 — Decide and act

**All of these must hold to approve:** CI green (not pending/failing), `mergeStateStatus: CLEAN`,
diff scoped to dependency files only, not a major/risky bump per Step 4.

If approving:
```bash
scripts/approve.sh <owner/repo> <pr-number> "<summary of what was checked>" [--also-lgtm]
```
Write the approval body as a real audit trail, e.g.: *"Automated dependency-triage approval: CI
green (N checks), mergeable/clean, minor bump (1.4.0 → 1.4.3), diff limited to go.mod/go.sum. No
source changes."* Add `--also-lgtm` only if Step 2 said this repo needs it.

If holding:
```bash
scripts/hold.sh <owner/repo> <pr-number> "<what's blocking and why>"
```
Be specific — name the failing check, the major-version jump, or the unexpected file — so a human
reviewer doesn't have to redo your triage from scratch.

**Never do any of the following, even if it seems like it would "help":**
- Don't force-push, rebase, or push commits to the PR branch yourself.
- Don't merge the PR yourself — approving (and/or `/lgtm`) is as far as this skill goes; let the
  repo's own merge automation (Tide, GitHub auto-merge, or a human) take it from there.
- Don't approve a PR with any failing required check, even if you believe the failure is unrelated
  flakiness — flag that belief in a hold comment instead and let a human make that call.
- Don't approve drafts, or PRs with an explicit hold/do-not-merge label.

### Step 6 — Report

End with a table: PR number | title | decision (approved/held/skipped-pending) | one-line reason.
This is the artifact a human skims to sanity-check what you did — make it complete even for PRs you
didn't touch (e.g. "still running CI, re-check next pass").

## Invoking this for a new repo

Nothing above is `cluster-backup-operator`-specific — pass any `owner/repo`. The only per-repo
thing worth confirming once is Step 2 (approval mechanism), since Prow-vs-plain-GitHub varies by
org/repo and changes what "approve" actually needs to do to be effective.

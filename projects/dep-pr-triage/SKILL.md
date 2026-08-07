---
name: dep-pr-triage
description: >-
  Triage open dependency-bump PRs (Dependabot/Renovate) for a given repo:
  verify CI is green, the PR is mergeable, the diff is scoped to
  dependency-manifest files only, and the version bump is not a risky major
  version. Two rounds: round 1 is read-only and ends with a report and a
  recommendation per PR (no approvals or comments posted); round 2 only runs
  after the human explicitly confirms, and then approves the recommended PRs
  directly (as the agent, via gh pr review) or leaves an explanatory comment
  on anything held. Use only when explicitly asked to triage/review
  dependency PRs for a repo - this performs real GitHub actions, so do not
  auto-invoke ambiently and never skip straight to round 2.
disable-model-invocation: true
---

# Dependency PR Triage

One-word workflow: given a repo, find dependency-bump PRs, decide safe-vs-risky per PR using the
checklist below, and report the recommendation. **This is always a two-round process — never
approve or comment on anything during round 1.** Round 1 is read-only: list, check, classify,
recommend, and stop at the report. Only in round 2, after the human explicitly says to proceed
(e.g. "approve", "approve #123 and #456", "approve all recommended"), do you actually call
`approve.sh` / `hold.sh`. This is a consequential-action skill (it approves PRs under your own `gh`
identity) — never skip straight to acting on a fresh invocation, even if every PR looks obviously
safe.

## Workflow

```
Task progress (copy and track per repo):
Round 1 (read-only):
- [ ] Step 1: List candidate PRs
- [ ] Step 2: Check this repo's approval mechanism (once per repo, not per PR)
- [ ] Step 3: Per PR — gather status
- [ ] Step 4: Per PR — classify the bump
- [ ] Step 5: Per PR — recommend: approve or hold (do NOT act yet)
- [ ] Step 6: Report a summary table and stop; wait for explicit go-ahead

Round 2 (only after explicit human confirmation):
- [ ] Step 7: Act on exactly what was confirmed
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
- **When something fails, read the actual failure log before writing your recommendation — never
  guess or speculate that it's "probably unrelated CI flakiness."** Pull the real log (e.g. via the
  Prow build-log URL from `gh pr checks`, typically
  `https://storage.googleapis.com/test-platform-results/pr-logs/pull/<org>_<repo>/<pr>/<job>/<id>/build-log.txt`)
  and find the actual compiler/linter/test error. Two failure modes are common and easy to
  misdiagnose as "flaky" if you only look at the pass/fail summary:
  - **Coordinated-bump breaks**: a bot bumps one dependency (e.g. `k8s.io/client-go`) without a
    compatible bump of a tightly-coupled one (e.g. `sigs.k8s.io/controller-runtime`), producing a
    genuine compile error. Diff the full `go.mod`/`go.sum` change (not just the file list) —
    "digest"-titled or single-package-titled bumps from bots (Renovate/mintmaker/Konflux) often
    drag in several transitive version bumps at once, and any one of them can be the actual culprit
    even if the PR title only mentions one package.
  - **Newly-surfaced deprecations under a zero-tolerance lint gate**: a transitive bump adds a
    `// Deprecated:` doc comment to something already in use (e.g. `staticcheck`'s `SA1019`), and a
    strict `make lint` fails the whole PR over it. This is a real, fixable issue in the target
    repo's source, not noise.
  - **Incomplete bot output**: `go.mod` updated but `go.sum` wasn't regenerated ("missing go.sum
    entry" errors) — a malformed PR, not a code compatibility problem.
  Your report should name the specific root cause (with the offending file/line where you found
  one), not just "CI is failing."
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

### Step 5 — Recommend (do NOT act yet)

**All of these must hold for a "recommend approve":** CI green (not pending/failing),
`mergeStateStatus: CLEAN`, diff scoped to dependency files only, not a major/risky bump per Step 4.
Anything else is "recommend hold" (or "not ready — CI/mergeability still pending, re-check later"
if nothing has actually failed, it just isn't done yet).

For each recommendation, draft — but do not yet post or run — the exact text/command you'd use in
Step 7:
- Recommend approve → draft the `approve.sh` call and the audit-trail body you'd pass it, e.g.
  *"Automated dependency-triage approval: CI green (N checks), mergeable/clean, minor bump
  (1.4.0 → 1.4.3), diff limited to go.mod/go.sum. No source changes."* Note whether `--also-lgtm`
  is needed per Step 2.
- Recommend hold → draft the `hold.sh` call and reason, naming the specific failing check, the
  major-version jump, or the unexpected file.

### Step 6 — Report and stop

End with a table: PR number | title | **recommendation** (approve/hold/not-ready) | one-line reason
| draft comment/approval text. Then stop. Do not call `approve.sh` or `hold.sh` in this round under
any circumstances, even if every single PR looks like a trivial patch bump — the human reviews the
report and tells you which ones (if any) to act on.

### Step 7 — Act (round 2 only, after explicit confirmation)

Only enter this step once the human has responded with something like "approve", "approve #123 and
#456", "approve all recommended", or "hold #789 instead, approve the rest". Act on exactly what was
confirmed — if they say "approve all recommended", that means only the ones you marked
recommend-approve in Step 6, not every PR in the list.

```bash
scripts/approve.sh <owner/repo> <pr-number> "<audit-trail body from Step 5>" [--also-lgtm]
scripts/hold.sh    <owner/repo> <pr-number> "<reason from Step 5>"
```

**Never do any of the following, even if it seems like it would "help":**
- Don't force-push, rebase, or push commits to the PR branch yourself.
- Don't merge the PR yourself — approving (and/or `/lgtm`) is as far as this skill goes; let the
  repo's own merge automation (Tide, GitHub auto-merge, or a human) take it from there.
- Don't approve a PR with any failing required check, even if you believe the failure is unrelated
  flakiness — flag that belief in a hold comment instead and let a human make that call.
- Don't approve drafts, or PRs with an explicit hold/do-not-merge label.
- Don't silently expand scope beyond what was confirmed (e.g. don't also hold-comment on PRs the
  human didn't mention).

Confirm back to the human what was actually done (which PRs got `approve.sh`, which got `hold.sh`,
which were left untouched) once round 2 finishes.

## Invoking this for a new repo

Nothing above is `cluster-backup-operator`-specific — pass any `owner/repo`. The only per-repo
thing worth confirming once is Step 2 (approval mechanism), since Prow-vs-plain-GitHub varies by
org/repo and changes what "approve" actually needs to do to be effective.

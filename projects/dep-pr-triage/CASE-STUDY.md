# Case Study: `dep-pr-triage` — Agentic Dependency-PR Triage

**Date:** August 7, 2026
**Context:** Built and dogfooded in a single session, on real, live repositories — not a demo environment.

## What was built

A Cursor Agent Skill (`dep-pr-triage`) that triages bot-opened dependency-bump PRs
(Dependabot/Renovate/Konflux-mintmaker) on any GitHub repo: checks CI status and mergeability,
classifies the version-bump risk, and — only after a human explicitly reviews a report and says
go — approves the safe ones directly via `gh pr review`.

Deliberately designed as a **two-round, human-gated workflow**, not a fire-and-forget automation:

- **Round 1 (read-only):** list candidates → check the repo's approval mechanism → gather CI/merge
  status per PR → classify the bump → produce a report with a recommendation per PR. Nothing is
  posted to GitHub in this round, no matter how obviously safe a PR looks.
- **Round 2 (act):** only runs after the human explicitly confirms which PRs to approve. Never
  merges, force-pushes, or rebases on its own — approval only, audit-trailed with the specific
  reasoning for each decision.

Portable by construction: takes any `owner/repo`, nothing hardcoded to one project.

## What it found (not hypothetical — real, live results)

Ran round 1 against two unrelated ACM repositories today. Combined: **33 dependency PRs
triaged, 4 distinct real root causes found, 0 unsafe approvals.**

### `stolostron/cluster-backup-operator` — 14 PRs, 0 approved in round 1

All 14 were held — but the *reason* mattered. The first pass instinct was "maybe some of this is
just unrelated CI flakiness." Reading the actual failure logs instead of the pass/fail summary
disproved that and surfaced three separate, concrete bugs:

1. **A real, fixable bug in the repo itself:** `controller-runtime` v0.24.0 deprecated
   `pkg/scheme.Builder`; the repo's zero-tolerance `make lint` gate fails outright on the resulting
   `staticcheck SA1019` finding. This silently blocked *every* dependency PR that happened to pull
   controller-runtime ≥ 0.24.x, regardless of what else the PR changed.
2. **A coordinated-bump break:** one PR bumped `k8s.io/client-go` to v0.36.3 without a matching
   `controller-runtime` bump, breaking the build (`ResourceEventHandlerRegistration` interface
   changed underneath it).
3. **A malformed bot PR:** `go.mod` updated, `go.sum` never regenerated.

### `stolostron/volsync-addon-controller` — 19 PRs, 2 approved (pending), rest held

Different repo, different dependency graph, same methodology — and it surfaced a bigger,
cross-cutting issue:

4. **A real breaking API change:** `open-cluster-management.io/addon-framework` v1.3.0 changed the
   `agent.AgentAddon.Manifests()` interface (added a `context.Context` param, switched
   `addon/v1alpha1` → `addon/v1beta1`). `volsync-addon-controller` doesn't implement the new
   signature, blocking 5 separate PRs. A second, independent version-skew failure (`sdk-go` bumped
   without `addon-framework`) was found in the same pass.
5. Also caught a **semver-heuristic edge case**: a PR bumping a pre-1.0 package
   (`operator-framework/api` 0.44.0→0.45.0) had fully green CI, but was correctly held anyway
   because the skill's own conservative pre-1.0 rule treats that bump like a major version.
6. Also caught a **governance/process block** unrelated to code: a release-2.14 PR couldn't merge
   because of the org's newer CVE-workflow branch policy requiring an
   `acknowledge-security-fixes-only` label — not a bug, just correctly not conflated with one.

## What happened next (the loop closed, not just a report)

- Finding #1 became a real, verified fix: [`stolostron/cluster-backup-operator#1689`](https://github.com/stolostron/cluster-backup-operator/pull/1689).
  Built, `go vet`'d, unit-tested, and specifically validated by temporarily bumping
  `controller-runtime` to v0.24.1 locally to prove the `SA1019` finding actually disappears.
- CI on that PR itself then caught a real gap in the fix — `crd-and-gen-files-check` failed because
  `make generate` hadn't been re-run after the source change. Read the log instead of guessing,
  fixed it (regenerated `zz_generated.deepcopy.go`), pushed, confirmed green.
- Finding #4 became [ACM-40371](https://redhat.atlassian.net/browse/ACM-40371), filed with the
  exact interface diff, the compiler error, the 4 files needing migration, and the 5 PRs it
  blocks — enough for the VolSync addon owner to start without re-deriving the diagnosis.

## Before → After

| | Before | After |
|---|---|---|
| `cluster-backup-operator` dependency PRs | 14 open, all silently red, root cause unknown | Root cause identified for all; fix PR open (#1689), verified to unblock at least 2 of them once merged and rebased |
| `volsync-addon-controller` dependency PRs | 19 open, mixed red/green, no one had connected them to a single root cause | 2 safe ones identified for approval; the real blocker (addon-framework v1.3.0 API break) documented and hand-off-ready in Jira |
| Time to reach this state manually | Would require someone to individually open ~33 PRs, read Prow logs, and cross-reference go.mod diffs by hand | ~20–30 minutes total, across two repos |

## The self-correction moment (arguably the most reusable part)

The first draft of the `cluster-backup-operator` report hedged: *"possibly a repo-wide CI issue...
worth checking if it's unrelated to real regressions."* That was wrong, and it was corrected in the
same session — not by getting it right the second time by luck, but by turning the correction into
a permanent rule in the skill itself:

> When something fails, read the actual failure log before writing your recommendation — never
> guess or speculate that it's "probably unrelated CI flakiness."

That rule then directly produced findings #4–6 in the second repo. The mistake became durable
leverage instead of a one-off fix.

## Why this is a reasonable review/day-of-learning artifact

- **Concrete, checkable outputs**, not just a description of effort: a merged-ready fix PR, a filed
  Jira ticket with enough detail to act on, and a portable skill others can reuse today.
- **Judgment over volume**: the skill itself is ~250 lines of markdown plus a handful of shell
  scripts — the value is in the safety design (two-round human gate, no merge/force-push, audit
  trails) and in catching real bugs, not in code complexity.
- **A demonstrated feedback loop**: a mistake this session became a rule that paid off later in the
  same session, on a different repo.

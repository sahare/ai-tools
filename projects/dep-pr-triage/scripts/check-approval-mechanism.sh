#!/usr/bin/env bash
# Determine how this repo actually unblocks a merge: native GitHub review
# approval, Prow /lgtm+/approve slash commands, or plain branch protection.
# Looks at the most recently merged PR's bot/approval comments.
# Usage: check-approval-mechanism.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: check-approval-mechanism.sh <owner/repo>}"

LAST_MERGED=$(gh pr list --repo "$REPO" --state merged --limit 1 --json number --jq '.[0].number')
if [ -z "$LAST_MERGED" ] || [ "$LAST_MERGED" = "null" ]; then
  echo "No merged PRs found to inspect. Assume plain GitHub branch protection."
  exit 0
fi

echo "Inspecting comments on last merged PR #$LAST_MERGED for approval mechanism..."
gh pr view "$LAST_MERGED" --repo "$REPO" --json comments \
  --jq '.comments[] | select(.body | test("APPROVALNOTIFIER|/lgtm|/approve"; "i")) | .body' | head -c 3000

echo
echo "---"
echo "Also checking who is a valid OWNERS/CODEOWNERS approver, and whether the"
echo "authenticated gh CLI user is one of them:"
gh api user --jq '.login'
for f in OWNERS OWNERS_ALIASES CODEOWNERS .github/CODEOWNERS; do
  gh api "repos/$REPO/contents/$f" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null && echo "(^ from $f)" && break
done || echo "No OWNERS/CODEOWNERS file found at repo root or .github/."

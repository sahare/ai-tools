#!/usr/bin/env bash
# Submit the actual approval. Only call this after the SKILL.md decision
# checklist has fully passed for this PR.
# Usage: approve.sh <owner/repo> <pr-number> <review-body> [--also-lgtm]
set -euo pipefail

REPO="${1:?usage: approve.sh <owner/repo> <pr-number> <review-body> [--also-lgtm]}"
PR="${2:?usage: approve.sh <owner/repo> <pr-number> <review-body> [--also-lgtm]}"
BODY="${3:?review body text is required}"
ALSO_LGTM="${4:-}"

gh pr review "$PR" --repo "$REPO" --approve --body "$BODY"
echo "Submitted native GitHub review approval on $REPO#$PR."

if [ "$ALSO_LGTM" = "--also-lgtm" ]; then
  gh pr comment "$PR" --repo "$REPO" --body "/lgtm"
  echo "Also posted /lgtm comment for Prow."
fi

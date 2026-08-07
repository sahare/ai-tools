#!/usr/bin/env bash
# Leave a clear, non-approving comment explaining why a PR was NOT approved.
# Usage: hold.sh <owner/repo> <pr-number> <reason-body>
set -euo pipefail

REPO="${1:?usage: hold.sh <owner/repo> <pr-number> <reason-body>}"
PR="${2:?usage: hold.sh <owner/repo> <pr-number> <reason-body>}"
BODY="${3:?reason body text is required}"

gh pr comment "$PR" --repo "$REPO" --body "$BODY"
echo "Posted hold/explanation comment on $REPO#$PR. No approval submitted."

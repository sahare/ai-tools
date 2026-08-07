#!/usr/bin/env bash
# Gather everything needed to make an approve/hold decision on one PR.
# Usage: pr-status.sh <owner/repo> <pr-number>
set -euo pipefail

REPO="${1:?usage: pr-status.sh <owner/repo> <pr-number>}"
PR="${2:?usage: pr-status.sh <owner/repo> <pr-number>}"

echo "### PR metadata"
gh pr view "$PR" --repo "$REPO" \
  --json number,title,body,mergeable,mergeStateStatus,reviewDecision,isDraft,baseRefName,headRefName

echo
echo "### Checks"
gh pr checks "$PR" --repo "$REPO" || echo "(no checks reported)"

echo
echo "### Changed files"
gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path'

echo
echo "### Diff stat"
gh pr diff "$PR" --repo "$REPO" --stat 2>/dev/null || true

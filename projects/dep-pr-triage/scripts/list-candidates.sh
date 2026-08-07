#!/usr/bin/env bash
# List open, non-draft dependency-bump PRs for a repo as JSON.
# Usage: list-candidates.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: list-candidates.sh <owner/repo>}"

gh pr list --repo "$REPO" --state open --limit 200 \
  --json number,title,url,author,isDraft,labels,createdAt \
  --jq '[.[] | select(.isDraft == false) | select(
      (.author.login | test("dependabot|renovate"; "i")) or
      (.labels[]?.name | test("^dependenc"; "i")) or
      (.title | test("^(fix|chore|build)\\(deps\\)|^(bump|update) "; "i"))
    )]'

#!/bin/bash
# gh_pr_comments/run.sh — list review and conversation comments on a GitHub PR
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, optional .repo)
# Writes: combined PR comments to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')

nwo="$repo"
if [ -z "$nwo" ]; then
  nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1) || {
    printf 'Cannot determine repository: %s' "$nwo"
    exit 1
  }
fi

owner="${nwo%%/*}"
name="${nwo##*/}"

printf '=== Review comments (inline on diff) ===\n\n'
timeout 30s gh api --paginate "repos/$owner/$name/pulls/$number/comments" \
  --jq '.[] | "[\(.user.login) at \(.updated_at)] \(.path):\(.line // .original_line)\n\(.body)\n"' 2>&1 || true

printf '\n=== Conversation comments ===\n\n'
timeout 30s gh api --paginate "repos/$owner/$name/issues/$number/comments" \
  --jq '.[] | "[\(.user.login) at \(.updated_at)]\n\(.body)\n"' 2>&1 || true

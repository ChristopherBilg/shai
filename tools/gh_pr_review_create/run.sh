#!/bin/bash
# gh_pr_review_create/run.sh — create a pending (draft) PR review with inline comments
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, .comments[], optional .repo, .body)
# Writes: review ID and status to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')
body=$(printf '%s' "$input" | jq -r '.body // ""')
comments=$(printf '%s' "$input" | jq -c '.comments')

nwo="$repo"
if [ -z "$nwo" ]; then
  nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1) || {
    printf 'Cannot determine repository: %s' "$nwo"
    exit 1
  }
fi

owner="${nwo%%/*}"
name="${nwo##*/}"

api_comments=$(printf '%s' "$comments" | jq -c '[.[] | {
  path: .path,
  line: .line,
  body: .body,
  side: (.side // "RIGHT")
} + (if .start_line then {start_line: .start_line} else {} end)]')

payload=$(jq -nc \
  --arg body "$body" \
  --argjson comments "$api_comments" \
  '{event: "PENDING", body: $body, comments: $comments}')

result=$(timeout 30s gh api "repos/$owner/$name/pulls/$number/reviews" \
  --method POST \
  --input - <<<"$payload" 2>&1) || {
  printf 'Failed to create review: %s' "$result"
  exit 1
}

review_id=$(printf '%s' "$result" | jq -r '.id')
comment_count=$(printf '%s' "$api_comments" | jq 'length')
printf 'Created pending review %s with %s comment(s). Review on GitHub before submitting with gh_pr_review_submit.' "$review_id" "$comment_count"

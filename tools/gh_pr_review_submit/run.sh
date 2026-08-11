#!/bin/bash
# gh_pr_review_submit/run.sh — submit a pending PR review
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, .review_id, .event, optional .repo, .body)
# Writes: submission confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
review_id=$(printf '%s' "$input" | jq -r '.review_id')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')
event=$(printf '%s' "$input" | jq -r '.event')
body=$(printf '%s' "$input" | jq -r '.body // ""')

nwo="$repo"
if [ -z "$nwo" ]; then
  nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1) || {
    printf 'Cannot determine repository: %s' "$nwo"
    exit 1
  }
fi

owner="${nwo%%/*}"
name="${nwo##*/}"

case "$event" in
  APPROVE | REQUEST_CHANGES | COMMENT) ;;
  *)
    printf 'Invalid event: %s (must be APPROVE, REQUEST_CHANGES, or COMMENT)' "$event"
    exit 1
    ;;
esac

payload=$(jq -nc --arg event "$event" --arg body "$body" '{event: $event, body: $body}')

result=$(timeout 30s gh api "repos/$owner/$name/pulls/$number/reviews/$review_id/events" \
  --method POST \
  --input - <<<"$payload" 2>&1) || {
  printf 'Failed to submit review: %s' "$result"
  exit 1
}

printf 'Submitted review %s as %s' "$review_id" "$event"

#!/bin/bash
# git_checkout_pr/run.sh — check out a pull request branch in a local repository
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, optional .repo, .path)
# Writes: checked-out branch name to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')
target_path=$(printf '%s' "$input" | jq -r '.path // "."')

if [ ! -d "$target_path/.git" ]; then
  printf 'Not a git repository: %s' "$target_path"
  exit 1
fi

args=(pr checkout -- "$number")
if [ -n "$repo" ]; then args=(pr checkout --repo "$repo" -- "$number"); fi

timeout 60s git -C "$target_path" fetch --quiet 2>&1 || true
cd "$target_path"
checkout_out=$(timeout 30s gh "${args[@]}" 2>&1) || {
  printf 'Failed to checkout PR %s: %s' "$number" "$checkout_out"
  exit 1
}

branch=$(git -C "$target_path" rev-parse --abbrev-ref HEAD 2>&1) || branch="unknown"
printf 'Checked out PR %s on branch %s in %s' "$number" "$branch" "$target_path"

#!/bin/bash
# gh_issue_view/run.sh — view a GitHub issue via gh CLI
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, optional .repo)
# Writes: issue details to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')
sub="issue"
args=("$sub" view)
if [ -n "$repo" ]; then args+=(--repo "$repo"); fi
args+=(-- "$number")
timeout 30s gh "${args[@]}" 2>&1

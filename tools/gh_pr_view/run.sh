#!/bin/bash
# gh_pr_view/run.sh — view a GitHub pull request via gh CLI
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .number, optional .repo)
# Writes: PR details to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
number=$(printf '%s' "$input" | jq -r '.number')
repo=$(printf '%s' "$input" | jq -r '.repo // empty')
args=(pr view)
if [ -n "$repo" ]; then args+=(--repo "$repo"); fi
args+=(-- "$number")
timeout 30s gh "${args[@]}" 2>&1

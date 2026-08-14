#!/bin/bash
# gh/run.sh — run an arbitrary gh CLI command from a pre-tokenized argument array
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .args array of strings)
# Writes: gh output to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
mapfile -t args < <(printf '%s' "$input" | jq -r '.args[]')
if [ "${#args[@]}" -eq 0 ]; then
  echo "error: args array must not be empty"
  exit 1
fi
timeout 30s gh "${args[@]}" 2>&1

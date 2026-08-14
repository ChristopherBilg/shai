#!/bin/bash
# git/run.sh — run an arbitrary git command from a pre-tokenized argument array
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .args array of strings)
# Writes: git output to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
mapfile -t -d '' args < <(printf '%s' "$input" | jq -j '.args[] | . + ([0] | implode)')
if [ "${#args[@]}" -eq 0 ]; then
  echo "error: args array must not be empty"
  exit 1
fi
timeout 120s git "${args[@]}" 2>&1

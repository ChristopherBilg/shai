#!/bin/bash
# gh/run.sh — run an arbitrary gh CLI command from a pre-tokenized argument array
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .args array of strings)
# Writes: gh output to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
# NUL-delimited framing: jq -j (no auto-newline) appends a NUL byte after every element
# (`[0] | implode` builds a one-character NUL string), and `mapfile -d ''` splits on NUL.
# A plain `jq -r '.args[]'` (newline-delimited) would silently split an argument value
# that itself contains a newline into two argv entries.
mapfile -t -d '' args < <(printf '%s' "$input" | jq -j '.args[] | . + ([0] | implode)')
if [ "${#args[@]}" -eq 0 ]; then
  echo "error: args array must not be empty"
  exit 1
fi
timeout 120s gh "${args[@]}" 2>&1

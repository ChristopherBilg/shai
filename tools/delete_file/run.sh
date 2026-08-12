#!/bin/bash
# delete_file/run.sh — delete a single file
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path)
# Writes: removes file at .path; confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
if [ ! -e "$path" ] && [ ! -L "$path" ]; then
  printf 'file not found: %s' "$path"
  exit 1
fi
if [ -d "$path" ] && [ ! -L "$path" ]; then
  printf 'cannot delete directory: %s' "$path"
  exit 1
fi
rm -- "$path" 2>&1 || {
  printf 'cannot delete %s' "$path"
  exit 1
}
printf 'Deleted %s' "$path"

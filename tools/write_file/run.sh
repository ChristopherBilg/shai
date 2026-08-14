#!/bin/bash
# write_file/run.sh — create or overwrite a file with given content
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, .content)
# Writes: file at .path; confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
content=$(printf '%s' "$input" | jq -rj '.content' && printf x) || {
  printf 'invalid JSON input'
  exit 1
}
content=${content%x}
mkdir -p -- "$(dirname "$path")" 2>&1 || {
  printf 'cannot create parent directory for %s' "$path"
  exit 1
}
printf '%s' "$content" >"$path" || {
  printf 'cannot write to %s' "$path"
  exit 1
}
printf 'Wrote %d bytes to %s' "$(wc -c <"$path")" "$path"
